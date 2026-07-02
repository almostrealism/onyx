//
// LSPSession.swift
//
// Responsibility: One live connection to a language server (jdtls) over a
//                 clean byte pipe — a spawned `Process` (local shell or ssh)
//                 with a background reader, JSON-RPC request/response
//                 correlation, notification delivery, and auto-answering of
//                 server→client requests. This is the spike's `LSPClient`,
//                 hardened for production and using the tested `LSPProtocol`
//                 framing.
// Scope: Manager-internal. Depends on Services (LSPProtocol) and Foundation.
//        Owned exclusively by LSPManager — one session per workspace.
// Threading: the pipe reader runs off-main; state is guarded by `lock`.
//        Continuations are resolved exactly once (response OR timeout).
//

import Foundation

// @unchecked Sendable: all mutable state (buffer, pending, nextId, stopped) is
// guarded by `lock`; the pipes/process are configured once in start(). We
// synchronize manually, so we opt out of the compiler's automatic checking.
final class LSPSession: @unchecked Sendable {
    private let cmd: String
    private let args: [String]

    private let proc = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    private let lock = NSLock()
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any?, Never>] = [:]
    private var stopped = false

    /// Delivered for server notifications (method, params). Set by the owner.
    var onNotification: ((String, [String: Any]) -> Void)?
    /// Called once when the server process exits.
    var onExit: (() -> Void)?

    /// Serial queue for timeout fallbacks so they never race the reader's lock.
    private let timeoutQueue = DispatchQueue(label: "com.onyx.lsp.timeout")

    init(cmd: String, args: [String]) {
        self.cmd = cmd
        self.args = args
    }

    var isRunning: Bool { proc.isRunning }

    // MARK: lifecycle

    func start() throws {
        proc.executableURL = URL(fileURLWithPath: cmd)
        proc.arguments = args
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            if data.isEmpty { return }   // EOF handled via terminationHandler
            self.feed(data)
        }
        // Drain stderr so the pipe never fills and blocks the server.
        errPipe.fileHandleForReading.readabilityHandler = { fh in _ = fh.availableData }

        proc.terminationHandler = { [weak self] _ in
            self?.handleExit()
        }
        try proc.run()
    }

    /// Ask the server to shut down cleanly, then tear the process down.
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()

        if proc.isRunning {
            notify("exit", [:])   // best-effort; caller sends shutdown first
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
        // Fail any in-flight requests so awaiters don't hang forever.
        failAllPending()
    }

    private func handleExit() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        failAllPending()
        onExit?()
    }

    private func failAllPending() {
        lock.lock()
        let conts = pending
        pending.removeAll()
        lock.unlock()
        for (_, c) in conts { c.resume(returning: nil) }
    }

    // MARK: reading

    private func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let messages = LSPProtocol.decode(&buffer)
        lock.unlock()
        for msg in messages { dispatch(msg) }
    }

    private func dispatch(_ msg: [String: Any]) {
        // Response to one of our requests: has an id, no method.
        if let id = msg["id"] as? Int, msg["method"] == nil {
            resolve(id, msg["result"] ?? msg["error"])
            return
        }
        guard let method = msg["method"] as? String else { return }
        if let id = msg["id"] {
            answerServerRequest(id: id, method: method)   // server→client request
        } else {
            onNotification?(method, msg["params"] as? [String: Any] ?? [:])
        }
    }

    /// Some server→client requests MUST be answered or jdtls stalls
    /// (spike finding #3). Minimal/null replies are accepted.
    private func answerServerRequest(id: Any, method: String) {
        let result: Any
        switch method {
        case "workspace/configuration":
            result = [[String: Any]()]        // one (empty) settings object per item
        case "workspace/applyEdit":
            result = ["applied": false]
        default:
            result = NSNull()                 // registerCapability, progress/create, …
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: sending

    private func send(_ obj: [String: Any]) {
        guard let data = LSPProtocol.encode(obj) else { return }
        // Writes are serialized by the pipe; guard against post-stop writes.
        lock.lock(); let dead = stopped && !proc.isRunning; lock.unlock()
        if dead { return }
        inPipe.fileHandleForWriting.write(data)
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Allocate the next request id under the lock. Synchronous (NSLock is
    /// unavailable from async contexts, and we never hold it across an await).
    private func allocateId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId; nextId += 1
        return id
    }

    /// Send a request and await its result (or nil on timeout / server death).
    /// The continuation is resolved exactly once — by the response or the
    /// timeout, whichever comes first.
    func request(_ method: String, _ params: Any, timeout: TimeInterval) async -> Any? {
        let id = allocateId()
        return await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
            lock.lock()
            if stopped {
                lock.unlock()
                cont.resume(returning: nil)
                return
            }
            pending[id] = cont
            lock.unlock()

            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])

            timeoutQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, nil)
            }
        }
    }

    /// Atomically hand the pending continuation for `id` its value. Whichever
    /// caller (response or timeout) removes it first resumes it; the loser is
    /// a no-op.
    private func resolve(_ id: Int, _ value: Any?) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(returning: value)
    }
}
