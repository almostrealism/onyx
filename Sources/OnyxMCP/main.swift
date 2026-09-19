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

/// `SOCK_STREAM` is an `Int32` in Darwin's headers and a `__socket_type`
/// enum in Glibc's, so the literal that compiles on a Mac does not
/// compile on Linux. This is the portable spelling.
#if canImport(Glibc)
let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
let streamSocket = SOCK_STREAM
#endif

// A write to a socket whose far end has closed raises SIGPIPE, and the
// default action for SIGPIPE is to KILL THE PROCESS. From Claude's side
// that is "Connection closed" with no result body — the bridge simply
// died — followed, after it restarts the server, by a retry that works.
// And the far end closes all the time: every connection-pair rotation
// tears down the `-R` forward under the bridge, and the desktop drops
// connections on error. Agents were seeing one or zero successful alerts
// per session because of this line's absence. With it ignored, write()
// returns EPIPE, `writeAll` reports false, and the reconnect path that
// was always there finally gets to run.
signal(SIGPIPE, SIG_IGN)

let socketPath: String = {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return home + "/.onyx/mcp.sock"
}()

// MARK: - Low-level socket helpers

func connectToUnixSocket() -> Int32 {
    let fd = socket(AF_UNIX, streamSocket, 0)
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
    let fd = socket(AF_INET, streamSocket, 0)
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
    /// Host-wide notes on what has and hasn't worked. Every outcome here
    /// is written down, so a later error message — or a human at the
    /// prompt — can say more than "unreachable".
    let ledger = Ledger()
    /// The desktop currently answering, once it has said who it is.
    private(set) var desktop: (machine: String, version: String)?
    /// Whether the LAST request got through. The transition from false to
    /// true is when the client should be told the tool list may have
    /// changed — because while the backend was down, the list was ours.
    private(set) var backendUp = false
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
        ledger.sawFailure(route: route.describe, reason: why)
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
                if attempt == 0 {
                    ledger.sawFailure(route: "every route",
                                      reason: "nothing listening on any of them")
                }
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
                identify(via: current)
                let who = desktop.map { " — \($0.machine), Onyx \($0.version)" } ?? ""
                let note = "OnyxMCP: connected to Onyx via \(current.describe)\(who)\n"
                FileHandle.standardError.write(Data(note.utf8))
            } else if let current {
                ledger.sawSuccess(route: current.describe)
            }
            backendUp = true
            return response
        }
        return nil
    }

    /// Ask the desktop who it is, and write it down.
    ///
    /// One extra `initialize` on the wire when a route first proves
    /// itself. The reply's serverInfo names the machine and the version,
    /// which is the difference between a ledger that says "something
    /// answered" and one that says "mac-studio, Onyx 0.17, 2 minutes ago".
    private func identify(via route: Route) {
        let request = #"{"jsonrpc":"2.0","id":"onyx-identify","method":"initialize"}"#
        // A transport failure here is not a fact about the desktop — the
        // socket may have been reset between the answer and this — so it
        // records nothing, and the next request's reconnect will get a
        // proper look. Only an ANSWER without an identity means "older
        // desktop".
        guard writeAll(fd: fd, data: Array((request + "\n").utf8)),
              let reply = readLine(fd: fd) else {
            closeFd()
            return
        }
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let info = result["serverInfo"] as? [String: Any] else {
            ledger.sawDesktop(machine: "unknown desktop", version: "pre-0.17",
                              route: route.describe)
            return
        }
        let machine = info["machine"] as? String ?? "unknown desktop"
        let version = info["version"] as? String ?? "?"
        desktop = (machine, version)
        ledger.sawDesktop(machine: machine, version: version, route: route.describe)
    }

    /// Note that the backend stopped answering, for the up→down→up edge.
    func markDown() { backendUp = false }

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

/// The bridge's shared state, in one place that can cross a thread.
///
/// This was a set of local functions closing over a connection, an outbox
/// and a lock — which the compiler rightly objects to the moment one of
/// them is called from a `Thread`: "concurrently-executed local function
/// must be marked @Sendable", an error in Swift 6. Local functions that
/// share mutable state across threads are the wrong shape for it anyway.
///
/// `@unchecked` because the safety is the lock's doing rather than the
/// type system's: one connection, used by the stdin loop and the retry
/// heartbeat, serialized here.
final class Bridge: @unchecked Sendable {
    private let connection: OnyxConnection
    let outbox: Outbox
    private let wire = NSLock()

    init(connection: OnyxConnection, outbox: Outbox) {
        self.connection = connection
        self.outbox = outbox
    }

    func deliver(_ line: String) -> String? {
        wire.lock(); defer { wire.unlock() }
        let reply = connection.sendRequest(line)
        if reply == nil {
            connection.markDown()
            return nil
        }
        // The edge that matters: the client was handed OUR tool list
        // (because the desktop was away, possibly since before the session
        // began), and the desktop has now answered. Tell the client the
        // list moved so it asks again — otherwise a session that started
        // while Onyx was closed never sees Onyx's tools at all.
        if clientHasLocalToolList {
            clientHasLocalToolList = false
            print(toolsChangedNotification())
            fflush(stdout)
            FileHandle.standardError.write(Data(
                "OnyxMCP: desktop reachable now — told the client the tool list changed\n".utf8))
        }
        return reply
    }

    /// True after `initialize` or `tools/list` was answered locally,
    /// until the desktop answers something.
    var clientHasLocalToolList = false

    /// How long to keep trying before giving up on delivering right now.
    /// Under the ~30s an MCP client allows a tool call, with margin.
    static let briefRetryBudget: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["ONYX_MCP_BRIEF_RETRY"],
           let seconds = TimeInterval(raw) { return seconds }
        return 18
    }()

    /// A few more tries over a few seconds. Nil if it still won't go.
    func retryBriefly(_ line: String) -> String? {
        let deadline = Date().addingTimeInterval(Self.briefRetryBudget)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 3)
            if let reply = deliver(line) { return reply }
        }
        return nil
    }

    var ledger: Ledger { connection.ledger }

    /// The full picture, as text an agent or a person can read.
    func statusReport() -> String {
        Ledger.report(ledger.snapshot(),
                      host: ProcessInfo.processInfo.hostName,
                      version: "\(onyxMCPVersion) (proto \(OnyxVersion.bridgeProtocol))",
                      routes: probeRoutes(),
                      outboxWaiting: outbox.count)
    }

    /// The paragraph that replaces "unreachable" in every error.
    func unreachableExplanation() -> String {
        Ledger.summary(ledger.snapshot(), outboxWaiting: outbox.count)
    }

    func sendNotification(_ line: String) {
        wire.lock(); defer { wire.unlock() }
        connection.sendNotification(line)
    }

    /// Try the queue. Cheap when it's empty, which is almost always.
    func flushOutbox(why: String) {
        outbox.purgeExpired()
        guard !outbox.isEmpty else { return }
        let result = outbox.flush { self.deliver($0) }
        guard result.delivered > 0 else { return }
        let note = "OnyxMCP: delivered \(result.delivered) queued alert(s) [\(why)]"
            + (result.remaining > 0 ? ", \(result.remaining) still waiting" : "")
            + "\n"
        FileHandle.standardError.write(Data(note.utf8))
    }
}

// MARK: - What the bridge answers on its own

/// The tool the bridge serves WITHOUT a desktop. It exists so an agent
/// always has something to call that explains the situation, instead of
/// being left to conclude "it's broken" from a failed tool call and a
/// one-word error.
let statusToolName = "onyx_status"

func statusToolJSON() -> String {
    // Kept as a literal so it is byte-identical whether the desktop is
    // reachable or not.
    #"""
    {"name":"onyx_status","description":"Is Onyx reachable from this host, and if not, why not and since when. Call this FIRST when any other Onyx tool fails or when the Onyx tools seem to be missing: it answers from this host's own records — which desktops have ever answered from here, when each was last heard from, what the last attempt saw, and whether alerts are queued — and never needs the desktop to be running.","inputSchema":{"type":"object","properties":{}}}
    """#.trimmingCharacters(in: .whitespacesAndNewlines)
}

func methodName(of line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["method"] as? String
}

func toolName(of line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let params = object["params"] as? [String: Any] else { return nil }
    return params["name"] as? String
}

/// An `initialize` answer the bridge can give with no desktop behind it.
///
/// This is the fix for a session that starts while Onyx is closed. The
/// bridge used to fail `initialize`, and a client that sees initialize
/// fail marks the server dead FOR THE WHOLE SESSION — Onyx opening a
/// minute later changed nothing. Now the handshake always succeeds,
/// `listChanged` tells the client the tool list can move, and when the
/// desktop appears the bridge says so (see the main loop).
func localInitializeResponse(id: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"onyx","version":"\#(onyxMCPVersion)","note":"bridge only — the Onyx desktop is not reachable from this host right now; call onyx_status"}}}"#
}

/// A `tools/list` with only what the bridge itself can serve.
func localToolsListResponse(id: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[\#(statusToolJSON())]}}"#
}

/// The desktop's own tools/list, with `onyx_status` added — so the tool
/// is callable whether or not the desktop is up, from the same name.
func withStatusTool(_ response: String) -> String {
    guard let data = response.data(using: .utf8),
          var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var result = object["result"] as? [String: Any],
          var tools = result["tools"] as? [[String: Any]],
          let statusData = statusToolJSON().data(using: .utf8),
          let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any]
    else { return response }
    guard !tools.contains(where: { $0["name"] as? String == statusToolName }) else { return response }
    tools.append(status)
    result["tools"] = tools
    object["result"] = result
    guard let out = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: out, encoding: .utf8) else { return response }
    return line
}

/// Live verdict per route, the same probe `--probe` prints.
func probeRoutes() -> [(route: String, verdict: String, ok: Bool)] {
    Route.allCases.map { route in
        let fd = route.connect()
        guard fd >= 0 else { return (route.describe, "nothing listening", false) }
        defer { close(fd) }
        setReceiveTimeout(fd: fd, seconds: 5)
        setSendTimeout(fd: fd, seconds: 5)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        guard writeAll(fd: fd, data: Array((request + "\n").utf8)) else {
            return (route.describe, "connected, but the write failed", false)
        }
        guard let reply = readLine(fd: fd) else {
            return (route.describe, "connected, then silence (a stale ssh -R forward looks exactly like this)", false)
        }
        return looksLikeOnyx(reply)
            ? (route.describe, "Onyx answered", true)
            : (route.describe, "answered, but it is not Onyx", false)
    }
}

/// The server→client notice that the tool list moved. Allowed on stdio
/// at any time; the client re-lists if it honors `listChanged`, and
/// ignores it harmlessly if not.
func toolsChangedNotification() -> String {
    #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#
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

/// A successful tool result carrying text — the MCP shape for "this
/// worked, and here is what happened".
///
/// Built by the serializer, not by hand. The first version escaped
/// quotes and backslashes itself and nothing else, which held until the
/// status report — several lines long — went through it and came out as
/// a JSON string with raw newlines in it, which is not JSON.
func toolResult(id: String, text: String) -> String {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": idValue(id),
        "result": ["content": [["type": "text", "text": text]]],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: data, encoding: .utf8) else {
        return #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"(unrepresentable)"}]}}"#
    }
    return line
}

/// `extractRequestId` hands back the id as it appeared in the request —
/// a number, a quoted string, or `null` — so it can be spliced into raw
/// JSON. The serializer needs the value instead.
func idValue(_ raw: String) -> Any {
    if raw == "null" { return NSNull() }
    if let n = Int(raw) { return n }
    if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
        return String(raw.dropFirst().dropLast())
    }
    return raw
}

func errorResponse(id: String, message: String) -> String {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": idValue(id),
        "error": ["code": -32000, "message": message],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: data, encoding: .utf8) else {
        return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"unreachable"}}"#
    }
    return line
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

// `--status` is the standalone answer to "what is going on": everything
// this host has ever seen of Onyx, every route's state right now, and
// what is queued. The same text the `onyx_status` tool returns to an
// agent, so a human and an agent are reading the same facts.
if CommandLine.arguments.contains("--status") {
    let ledger = Ledger()
    let routes = probeRoutes()
    print(Ledger.report(ledger.snapshot(),
                        host: ProcessInfo.processInfo.hostName,
                        version: "\(onyxMCPVersion) (proto \(OnyxVersion.bridgeProtocol))",
                        routes: routes,
                        outboxWaiting: Outbox().count))
    exit(routes.contains { $0.ok } ? 0 : 1)
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

    let bridge = Bridge(connection: OnyxConnection(receiveTimeout: 30), outbox: Outbox())

    // A bridge that only retried when the agent spoke would hold an alert
    // until the agent happened to do something else — and an agent that
    // finishes its work and goes quiet is exactly the one whose last
    // message matters. So the queue gets its own heartbeat.
    let retry = Thread { [bridge] in
        while true {
            // Quicker while something is waiting: "delivered within a
            // minute" is a promise made to the agent above, and a desktop
            // that checks in every minute needs to be caught mid-contact.
            Thread.sleep(forTimeInterval: bridge.outbox.isEmpty ? 60 : 15)
            bridge.flushOutbox(why: "retry")
            // If the client is holding OUR tool list, look for the desktop
            // even though nobody asked: an idle agent would otherwise
            // never learn that Onyx opened. `deliver` sends the
            // list_changed notice itself on success; the reply is
            // discarded because no one requested it.
            if bridge.clientHasLocalToolList {
                _ = bridge.deliver(#"{"jsonrpc":"2.0","id":"onyx-heartbeat","method":"initialize"}"#)
            }
        }
    }
    retry.stackSize = 512 * 1024
    retry.start()

    // A new session is a new chance: whatever the last one couldn't
    // deliver goes out before anything else.
    bridge.flushOutbox(why: "session start")

    // Best-effort first connect, but DO NOT exit on failure: the backend
    // may come up later (e.g. desktop launch after MCP started).
    while let line = Swift.readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }

        // A notification gets no answer, and must produce no output — a
        // client that receives a response to something it never gave an
        // id to treats the stream as broken.
        if isNotification(line) {
            bridge.sendNotification(line)
            continue
        }

        // `ping` is the client asking whether THIS SERVER is alive, and it
        // is. Forwarding it was wrong twice over: the desktop answered
        // methodNotFound, and with the desktop away the forward went to a
        // dead socket — which, before SIGPIPE was ignored, killed the
        // bridge on a request no agent ever made.
        if methodName(of: line) == "ping" {
            print(#"{"jsonrpc":"2.0","id":\#(extractRequestId(line)),"result":{}}"#)
            fflush(stdout)
            continue
        }

        // Served here, desktop or no desktop. An agent that can call this
        // never has to guess.
        if methodName(of: line) == "tools/call", toolName(of: line) == statusToolName {
            print(toolResult(id: extractRequestId(line), text: bridge.statusReport()))
            fflush(stdout)
            continue
        }

        if let response = bridge.deliver(line) {
            print(methodName(of: line) == "tools/list" ? withStatusTool(response) : response)
            fflush(stdout)
            bridge.flushOutbox(why: "backend is up")
        } else if methodName(of: line) == "initialize" {
            // Never fail the handshake. A client that sees it fail marks
            // this server dead for the whole session, and Onyx opening a
            // minute later then changes nothing.
            bridge.clientHasLocalToolList = true
            print(localInitializeResponse(id: extractRequestId(line)))
            fflush(stdout)
            let note = "OnyxMCP: desktop unreachable at startup — answered initialize "
                + "locally; tools will appear when it is\n"
            FileHandle.standardError.write(Data(note.utf8))
        } else if methodName(of: line) == "tools/list" {
            bridge.clientHasLocalToolList = true
            print(localToolsListResponse(id: extractRequestId(line)))
            fflush(stdout)
        } else if Outbox.isWorthQueueing(line) {
            // If the desktop was around a few minutes ago it is probably
            // between contacts — a laptop lid, a wifi nap — not gone. Try a
            // little longer before queueing: turning "queued" into
            // "delivered" here spares the agent a judgment call it can't
            // make well. Bounded so the agent's tool call can't time out.
            if case .recent = Ledger.recency(bridge.ledger.snapshot()),
               let reply = bridge.retryBriefly(line) {
                print(reply)
                fflush(stdout)
                bridge.flushOutbox(why: "backend came back")
                continue
            }

            // The point of the outbox. The desktop being unreachable is an
            // infrastructure problem; the alert is still true, and the
            // person still wants it. What the agent is told depends on how
            // recently the desktop was here — "queued" on a laptop that
            // checks in every minute means "delivered shortly", and saying
            // anything gloomier gets relayed to the user as a failure they
            // then receive the alert about anyway.
            let waiting = bridge.outbox.enqueue(line)
            FileHandle.standardError.write(Data(
                "OnyxMCP: backend unreachable — queued this alert (\(waiting) waiting)\n".utf8))
            print(toolResult(
                id: extractRequestId(line),
                text: Ledger.queuedExplanation(bridge.ledger.snapshot(), waiting: waiting)))
            fflush(stdout)
        } else {
            // Not "unreachable": WHAT was seen, WHEN it last worked, and
            // what to do. An agent can relay every sentence of this.
            let err = errorResponse(
                id: extractRequestId(line),
                message: "Onyx is not reachable from this host. " + bridge.unreachableExplanation()
                    + " The next request will retry automatically."
            )
            FileHandle.standardError.write(Data("OnyxMCP: request failed after retries\n".utf8))
            print(err)
            fflush(stdout)
        }
    }
}
