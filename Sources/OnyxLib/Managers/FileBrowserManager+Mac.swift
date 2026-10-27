//
// FileBrowserManager+Mac.swift
//
// Responsibility: The file browser's Mac-only half — the save panel a
//                 download asks for, Finder's pasteboard, and the Java
//                 dependency graph (an artifact, which only the Mac has).
//                 The browser itself is OnyxCore's, shared with the iPad.
//

import Foundation
import AppKit
import OnyxCore

extension FileBrowserManager {

    /// The files on a pasteboard — what Finder puts there on ⌘C. Empty
    /// when it holds anything else, text included.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        fileURLs(in: pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]))
    }

    /// Download entry.
    public func downloadEntry(_ entry: RemoteEntry) {
        guard let path = fullPath(of: entry) else { return }
        downloadPath(path, isDirectory: entry.isDirectory)
    }

    /// Ask where, then download.
    public func downloadPath(_ remotePath: String, isDirectory: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (remotePath as NSString).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destURL = panel.url else { return }
        download(remotePath, isDirectory: isDirectory, to: destURL)
    }

    /// Analyze Java dependency graph and show as artifact diagram
    public func analyzeDependencies(repoPath: String, appState: AppState) {
        depsStatus = "Analyzing dependencies..."
        print("analyzeDependencies: starting for \(repoPath)")

        let analyzer = DependencyAnalyzer(appState: appState)
        analyzer.analyze(repoPath: repoPath) { [weak self] mermaid in
            if let mermaid = mermaid, !mermaid.isEmpty {
                print("analyzeDependencies: got \(mermaid.count) chars of Mermaid")
                let content = ArtifactContent.diagram(content: mermaid, format: .mermaid)
                _ = appState.artifactManager.setSlot(0, title: "Dependency Graph", content: content)
                appState.activeRightPanel = .artifacts
                self?.depsStatus = nil
            } else {
                print("analyzeDependencies: no output returned")
                self?.depsStatus = "No dependency data (need python3 + Java files)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self?.depsStatus?.hasPrefix("No dep") == true {
                        self?.depsStatus = nil
                    }
                }
            }
        }
    }

}
