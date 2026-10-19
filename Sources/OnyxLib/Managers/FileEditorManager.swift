//
// FileEditorManager.swift
//
// Responsibility: Editing one file from the file browser by hand: load it
//                 as exact bytes, keep the edited text, save it back
//                 without clobbering a change made on the host meanwhile.
// Scope: Per window. The rules — what may be edited, the paths, the
//        commit script — are RemoteFileEdit's; this runs them.
//

import Foundation

public final class FileEditorManager: ObservableObject {

    public enum Phase: Equatable {
        case loading
        case editing
        case saving
        /// The file changed on the host since it was opened (or is gone).
        /// Saving now would throw that change away, so it waits for the
        /// user: overwrite, or reload and lose the edits here.
        case conflict
        /// Can't be edited at all — too big, not text, unreadable.
        case refused(String)
    }

    /// Nil when no editor is open.
    @Published public private(set) var path: String?
    @Published public private(set) var hostLabel = ""
    @Published public private(set) var phase: Phase = .loading
    /// The text being edited. The view binds to it.
    @Published public var text = ""
    /// The last save's problem, shown until the next attempt.
    @Published public private(set) var saveError: String?
    @Published public private(set) var lastSaved: Date?
    /// Closing was asked for with unsaved edits; the view asks whether to
    /// discard them.
    @Published public var confirmingDiscard = false

    /// The bytes as opened or last saved — what "unchanged" means, and
    /// what the host's copy must still be for a save to go ahead.
    private var original = Data()
    private var host: HostConfig?
    private let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var isOpen: Bool { path != nil }
    public var isDirty: Bool { phase != .loading && Data(text.utf8) != original }
    public var fileName: String { (path.map { ($0 as NSString).lastPathComponent }) ?? "" }

    // MARK: Open / close

    public func open(path: String, host: HostConfig?) {
        self.path = path
        self.host = host
        hostLabel = host?.label ?? "this Mac"
        phase = .loading
        text = ""
        original = Data()
        saveError = nil
        lastSaved = nil
        confirmingDiscard = false
        load()
    }

    public func close() {
        confirmingDiscard = false
        path = nil
        text = ""
        original = Data()
    }

    /// Throw away the edits and read the host's copy again.
    public func reload() {
        guard path != nil else { return }
        phase = .loading
        saveError = nil
        load()
    }

    private func load() {
        guard let path else { return }
        let host = self.host
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.fetch(path, host: host)
            DispatchQueue.main.async {
                guard self.path == path else { return }   // closed or reopened meanwhile
                switch result {
                case .failure(let message):
                    self.phase = .refused(message)
                case .success(let data):
                    if let refusal = RemoteFileEdit.refusal(for: data) {
                        self.phase = .refused(refusal)
                        return
                    }
                    self.original = data
                    self.text = RemoteFileEdit.decode(data) ?? ""
                    self.phase = .editing
                }
            }
        }
    }

    // MARK: Save

    /// Save, unless the host's copy changed since it was opened — then
    /// stop at `.conflict` and let the user choose.
    public func save() { save(overwrite: false) }

    /// Save over whatever the host has now.
    public func overwrite() { save(overwrite: true) }

    private func save(overwrite: Bool) {
        guard let path, phase == .editing || phase == .conflict else { return }
        let host = self.host
        let expected = original
        let data = Data(text.utf8)
        phase = .saving
        saveError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome: SaveOutcome
            if overwrite {
                outcome = self.write(data, to: path, host: host)
            } else {
                switch self.fetch(path, host: host) {
                case .success(let current):
                    outcome = current == expected ? self.write(data, to: path, host: host) : .conflict
                case .failure(let message):
                    // Not proof of a change — the connection may have
                    // blinked — so say what happened instead.
                    outcome = .failed("Couldn't check the host's copy before saving, so nothing was written: \(message)")
                }
            }
            DispatchQueue.main.async {
                guard self.path == path else { return }
                switch outcome {
                case .saved:
                    self.original = data
                    self.lastSaved = Date()
                    self.phase = .editing
                case .conflict:
                    self.phase = .conflict
                case .failed(let message):
                    self.saveError = message
                    self.phase = .editing
                }
            }
        }
    }

    private enum SaveOutcome { case saved, conflict, failed(String) }

    // MARK: Transport

    private enum Fetch { case success(Data), failure(String) }

    /// The file's exact bytes.
    private func fetch(_ path: String, host: HostConfig?) -> Fetch {
        guard let host, !host.isLocal else {
            let expanded = (path as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: expanded) else {
                return .failure("Couldn't read \(path).")
            }
            return .success(data)
        }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        let (cmd, args) = appState.scpFetchCommand(remotePath: RemoteFileEdit.scpPath(path),
                                                   localPath: local.path, host: host)
        let result = RemoteExec.shared.run(cmd, args: args, softTimeout: 30,
                                           captureStderr: true, label: "editor fetch")
        guard result.exit == 0, let data = FileManager.default.contents(atPath: local.path) else {
            if result.exit == 255 { appState.reportSSHFailure(host: host) }
            let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(said.isEmpty ? "Couldn't read \(path) from \(host.label)." : said)
        }
        return .success(data)
    }

    private func write(_ data: Data, to path: String, host: HostConfig?) -> SaveOutcome {
        guard let host, !host.isLocal else {
            // Written in place, not replaced, so the file keeps its
            // permissions and links — the same reason as `cat` remotely.
            let expanded = (path as NSString).expandingTildeInPath
            guard let handle = FileHandle(forWritingAtPath: expanded) else {
                return .failed("Couldn't open \(path) for writing.")
            }
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.close()
                return .saved
            } catch {
                return .failed("Couldn't write \(path): \(error.localizedDescription)")
            }
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let temporary = RemoteFileEdit.temporaryPath(for: path, token: token)
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-save-\(token)")
        defer { try? FileManager.default.removeItem(at: local) }
        do { try data.write(to: local) } catch {
            return .failed("Couldn't stage the file locally: \(error.localizedDescription)")
        }

        let (cmd, args) = appState.scpCommand(localPath: local.path,
                                              remotePath: RemoteFileEdit.scpPath(temporary),
                                              host: host)
        let upload = RemoteExec.shared.run(cmd, args: args, softTimeout: 60,
                                           captureStderr: true, label: "editor upload")
        guard upload.exit == 0 else {
            if upload.exit == 255 { appState.reportSSHFailure(host: host) }
            let said = upload.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(said.isEmpty ? "Upload to \(host.label) failed; nothing was changed." : said)
        }

        let run = FileBrowserManager.runScriptWithFallback(
            RemoteFileEdit.commitScript(temporary: temporary, target: path),
            appState: appState, host: host, timeout: 20)
        guard let output = run.cleaned, output.contains(RemoteFileEdit.savedMarker) else {
            let said = run.hostSaid ?? "no reply"
            return .failed("Uploaded, but couldn't put it in place (\(said)). "
                           + "The new version is beside the file as \((temporary as NSString).lastPathComponent).")
        }
        return .saved
    }
}
