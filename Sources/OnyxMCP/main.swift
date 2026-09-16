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

/// The ways the bridge can reach Onyx, in the order they're tried.
///
/// A route that CONNECTS is not a route that works. The forwarded port is
/// a well-known number on a machine we don't own: another user's stale
/// `-R` forward, a forward whose far end died with the app that made it,
/// or any unrelated service can be sitting on it. Each of those accepts
/// the connection and then says nothing — and a bridge that waits on
/// silence looks, from Claude's side, exactly like a server that hangs.
/// That is the 30-second timeout users hit on a shared host.
///
/// So a route has to ANSWER before it is believed. Until it does, it gets
/// a short deadline and is dropped for the rest of the process the moment
/// it fails to speak JSON-RPC.
enum Route: CaseIterable {
    case envPort          // ONYX_MCP_PORT — set inside Onyx's own sessions
    case unixSocket       // same machine as the app
    case forwardedPort    // the connection pair's -R, on any host Onyx uses

    var describe: String {
        switch self {
        case .envPort:
            return "ONYX_MCP_PORT=\(ProcessInfo.processInfo.environment["ONYX_MCP_PORT"] ?? "?")"
        case .unixSocket:    return socketPath
        case .forwardedPort: return "127.0.0.1:\(defaultForwardedPort) (ssh -R)"
        }
    }

    func connect() -> Int32 {
        switch self {
        case .envPort:
            guard let raw = ProcessInfo.processInfo.environment["ONYX_MCP_PORT"],
                  let port = UInt16(raw) else { return -1 }
            return connectToTCP(port: port)
        case .unixSocket:
            return connectToUnixSocket()
        case .forwardedPort:
            guard defaultForwardedPort > 0 else { return -1 }
            return connectToTCP(port: defaultForwardedPort)
        }
    }
}

/// Whether a reply came from Onyx rather than from whatever else happens
/// to hold the port. Cheap on purpose: a JSON object carrying "jsonrpc".
func looksLikeOnyx(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["jsonrpc"] != nil || object["result"] != nil || object["error"] != nil
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
    /// The route the current fd came from.
    private var route: Route?
    /// Routes that have answered with JSON-RPC at least once. A proven
    /// route gets the full timeout, because a real tool call may take a
    /// moment; an unproven one gets seconds.
    private var proven: Set<Int> = []
    /// Routes that connected and then didn't speak. Not retried: the thing
    /// on that port is not going to become Onyx later, and trying it again
    /// on every request is how the whole session becomes unusable.
    private var rejected: Set<Int> = []

    /// How long to wait on a route that hasn't proved itself.
    ///
    /// Claude gives an MCP server 30 seconds to come up. Waiting that long
    /// on one suspect route spends the entire budget and reports nothing;
    /// five seconds is far longer than a loopback needs and leaves room to
    /// try the others.
    private let handshakeTimeout = 5

    init(receiveTimeout: Int) {
        self.receiveTimeout = receiveTimeout
    }

    deinit {
        closeFd()
    }

    private func closeFd() {
        if fd >= 0 { close(fd); fd = -1 }
        route = nil
    }

    private func key(_ route: Route) -> Int {
        Route.allCases.firstIndex(of: route) ?? -1
    }

    private func isProven(_ route: Route) -> Bool { proven.contains(key(route)) }

    /// Ensure we have a live fd. Returns true on success.
    @discardableResult
    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        for candidate in Route.allCases where !rejected.contains(key(candidate)) {
            let newFd = candidate.connect()
            guard newFd >= 0 else { continue }
            setReceiveTimeout(fd: newFd,
                              seconds: isProven(candidate) ? receiveTimeout : handshakeTimeout)
            setSendTimeout(fd: newFd, seconds: 10)
            fd = newFd
            route = candidate
            return true
        }
        return false
    }

    /// Give up on a route that connected and then failed to speak.
    private func reject(_ route: Route, why: String) {
        rejected.insert(key(route))
        FileHandle.standardError.write(Data(
            "OnyxMCP: \(route.describe) is not Onyx (\(why)) — trying the next route\n".utf8))
        closeFd()
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
        setReceiveTimeout(fd: fd, seconds: route.map { isProven($0) ? receiveTimeout : handshakeTimeout } ?? handshakeTimeout)
    }

    /// Send a request and read one response line, transparently reconnecting
    /// on failure. Up to `attempts` total tries with exponential backoff.
    func sendRequest(_ message: String, attempts: Int = 3) -> String? {
        let payload = Array((message + "\n").utf8)
        // Rotating past a peer that isn't Onyx does NOT spend an attempt:
        // it is a different machine's problem, not this one having a bad
        // moment, and it needs no backoff. Rejection is self-limiting —
        // a rejected route is never tried again — so the loop is still
        // bounded. Charging rotations to the retry budget broke hook mode,
        // which runs on every tool call and has seconds to work with.
        var attempt = 0

        while attempt < attempts {
            if !ensureConnected() {
                logRetry(attempt: attempt, reason: "connect failed")
                backoff(attempt: attempt); attempt += 1
                continue
            }
            let current = route

            if !writeAll(fd: fd, data: payload) {
                logRetry(attempt: attempt, reason: "write failed (peer likely closed)")
                closeFd()
                backoff(attempt: attempt); attempt += 1
                continue
            }

            guard let response = readLine(fd: fd) else {
                // Silence from a route that has never answered is the
                // signature of something else holding the port: a stale
                // -R forward whose far end is gone, another user's
                // forward, an unrelated service. Drop it and move on
                // rather than spending Claude's whole startup budget
                // waiting for it.
                if let current, !isProven(current) {
                    reject(current, why: "no answer in \(handshakeTimeout)s")
                    continue      // a different route, not a retry
                }
                logRetry(attempt: attempt, reason: "read failed/EOF")
                closeFd()
                backoff(attempt: attempt); attempt += 1
                continue
            }

            guard looksLikeOnyx(response) else {
                if let current, !isProven(current) {
                    reject(current, why: "answered, but not JSON-RPC")
                    continue      // a different route, not a retry
                }
                logRetry(attempt: attempt, reason: "reply was not JSON-RPC")
                closeFd()
                backoff(attempt: attempt); attempt += 1
                continue
            }

            // It spoke. Trust it with the full timeout from here on.
            if let current, !isProven(current) {
                proven.insert(key(current))
                setReceiveTimeout(fd: fd, seconds: receiveTimeout)
                FileHandle.standardError.write(Data(
                    "OnyxMCP: connected to Onyx via \(current.describe)\n".utf8))
            }
            return response
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
/// stalls the bridge or desynchronizes every response after it.
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

/// A successful tool result carrying one line of text — the MCP shape for
/// "this worked, and here is what happened".
func toolResult(id: String, text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"content\":"
        + "[{\"type\":\"text\",\"text\":\"\(escaped)\"}]}}"
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
    // how a stale install is recognized without relying on the release
    // number — the old bridge shipped claiming 0.17 too.
    print("OnyxMCP \(onyxMCPVersion) (proto \(OnyxVersion.bridgeProtocol))")
    exit(0)
}

// `--probe` answers "can this host actually reach Onyx", route by route,
// which is the question an install should be able to settle on the spot.
// Without it the first sign of trouble is Claude hanging for 30 seconds
// and then saying "connection timed out", which names no cause at all.
if CommandLine.arguments.contains("--probe") {
    var reachable = false
    for route in Route.allCases {
        let fd = route.connect()
        guard fd >= 0 else {
            print("no    \(route.describe) — nothing listening")
            continue
        }
        setReceiveTimeout(fd: fd, seconds: 5)
        setSendTimeout(fd: fd, seconds: 5)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        if !writeAll(fd: fd, data: Array((request + "\n").utf8)) {
            print("no    \(route.describe) — connected, but the write failed")
        } else if let reply = readLine(fd: fd) {
            if looksLikeOnyx(reply) {
                print("YES   \(route.describe) — Onyx answered")
                reachable = true
            } else {
                // The five9 case: something holds the port and is not Onyx.
                print("no    \(route.describe) — answered, but it is not Onyx")
            }
        } else {
            print("no    \(route.describe) — connected, then silence "
                  + "(a stale ssh -R forward looks exactly like this)")
        }
        close(fd)
    }
    print(reachable ? "reachable" : "NOT REACHABLE from this host")
    exit(reachable ? 0 : 1)
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
    let outbox = Outbox()
    // One connection, two threads (the stdin loop and the retry timer).
    let wire = NSLock()

    func deliver(_ line: String) -> String? {
        wire.lock(); defer { wire.unlock() }
        return conn.sendRequest(line)
    }

    /// Try the queue. Cheap when it's empty, which is almost always.
    func flushOutbox(why: String) {
        outbox.purgeExpired()
        guard !outbox.isEmpty else { return }
        let result = outbox.flush { deliver($0) }
        if result.delivered > 0 {
            let note = "OnyxMCP: delivered \(result.delivered) queued alert(s) [\(why)]"
                + (result.remaining > 0 ? ", \(result.remaining) still waiting" : "")
                + "\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
    }

    // A bridge that only retried when the agent spoke would hold an alert
    // until the agent happened to do something else — and an agent that
    // finishes its work and goes quiet is exactly the one whose last
    // message matters. So the queue gets its own heartbeat.
    let retry = Thread {
        while true {
            Thread.sleep(forTimeInterval: 60)
            flushOutbox(why: "retry")
        }
    }
    retry.stackSize = 512 * 1024
    retry.start()

    // A new session is a new chance: whatever the last one couldn't
    // deliver goes out before anything else.
    flushOutbox(why: "session start")

    // Best-effort first connect, but DO NOT exit on failure: the backend
    // may come up later (e.g. desktop launch after MCP started).
    while let line = Swift.readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }

        // A notification gets no answer, and must produce no output — a
        // client that receives a response to something it never gave an
        // id to treats the stream as broken.
        if isNotification(line) {
            wire.lock()
            conn.sendNotification(line)
            wire.unlock()
            continue
        }

        if let response = deliver(line) {
            print(response)
            fflush(stdout)
            flushOutbox(why: "backend is up")
        } else if Outbox.isWorthQueueing(line) {
            // The point of the outbox. The desktop being unreachable is an
            // infrastructure problem; the alert is still true, and the
            // person still wants it. Tell the agent plainly so it doesn't
            // retry and queue a second copy.
            let waiting = outbox.enqueue(line)
            FileHandle.standardError.write(Data(
                "OnyxMCP: backend unreachable — queued this alert (\(waiting) waiting)\n".utf8))
            print(toolResult(
                id: extractRequestId(line),
                text: "Onyx is not reachable from here right now, so this alert is QUEUED and "
                    + "will be delivered when it is (\(waiting) waiting; queued alerts are "
                    + "dropped after 24 hours). Don't resend it — that would arrive twice."))
            fflush(stdout)
        } else {
            let err = errorResponse(
                id: extractRequestId(line),
                message: "Onyx backend unreachable after retries. The next request will retry automatically."
            )
            FileHandle.standardError.write(Data("OnyxMCP: request failed after retries\n".utf8))
            print(err)
            fflush(stdout)
        }
    }
}
