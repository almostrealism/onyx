//
// jdtls-spike — a throwaway harness that proves Onyx can drive the Eclipse
// JDT language server (jdtls) over a clean byte pipe (local process or SSH)
// and get real semantic navigation results back: subclasses, implementors,
// overrides, references.
//
// This is NOT production code. It exists to retire the transport risk before
// we commit to an `LSPManager`. It deliberately reuses no OnyxLib types so it
// stays self-contained and disposable. Where it mirrors an app pattern, a
// comment points at the real thing.
//
// Usage (local, against the bundled sample project):
//   swift run jdtls-spike \
//     --project spike/sample-java \
//     --file src/main/java/com/onyx/spike/AbstractShape.java \
//     --symbol AbstractShape --query subtypes
//
// Usage (remote, over SSH — the real target):
//   swift run jdtls-spike --host myhost --user me \
//     --jdtls '~/.onyx/jdtls/bin/jdtls' \
//     --project /srv/code/myrepo \
//     --file src/main/java/.../Shape.java --symbol Shape --query implementation
//
import Foundation

// MARK: - Tiny arg parser

func parseArgs(_ argv: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                out[key] = argv[i + 1]; i += 2
            } else {
                out[key] = "true"; i += 1   // bare flag
            }
        } else { i += 1 }
    }
    return out
}

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

let verbose = args["v"] != nil || args["verbose"] != nil
func vlog(_ s: String) { if verbose { FileHandle.standardError.write(Data(("· " + s + "\n").utf8)) } }

// MARK: - Config

let host = args["host"]                                   // nil / "local" → run jdtls directly
let user = args["user"] ?? ""
let port = args["port"].flatMap { Int($0) } ?? 22
let identity = args["identity"]
let isRemote = (host != nil && host != "local" && host != "localhost")

// Default local jdtls launcher; on remote the user should pass an absolute path.
let jdtlsCmd = args["jdtls"] ?? (NSHomeDirectory() + "/.onyx/jdtls/bin/jdtls")

guard let projectArg = args["project"] else { die("--project <path> required") }
// Local project paths get resolved to absolute; remote paths are used verbatim.
let projectPath: String = isRemote ? projectArg
    : URL(fileURLWithPath: projectArg).standardizedFileURL.path

guard let fileArg = args["file"] else { die("--file <path> required") }
// File may be given relative to the project root.
let filePath: String = fileArg.hasPrefix("/") ? fileArg : (projectPath + "/" + fileArg)

let query = args["query"] ?? "subtypes"      // subtypes | supertypes | implementation | references
let dataDir = args["data"] ?? (NSTemporaryDirectory() + "jdtls-spike-ws")
let overallTimeout = args["timeout"].flatMap { Double($0) } ?? 180.0

// MARK: - File content (needed for didOpen + to locate --symbol)

func fetchFileContent(_ path: String) -> String {
    if isRemote {
        // A quick side-channel read. The real app already has remote file
        // reads (FileBrowserManager); here we just shell out to `ssh cat`.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshArgs(extra: ["cat \(shellQuote(path))"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } else {
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - Transport

/// SSH args mirroring AppState.sshSessionArgs — a long-lived session, but
/// crucially WITHOUT `-t`: an LSP stream is raw framed bytes, and a PTY would
/// echo our stdin and translate newlines, corrupting the framing. The real
/// LSPManager will make the same choice.
func sshArgs(extra: [String]) -> [String] {
    var a: [String] = [
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "BatchMode=yes",
    ]
    if port != 22 { a += ["-p", "\(port)"] }
    if let identity, !identity.isEmpty { a += ["-i", identity] }
    let userHost = user.isEmpty ? (host ?? "") : "\(user)@\(host ?? "")"
    a.append(userHost)
    a += extra
    return a
}

func makeServerProcess() -> Process {
    let p = Process()
    if isRemote {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Login shell so java/python3 are on PATH; jdtls speaks stdio.
        let launch = "exec $SHELL -lc \(shellQuote("\(jdtlsCmd) -data \(dataDir)"))"
        p.arguments = sshArgs(extra: [launch])
    } else {
        p.executableURL = URL(fileURLWithPath: jdtlsCmd)
        p.arguments = ["-data", dataDir]
    }
    return p
}

// MARK: - LSP client

final class LSPClient {
    private let proc = makeServerProcess()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    private var buffer = Data()
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: (Any?) -> Void] = [:]

    /// Notification handler (method, params).
    var onNotification: ((String, [String: Any]) -> Void)?

    func start() throws {
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { return }
            self?.feed(d)
        }
        // Surface server stderr only in verbose mode — jdtls is chatty.
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { return }
            if verbose { FileHandle.standardError.write(d) }
        }
        try proc.run()
    }

    func stop() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
    }

    // MARK: framing

    /// Robust reader: tolerates any non-LSP banner text the login shell might
    /// emit before the first frame (MOTD, profile echoes) by scanning for the
    /// Content-Length header rather than assuming the stream starts clean.
    private func feed(_ d: Data) {
        lock.lock(); buffer.append(d); lock.unlock()
        while let frame = nextFrame() { dispatch(frame) }
    }

    private func nextFrame() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let header = Data("Content-Length:".utf8)
        guard let hRange = buffer.range(of: header) else {
            // No header yet. Prevent unbounded growth from pure banner noise.
            if buffer.count > 1_000_000 { buffer.removeFirst(buffer.count - 100_000) }
            return nil
        }
        // Drop any banner bytes before the header.
        if hRange.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<hRange.lowerBound) }

        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = buffer.range(of: sep) else { return nil }  // header incomplete
        let headerData = buffer.subdata(in: buffer.startIndex..<sepRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        var length = -1
        for line in headerStr.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? -1
        }
        guard length >= 0 else { return nil }
        let bodyStart = sepRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }  // body incomplete
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private func dispatch(_ msg: [String: Any]) {
        if let id = msg["id"] as? Int, msg["method"] == nil {
            // Response to one of our requests.
            lock.lock(); let cb = pending.removeValue(forKey: id); lock.unlock()
            cb?(msg["result"] ?? msg["error"])
            return
        }
        if let method = msg["method"] as? String {
            if let id = msg["id"] {
                // Server→client REQUEST — must answer or jdtls stalls.
                answerServerRequest(id: id, method: method)
            } else {
                onNotification?(method, msg["params"] as? [String: Any] ?? [:])
            }
        }
    }

    private func answerServerRequest(id: Any, method: String) {
        var result: Any = NSNull()
        switch method {
        case "workspace/configuration":
            // One settings object per requested item; empty is fine for the spike.
            result = [[String: Any]()]
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create":
            result = NSNull()
        case "workspace/applyEdit":
            result = ["applied": false]
        default:
            result = NSNull()
        }
        sendRaw(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: sending

    private func sendRaw(_ obj: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        inPipe.fileHandleForWriting.write(out)
    }

    func notify(_ method: String, _ params: [String: Any]) {
        sendRaw(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Synchronous request with timeout. Returns result (or error) or nil on timeout.
    @discardableResult
    func request(_ method: String, _ params: Any, timeout: Double = 30) -> Any? {
        lock.lock(); let id = nextId; nextId += 1; lock.unlock()
        let sem = DispatchSemaphore(value: 0)
        var captured: Any?
        lock.lock(); pending[id] = { captured = $0; sem.signal() }; lock.unlock()
        sendRaw(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            vlog("request \(method) timed out")
            return nil
        }
        return captured
    }
}

// MARK: - Locating the symbol position

/// Convert 1-based line/col to LSP 0-based Position. If --symbol is given,
/// find the token so the caller needn't hand-count columns.
func resolvePosition(content: String) -> (line: Int, char: Int) {
    if let line = args["line"].flatMap({ Int($0) }) {
        let col = args["col"].flatMap { Int($0) } ?? 1
        return (line - 1, col - 1)
    }
    guard let symbol = args["symbol"] else {
        die("provide --symbol <name>, or --line/--col")
    }
    let lines = content.components(separatedBy: "\n")
    // Prefer a declaration line (class/interface/record/enum or a method decl).
    let declKeywords = ["class ", "interface ", "record ", "enum "]
    var best: (Int, Int)?
    for (idx, text) in lines.enumerated() {
        guard let r = text.range(of: symbol) else { continue }
        let col = text.distance(from: text.startIndex, to: r.lowerBound)
        if declKeywords.contains(where: { text.contains($0) }) {
            return (idx, col)   // declaration line wins immediately
        }
        if best == nil { best = (idx, col) }
    }
    guard let b = best else { die("symbol '\(symbol)' not found in \(filePath)") }
    return b
}

// MARK: - URI helpers

func fileURI(_ path: String) -> String {
    // jdtls wants file:// URIs; on remote these are the remote absolute paths.
    var p = path
    if !p.hasPrefix("/") { p = "/" + p }
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    return "file://" + (p.addingPercentEncoding(withAllowedCharacters: allowed) ?? p)
}

func shortURI(_ uri: String) -> String {
    let base = uri.removingPercentEncoding ?? uri
    if base.hasPrefix(projectPath) || base.hasPrefix("file://" + projectPath) {
        return String(base.split(separator: "/").last ?? Substring(base))
    }
    return String(base.split(separator: "/").last ?? Substring(base))
}

func fmtLocation(_ loc: [String: Any]) -> String {
    let uri = (loc["uri"] as? String) ?? (loc["targetUri"] as? String) ?? "?"
    let range = (loc["range"] as? [String: Any]) ?? (loc["selectionRange"] as? [String: Any]) ?? [:]
    let start = range["start"] as? [String: Any]
    let line = (start?["line"] as? Int).map { $0 + 1 } ?? 0
    let name = (loc["name"] as? String).map { " \($0)" } ?? ""
    return "  \(shortURI(uri)):\(line)\(name)"
}

// MARK: - Main flow

let content = fetchFileContent(filePath)
if content.isEmpty { die("could not read \(filePath)") }
let pos = resolvePosition(content: content)
let uri = fileURI(filePath)

print("jdtls-spike")
print("  transport : \(isRemote ? "ssh \(user)@\(host ?? "?")" : "local process")")
print("  jdtls     : \(jdtlsCmd)")
print("  project   : \(projectPath)")
print("  file      : \(fileArg)  @ line \(pos.line + 1), char \(pos.char + 1)")
print("  query     : \(query)")
print("  ----")

let client = LSPClient()

// Readiness: jdtls sends language/status notifications; "ServiceReady" (or a
// project import completion) means the classpath is resolved and queries will
// return real results. We also just retry the query until non-empty.
let readySem = DispatchSemaphore(value: 0)
var sawReady = false
client.onNotification = { method, params in
    switch method {
    case "language/status":
        let type = params["type"] as? String ?? ""
        let message = params["message"] as? String ?? ""
        vlog("status[\(type)] \(message)")
        if type == "ServiceReady" || type == "Started" {
            if !sawReady { sawReady = true; readySem.signal() }
        }
    case "$/progress":
        if verbose, let value = params["value"] as? [String: Any] {
            vlog("progress \(value["kind"] ?? "?") \(value["title"] ?? value["message"] ?? "")")
        }
    case "window/logMessage", "window/showMessage":
        if verbose { vlog("log: \(params["message"] ?? "")") }
    default: break
    }
}

do { try client.start() } catch { die("failed to launch jdtls: \(error)") }

let startTime = Date()
func remaining() -> Double { max(5, overallTimeout - Date().timeIntervalSince(startTime)) }

// initialize handshake
let initParams: [String: Any] = [
    "processId": NSNull(),
    "rootUri": fileURI(projectPath),
    "workspaceFolders": [["uri": fileURI(projectPath), "name": "spike"]],
    "capabilities": [
        "textDocument": [
            "typeHierarchy": ["dynamicRegistration": true],
            "implementation": ["dynamicRegistration": true],
            "references": ["dynamicRegistration": true],
            "definition": ["dynamicRegistration": true],
        ],
        "window": ["workDoneProgress": true],
    ],
]
vlog("→ initialize")
guard client.request("initialize", initParams, timeout: remaining()) != nil else {
    client.stop(); die("initialize failed / timed out")
}
client.notify("initialized", [:])
print("  initialized. waiting for project import…")

// Wait for ServiceReady, but don't hang forever — fall through to polling.
_ = readySem.wait(timeout: .now() + min(90, remaining()))
if sawReady { print("  jdtls reports project ready.") }
else { print("  no explicit ready signal; polling anyway…") }

// Open the document so jdtls resolves positions against exactly this text.
client.notify("textDocument/didOpen", [
    "textDocument": ["uri": uri, "languageId": "java", "version": 1, "text": content],
])

// Give indexing a beat after didOpen.
Thread.sleep(forTimeInterval: 2.0)

let position: [String: Any] = ["line": pos.line, "character": pos.char]
let docPos: [String: Any] = ["textDocument": ["uri": uri], "position": position]

/// Poll a producer until it yields a non-empty result or we run out of time —
/// covers the window where the server is up but still indexing.
func poll<T>(_ label: String, _ f: () -> [T]?) -> [T] {
    while remaining() > 6 {
        if let r = f(), !r.isEmpty { return r }
        vlog("\(label): empty, retrying…")
        Thread.sleep(forTimeInterval: 2.0)
    }
    return []
}

switch query {
case "subtypes", "supertypes":
    // prepareTypeHierarchy → typeHierarchy/{sub,super}types
    let items = poll("prepareTypeHierarchy") { () -> [[String: Any]]? in
        client.request("textDocument/prepareTypeHierarchy", docPos, timeout: 20) as? [[String: Any]]
    }
    guard let item = items.first else { print("\nNo type-hierarchy item at that position."); client.stop(); exit(2) }
    print("\nType hierarchy for: \((item["name"] as? String) ?? "?")")
    let dir = query == "subtypes" ? "typeHierarchy/subtypes" : "typeHierarchy/supertypes"
    let related = poll(dir) { () -> [[String: Any]]? in
        client.request(dir, ["item": item], timeout: 20) as? [[String: Any]]
    }
    print(query == "subtypes" ? "Subtypes (\(related.count)):" : "Supertypes (\(related.count)):")
    for r in related.sorted(by: { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }) {
        print(fmtLocation(r))
    }

case "implementation":
    let locs = poll("textDocument/implementation") { () -> [[String: Any]]? in
        client.request("textDocument/implementation", docPos, timeout: 20) as? [[String: Any]]
    }
    print("\nImplementations (\(locs.count)):")
    for l in locs.sorted(by: { fmtLocation($0) < fmtLocation($1) }) { print(fmtLocation(l)) }

case "references":
    var params = docPos
    params["context"] = ["includeDeclaration": true]
    let locs = poll("textDocument/references") { () -> [[String: Any]]? in
        client.request("textDocument/references", params, timeout: 20) as? [[String: Any]]
    }
    print("\nReferences (\(locs.count)):")
    for l in locs.sorted(by: { fmtLocation($0) < fmtLocation($1) }) { print(fmtLocation(l)) }

default:
    print("unknown --query \(query); use subtypes|supertypes|implementation|references")
}

print("  ----\n  done in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
_ = client.request("shutdown", NSNull(), timeout: 5)
client.notify("exit", [:])
client.stop()
exit(0)
