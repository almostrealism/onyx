//
// AppState+MCPSetup.swift
//
// Responsibility: Putting the OnyxMCP bridge on a host from the app —
//                 finding the bundled binary, uploading it, wiring Claude
//                 Code's hooks to it, and reporting what happened.
// Scope: An extension on AppState; the per-host status and the shell that
//        does the work live in MCPInstaller.
//
// Split out of AppState.swift, which had grown past the point where the
// file could be read as one thing. Nothing here changed in the move.
//

import Foundation
import OnyxCore

extension AppState {

    /// Install OnyxMCP and configure Claude Code hooks on the active host.
    /// Copies the binary from the local app bundle and configures hooks via SSH.
    /// Install the MCP bridge on the active host and wire Claude Code to
    /// it. The status line reports progress; the monitor's CONNECTIONS
    /// section shows the result per host afterwards.
    public func installMCPOnActiveHost() {
        guard let host = activeHost else {
            hooksSetupStatus = "No active host"
            clearStatusAfterDelay()
            return
        }
        hooksSetupStatus = "Installing Onyx MCP on \(host.label)…"
        MCPInstaller.shared.install(host: host, appState: self) { [weak self] ok in
            guard let self else { return }
            let status = MCPInstaller.shared.status(for: host)
            self.hooksSetupStatus = ok
                ? "Onyx MCP ready on \(host.label) — \(status.label)"
                : (MCPInstaller.shared.progress[host.id] ?? "Install failed on \(host.label)")
            self.clearStatusAfterDelay()
        }
    }

    func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.hooksSetupStatus = nil
        }
    }
}
