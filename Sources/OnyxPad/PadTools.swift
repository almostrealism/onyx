//
// PadTools.swift
//
// Responsibility: The panels an iPad window shows beside its terminal —
//                 the host's monitor, files, git and an editor — as the
//                 Mac's own managers (OnyxCore), pointed at the host of the
//                 terminal in front.
// Scope: One per window. It is the managers' RemoteEnvironment.
// Threading: Main thread.
//
// The Mac answers the managers' gates with its ConnectionPair; an iPad has
// one built-in connection per host and answers them itself: a host is
// usable when it has a route, a poll already in flight is skipped, and a
// connection failure drops the connection so the next call makes a new one.
//

import Foundation
import Combine
import OnyxCore
import OnyxSSH

public final class PadTools: ObservableObject, RemoteEnvironment {

    public enum Panel: String, CaseIterable, Identifiable {
        case note, monitor, files, git
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .note: return "Note"
            case .monitor: return "Monitor"
            case .files: return "Files"
            case .git: return "Git"
            }
        }
    }

    @Published public var panel: Panel = .note
    /// The host the panels show: the front terminal's.
    @Published public private(set) var host: PadHost?

    // Lazy, so they can be handed this window as their environment.
    public private(set) lazy var monitor = MonitorManager(appState: self)
    public private(set) lazy var files = FileBrowserManager(appState: self, savedFoldersURL: foldersURL)
    public private(set) lazy var editor = FileEditorManager(appState: self)
    public var git: GitManager { files.gitManager }

    private let nio: NIOTransport
    private let foldersURL: URL
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let healthSubject = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []
    /// Each host's home folder, once asked.
    private var homes: [UUID: String] = [:]

    public init(transport: NIOTransport, foldersURL: URL) {
        nio = transport
        self.foldersURL = foldersURL
        for publisher in [monitor.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          files.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          editor.objectWillChange.map { _ in () }.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Following the front terminal

    /// The terminal in front changed (or there's none).
    public func follow(_ next: PadHost?) {
        guard next?.id != host?.id || next?.route != host?.route else { return }
        host = next
        healthSubject.send()
        monitor.stopPolling()
        files.currentPath = nil
        files.entries = []
        git.clear()
        guard next?.connection != nil else { return }
        showPanel(panel)
    }

    /// Start whatever the panel needs.
    public func showPanel(_ panel: Panel) {
        self.panel = panel
        if panel == .monitor {
            monitor.startPolling()
            monitor.setOverlayVisible(true)
        } else {
            monitor.setOverlayVisible(false)
        }
        if panel == .files || panel == .git, files.currentPath == nil { openHome() }
    }

    /// The host's home folder, asked once.
    public func openHome() {
        guard let host, let connection = host.connection else { return }
        if let home = homes[host.id] { return files.navigateTo(home) }
        let transport = nio
        DispatchQueue.global(qos: .userInitiated).async {
            let out = transport.runCommand("printf '%s' \"$HOME\"", on: connection, timeout: 10, label: "pad:home")
            let home = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard self.host?.id == host.id else { return }
                let path = out.exit == 0 && home.hasPrefix("/") ? home : "/"
                self.homes[host.id] = path
                self.files.navigateTo(path)
            }
        }
    }

    // MARK: - RemoteEnvironment

    public var transport: RemoteTransport { nio }
    public var activeHost: HostConfig? { host?.connection }

    public func hostUsable(_ host: HostConfig?) -> Bool {
        guard let host else { return false }
        return !host.ssh.host.isEmpty
    }

    public func acquireUtilityChannel(_ label: String, host: HostConfig?) -> (() -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard inFlight.insert(label).inserted else { return nil }
        return { [weak self] in
            self?.lock.lock(); self?.inFlight.remove(label); self?.lock.unlock()
        }
    }

    public func reportSSHFailure(host: HostConfig?) {
        if let host { nio.disconnect(host) }
    }

    public var hostHealthChanged: AnyPublisher<Void, Never> { healthSubject.eraseToAnyPublisher() }
}
