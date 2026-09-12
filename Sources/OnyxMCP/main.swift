import Foundation
import OnyxVersion
#if canImport(Glibc)
import Glibc
#endif

/// OnyxMCP — stdio-to-socket bridge for MCP integration.
/// Reads JSON-RPC from stdin, forwards to the Onyx app, writes responses to stdout.
///
/// Connection modes, in order:
/// 1. ONYX_MCP_PORT set: TCP to 127.0.0.1:<port>. Onyx exports this into
///    the tmux sessions it starts.
/// 2. The Unix socket — right when the bridge and the app are on the
///    same machine.
/// 3. TCP to the well-known forwarded port. Onyx's connection pair
///    always carries `-R 19432:127.0.0.1:<app port>`, so on any host
///    Onyx is connected to, the app is reachable there whether or not
///    anything set an environment variable.
///
/// Without (3) the bridge worked only inside an Onyx terminal: run
/// `claude mcp list` from your own ssh shell on a remote host and it
/// reported "Onyx backend unreachable", because the socket it fell back
/// to lives on the Mac running the app, not on the host.
///
/// Resilience: the bridge process stays alive for the lifetime of the Claude
/// session. Each request transparently reconnects on failure (up to 3 attempts
/// with exponential backoff). Stale fds are always closed before reconnecting,
/// so the process never accumulates CLOSE_WAIT half-open sockets. Read framing
/// loops on `read()` until a newline so multi-packet responses don't truncate.

let socketPath: String = {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return home + "/.onyx/mcp.sock"
}()

// MARK: - Low-level socket helpers

func connectToUnixSocket() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for (i, byte) in pathBytes.enumerated() {
                dest[i] = byte
            }
        }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result < 0 {
        close(fd)
        return -1
    }
    return fd
}

func connectToTCP(port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    if result < 0 {
        close(fd)
        return -1
    }
    return fd
}

/// The port Onyx's connection-pair master forwards on every host.
/// Must match MCPSocketServer.defaultRemotePort — the bridge is a
/// standalone target and can't import the library to share it.
///
/// `ONYX_MCP_FORWARD_PORT` overrides it, and 0 turns the fallback off.
/// Tests need that: without it, "no backend reachable" can't be asserted
/// on a machine where Onyx happens to be forwarding this port — which is
/// any machine a developer is actually using.
let defaultForwardedPort: UInt16 = {
    if let raw = ProcessInfo.processInfo.environment["ONYX_MCP_FORWARD_PORT"],
       let port = UInt16(raw) {
        return port
    }
    return 19432
}()

func connectToOnyx() -> Int32 {
    if let portStr = ProcessInfo.processInfo.environment["ONYX_MCP_PORT"],
       let port = UInt16(portStr) {
        let fd = connectToTCP(port: port)
        if fd >= 0 { return fd }
    }
    // Same machine as the app.
    let unix = connectToUnixSocket()
    if unix >= 0 { return unix }
    // A host Onyx is connected to: the master's -R forwarding makes the
    // app answer here, with nothing needed in the environment.
    guard defaultForwardedPort > 0 else { return -1 }
    return connectToTCP(port: defaultForwardedPort)
}

func setReceiveTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func setSendTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Write all bytes, looping over short writes.
func writeAll(fd: Int32, data: [UInt8]) -> Bool {
    var written = 0
    while written < data.count {
        let n = data[written...].withUnsafeBufferPointer { ptr -> Int in
            #if canImport(Glibc)
            return write(fd, ptr.baseAddress, data.count - written)
            #else
            return write(fd, ptr.baseAddress, data.count - written)
            #endif
        }
        if n <= 0 { return false }
        written += n
    }
    return true
}

/// Read until newline. Returns the line without the trailing \n, or nil on EOF/error.
func readLine(fd: Int32) -> String? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(4096)
    var byte: UInt8 = 0
    while true {
        let n = read(fd, &byte, 1)
        if n == 0 { return nil }       // EOF — peer closed
        if n < 0 { return nil }        // error or timeout
        if byte == UInt8(ascii: "\n") {
            return String(bytes: bytes, encoding: .utf8)
        }
        bytes.append(byte)
        if bytes.count > 16 * 1024 * 1024 {
            // 16MB sanity cap
            return nil
        }
    }
}

// MARK: - Reconnecting connection wrapper

final class OnyxConnection {
    private var fd: Int32 = -1
    private let receiveTimeout: Int

    init(receiveTimeout: Int) {
        self.receiveTimeout = receiveTimeout
    }

    deinit {
        closeFd()
    }

    private func closeFd() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Ensure we have a live fd. Returns true on success.
    @discardableResult
    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        let newFd = connectToOnyx()
        guard newFd >= 0 else { return false }
        setReceiveTimeout(fd: newFd, seconds: receiveTimeout)
        setSendTimeout(fd: newFd, seconds: 10)
        fd = newFd
        return true
    }

    /// Send a notification — a message with no id — and expect nothing
    /// back.
    ///
    /// Waiting for a reply to one is how this bridge used to stall: the
    /// desktop sends nothing (correctly), so the read blocks for the full
    /// receive timeout, three times, before the client is told the backend
    /// is unreachable. At session start that reads as "Failed to reconnect
    /// to onyx".
    ///
    /// The short drain afterwards is for an OLDER desktop that still
    /// answers notifications: its stray `{"result":null}` has to be
    /// consumed here, or the next real request would read it as its own
    /// response and every reply after that would be off by one.
    func sendNotification(_ message: String) {
        let payload = Array((message + "\n").utf8)
        guard ensureConnected(), writeAll(fd: fd, data: payload) else {
            closeFd()
            return
        }
        setReceiveTimeout(fd: fd, seconds: 1)
        _ = readLine(fd: fd)
        setReceiveTimeout(fd: fd, seconds: receiveTimeout)
    }

    /// Send a request and read one response line, transparently reconnecting
    /// on failure. Up to `attempts` total tries with exponential backoff.
    func sendRequest(_ message: String, attempts: Int = 3) -> String? {
        let payload = Array((message + "\n").utf8)
        for attempt in 0..<attempts {
            if !ensureConnected() {
                logRetry(attempt: attempt, reason: "connect failed")
                backoff(attempt: attempt)
                continue
            }

            // Send
            if !writeAll(fd: fd, data: payload) {
                logRetry(attempt: attempt, reason: "write failed (peer likely closed)")
                closeFd()
                backoff(attempt: attempt)
                continue
            }

            // Receive one line
            if let response = readLine(fd: fd) {
                return response
            }
            logRetry(attempt: attempt, reason: "read failed/EOF")
            closeFd()
            backoff(attempt: attempt)
        }
        return nil
    }

    private func logRetry(attempt: Int, reason: String) {
        let msg = "OnyxMCP: attempt \(attempt + 1) — \(reason)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    private func backoff(attempt: Int) {
        // 100ms, 300ms, 900ms ...
        let micros: UInt32 = 100_000 * UInt32(pow(3.0, Double(attempt)))
        usleep(min(micros, 2_000_000))
    }
}

// MARK: - JSON-RPC helpers

/// Whether a client message is a notification: no id, or an explicit
/// null one. Parsed properly rather than pattern-matched — an "id" inside
/// a tool argument would fool a regex, and getting this wrong either
/// stalls the bridge or desynchronises every response after it.
///
/// An unparseable line is treated as a REQUEST, so the desktop's parse
/// error still reaches the client instead of vanishing.
func isNotification(_ json: String) -> Bool {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    guard let id = object["id"] else { return true }
    return id is NSNull
}

/// Extract the "id" field from a JSON-RPC request string for error responses
func extractRequestId(_ json: String) -> String {
    if let range = json.range(of: #""id"\s*:\s*"#, options: .regularExpression) {
        let after = json[range.upperBound...]
        if after.hasPrefix("null") { return "null" }
        if after.hasPrefix("\"") {
            if let end = after.dropFirst().firstIndex(of: "\"") {
                return String(after[after.startIndex...end])
            }
        }
        let digits = after.prefix(while: { $0.isNumber || $0 == "-" })
        if !digits.isEmpty { return String(digits) }
    }
    return "null"
}

func errorResponse(id: String, message: String) -> String {
    // Escape quotes and backslashes in the message
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"error\":{\"code\":-32000,\"message\":\"\(escaped)\"}}"
}

// MARK: - Modes

/// Build identity, stamped by package.sh / CI so an installed bridge can
/// be tied back to what produced it.
let onyxMCPVersion = OnyxVersion.current

// `--version` answers "is this thing installed and can it start", which
// is the question both CI and the app's installer ask. It must not touch
// the socket: the whole point is to verify the binary independently of
// whether Onyx is running or reachable.
if CommandLine.arguments.contains("--version") {
    // The proto number is what the installer actually reads. A bridge
    // that prints none is older than the idea of printing one, which is
    // how a stale install is recognised without relying on the release
    // number — the old bridge shipped claiming 0.17 too.
    print("OnyxMCP \(onyxMCPVersion) (proto \(OnyxVersion.bridgeProtocol))")
    exit(0)
}

let hookIndex = CommandLine.arguments.firstIndex(of: "--hook")
let isHookMode = hookIndex != nil

if isHookMode {
    // HOOK MODE — read one Claude Code hook event from stdin, forward, exit.
    //
    // Usage: OnyxMCP --hook <EventName>
    // The event name (PreToolUse, PostToolUse, PermissionRequest, etc.) is
    // passed as the arg after --hook so we can tag the JSON-RPC payload.
    // Claude Code itself does NOT include the event type in the stdin JSON.
    let eventName: String = {
        if let idx = hookIndex, idx + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[idx + 1]
        }
        return "Unknown"
    }()

    // PermissionRequest may block up to 120s waiting for user interaction.
    // Other events should be fast.
    let hookTimeout = eventName == "PermissionRequest" ? 120 : 10
    let conn = OnyxConnection(receiveTimeout: hookTimeout)

    var inputData = Data()
    while let chunk = Optional(FileHandle.standardInput.availableData), !chunk.isEmpty {
        inputData.append(chunk)
        if (try? JSONSerialization.jsonObject(with: inputData)) != nil { break }
    }

    guard !inputData.isEmpty, let inputString = String(data: inputData, encoding: .utf8) else {
        exit(0)
    }

    // Inject hook_event_name into the params so the desktop can route the
    // event to the correct handler. Claude's stdin payload has tool_name
    // etc but NOT the event type.
    let requestId = "hook_\(ProcessInfo.processInfo.processIdentifier)"
    let enrichedParams: String
    if let data = inputData as Data?,
       var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        dict["hook_event_name"] = eventName
        if let enriched = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: enriched, encoding: .utf8) {
            enrichedParams = str
        } else {
            enrichedParams = inputString
        }
    } else {
        enrichedParams = inputString
    }

    let jsonRPC = """
    {"jsonrpc":"2.0","id":"\(requestId)","method":"claude/hook","params":\(enrichedParams)}
    """

    if let response = conn.sendRequest(jsonRPC, attempts: 2),
       let data = response.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let result = json["result"],
       let resultData = try? JSONSerialization.data(withJSONObject: result),
       let resultString = String(data: resultData, encoding: .utf8) {
        print(resultString)
        fflush(stdout)
    }
    // Silent fall-through on any failure — Claude Code continues normally.
} else {
    // BRIDGE MODE — long-lived stdio JSON-RPC bridge.
    //
    // The bridge process MUST stay alive for the lifetime of the Claude
    // session. Backend restarts (Onyx desktop quitting/relaunching, SSH
    // tunnel reconnecting, network blips) are handled inside sendRequest
    // via reconnect + backoff. Individual requests may return an error
    // when the backend is unreachable, but subsequent requests will
    // automatically reconnect once it comes back.

    let conn = OnyxConnection(receiveTimeout: 30)

    // Best-effort first connect, but DO NOT exit on failure: the backend
    // may come up later (e.g. desktop launch after MCP started).
    while let line = Swift.readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }

        // A notification gets no answer, and must produce no output — a
        // client that receives a response to something it never gave an
        // id to treats the stream as broken.
        if isNotification(line) {
            conn.sendNotification(line)
            continue
        }

        if let response = conn.sendRequest(line) {
            print(response)
            fflush(stdout)
        } else {
            let reqId = extractRequestId(line)
            let err = errorResponse(
                id: reqId,
                message: "Onyx backend unreachable after retries. The next request will retry automatically."
            )
            FileHandle.standardError.write(Data("OnyxMCP: request failed after retries\n".utf8))
            print(err)
            fflush(stdout)
        }
    }
}
