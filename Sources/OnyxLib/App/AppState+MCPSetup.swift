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
import AppKit

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

    @available(*, deprecated, message: "Use installMCPOnActiveHost — one install does hooks too")
    public func setupClaudeHooks() {
        guard let host = activeHost else {
            hooksSetupStatus = "No active host"
            return
        }

        hooksSetupStatus = "Setting up hooks on \(host.label)..."

        // Find the local OnyxMCP binary
        let possiblePaths = [
            Bundle.main.bundlePath + "/Contents/MacOS/OnyxMCP",
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.onyx/bin/OnyxMCP" },
            Optional("/Users/Shared/flowtree/tools/OnyxMCP"),
        ].compactMap { $0 }

        let localBinary = possiblePaths.first { FileManager.default.isExecutableFile(atPath: $0) }

        // Also check the build directory
        let buildBinary = localBinary ?? {
            let buildDir = (ProcessInfo.processInfo.environment["PWD"] ?? "") + "/.build/debug/OnyxMCP"
            return FileManager.default.isExecutableFile(atPath: buildDir) ? buildDir : nil
        }()

        guard let binary = buildBinary else {
            let searched = possiblePaths.joined(separator: ", ")
            hooksSetupStatus = "OnyxMCP not found. Run install-mcp.sh first. Searched: \(searched)"
            clearStatusAfterDelay()
            return
        }

        print("setupClaudeHooks: using binary at \(binary) for \(host.label)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if host.isLocal {
                // Local setup — just configure hooks
                self.configureHooksLocally(binary: binary)
            } else {
                // Remote setup — copy binary then configure
                self.configureHooksRemotely(host: host, localBinary: binary)
            }
        }
    }

    private func configureHooksLocally(binary: String) {
        let hookCmd = binary + " --hook"
        let hooksJson = buildHooksJson(hookCmd: hookCmd)

        let settingsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let settingsFile = settingsDir.appendingPathComponent("settings.json")

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        if let hooksObj = try? JSONSerialization.jsonObject(with: Data(hooksJson.utf8)) {
            settings["hooks"] = hooksObj
        }

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) {
            try? data.write(to: settingsFile)
        }

        DispatchQueue.main.async {
            self.hooksSetupStatus = "Hooks configured for local Claude Code"
            self.clearStatusAfterDelay()
        }
    }

    /// Run a process and capture stderr for error reporting
    private func runCapturingError(_ executable: String, args: [String]) -> (exitCode: Int32, stderr: String) {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, errStr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func configureHooksRemotely(host: HostConfig, localBinary: String) {
        let remoteBin = ".onyx/bin/OnyxMCP"
        let hookCmd = "$HOME/.onyx/bin/OnyxMCP --hook"

        // Step 1: Create remote directory
        DispatchQueue.main.async { self.hooksSetupStatus = "Creating ~/.onyx/bin on \(host.label)..." }

        let (mkCmd, mkArgs) = remoteCommand("mkdir -p ~/.onyx/bin", host: host)
        let mkResult = runCapturingError(mkCmd, args: mkArgs)
        if mkResult.exitCode != 0 {
            DispatchQueue.main.async {
                self.hooksSetupStatus = "Failed to create directory on \(host.label): \(mkResult.stderr)"
                self.clearStatusAfterDelay()
            }
            return
        }

        // Step 2: SCP the binary
        DispatchQueue.main.async { self.hooksSetupStatus = "Uploading OnyxMCP to \(host.label)..." }

        var scpArgs = scpBaseArgs(for: host)
        scpArgs.append(localBinary)
        scpArgs.append("\(sshUserHost(for: host)):~/\(remoteBin)")
        let scpResult = runCapturingError("/usr/bin/scp", args: scpArgs)

        guard scpResult.exitCode == 0 else {
            let detail = scpResult.stderr.isEmpty ? "exit code \(scpResult.exitCode)" : scpResult.stderr
            DispatchQueue.main.async {
                self.hooksSetupStatus = "Upload failed: \(detail)"
                self.clearStatusAfterDelay()
            }
            return
        }

        // Step 3: chmod +x
        let (chCmd, chArgs) = remoteCommand("chmod +x ~/\(remoteBin)", host: host)
        _ = runCapturingError(chCmd, args: chArgs)

        // Step 2: Configure hooks by writing a JSON file and a setup script,
        // then SCPing both to the remote and executing the script.
        // This avoids all shell quoting issues with inline JSON.
        DispatchQueue.main.async { self.hooksSetupStatus = "Configuring hooks on \(host.label)..." }

        let hooksJson = buildHooksJson(hookCmd: hookCmd)

        // Write files to a temp directory locally
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-hooks-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksFile = tmpDir.appendingPathComponent("hooks.json")
        try? hooksJson.write(to: hooksFile, atomically: true, encoding: .utf8)

        let setupScript = tmpDir.appendingPathComponent("setup.sh")
        let scriptContent = """
        #!/bin/sh
        mkdir -p ~/.claude
        HOOKS_FILE=~/.onyx/hooks.json
        if [ -f ~/.claude/settings.json ] && command -v python3 >/dev/null 2>&1; then
            python3 -c "
        import json
        with open('$HOOKS_FILE') as hf:
            hooks = json.load(hf)
        try:
            with open('$HOME/.claude/settings.json') as sf:
                settings = json.load(sf)
        except:
            settings = {}
        settings['hooks'] = hooks
        with open('$HOME/.claude/settings.json', 'w') as sf:
            json.dump(settings, sf, indent=2)
            sf.write('\\n')
        "
        elif [ -f ~/.claude/settings.json ] && command -v jq >/dev/null 2>&1; then
            TMP=$(mktemp)
            jq --slurpfile hooks "$HOOKS_FILE" '.hooks = $hooks[0]' ~/.claude/settings.json > "$TMP" && mv "$TMP" ~/.claude/settings.json
        else
            echo '{"hooks": '$(cat "$HOOKS_FILE")'}' > ~/.claude/settings.json
        fi
        rm -f "$HOOKS_FILE"
        """
        try? scriptContent.write(to: setupScript, atomically: true, encoding: .utf8)

        // SCP the hooks JSON to remote ~/.onyx/hooks.json
        var scpHooksArgs = scpBaseArgs(for: host)
        scpHooksArgs.append(hooksFile.path)
        scpHooksArgs.append("\(sshUserHost(for: host)):~/.onyx/hooks.json")
        let scpHooksResult = runCapturingError("/usr/bin/scp", args: scpHooksArgs)
        guard scpHooksResult.exitCode == 0 else {
            DispatchQueue.main.async {
                self.hooksSetupStatus = "Failed to upload hooks config: \(scpHooksResult.stderr)"
                self.clearStatusAfterDelay()
            }
            return
        }

        // SCP the setup script
        var scpScriptArgs = scpBaseArgs(for: host)
        scpScriptArgs.append(setupScript.path)
        scpScriptArgs.append("\(sshUserHost(for: host)):~/.onyx/setup-hooks.sh")
        _ = runCapturingError("/usr/bin/scp", args: scpScriptArgs)

        // Execute the setup script remotely
        let (cfgCmd, cfgArgs) = remoteCommand("sh ~/.onyx/setup-hooks.sh && rm -f ~/.onyx/setup-hooks.sh", host: host)
        let cfgResult = runCapturingError(cfgCmd, args: cfgArgs)

        DispatchQueue.main.async {
            if cfgResult.exitCode == 0 {
                self.hooksSetupStatus = "Hooks configured on \(host.label)"
            } else {
                let detail = cfgResult.stderr.isEmpty ? "exit code \(cfgResult.exitCode)" : cfgResult.stderr
                self.hooksSetupStatus = "Hook config failed: \(detail)"
            }
            self.clearStatusAfterDelay()
        }
    }

    private func buildHooksJson(hookCmd: String) -> String {
        // Each event type passes its name as a CLI arg so OnyxMCP can tag
        // the JSON-RPC payload and the desktop routes the event correctly.
        //
        // PermissionRequest fires ONLY when Claude would show a permission
        // prompt — meaning auto-allowed tools DON'T trigger it — so gating
        // it naturally respects the user's existing allow/deny rules.
        // The 120s timeout lets the user respond in the Onyx UI.
        //
        // PreToolUse/PostToolUse track session activity for the monitor.
        // SessionStart/Stop track session lifecycle.
        """
        {"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"\(hookCmd) PreToolUse","timeout":10}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"\(hookCmd) PostToolUse","timeout":5}]}],"PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"\(hookCmd) PermissionRequest","timeout":120}]}],"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\(hookCmd) SessionStart","timeout":5}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"\(hookCmd) Stop","timeout":5}]}]}
        """
    }

    func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.hooksSetupStatus = nil
        }
    }
}
