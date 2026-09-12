//
// MCPInstaller.swift
//
// Responsibility: Putting the OnyxMCP bridge on a host and wiring Claude
//                 Code to it — detect the platform, upload the matching
//                 bundled binary, merge settings.json, verify it runs —
//                 and reporting per-host status afterwards.
// Scope: Shared singleton; installs are per host and rare, status is
//        polled for the monitor overlay.
// Threading: work on a utility queue, @Published state on main.
//
// Replaces the old "setup hooks" action. That uploaded the same binary
// and wrote the same file, so a host could have had one run and not the
// other with nothing to say which — and hooks without the MCP
// registration is a half-installed state nobody asked for. One install
// does both.
//
// Every step reports what actually happened, in the remote's own words.
// A silent install that didn't work is the failure mode this whole area
// keeps producing, and the status indicator exists so it can't hide.
//

import Foundation

/// What the app knows about the bridge on one host.
public struct MCPHostStatus: Equatable {
    public enum State: Equatable {
        /// Never checked, or the host isn't reachable to check.
        case unknown
        /// Checked, and there's no bridge there.
        case notInstalled
        /// Installed, runs, and reports this version.
        case installed(version: String)
        /// Installed and working, but older than the bridge this build
        /// carries. Worth saying out loud: the app and the bridge are
        /// versioned together, and a fix to one usually needs the other.
        case outdated(version: String)
        /// Installed but something is wrong — the message is the remote's.
        case broken(String)
        /// This build carries no binary for that platform.
        case unsupported(platform: String)
    }

    public var state: State
    public var checkedAt: Date?
    /// Where the binary is, once we know.
    public var path: String?

    public init(state: State = .unknown, checkedAt: Date? = nil, path: String? = nil) {
        self.state = state
        self.checkedAt = checkedAt
        self.path = path
    }

    public var isWorking: Bool {
        switch state {
        case .installed, .outdated: return true
        default:                    return false
        }
    }

    /// Short label for the monitor overlay.
    public var label: String {
        switch state {
        case .unknown:                 return "unknown"
        case .notInstalled:            return "not installed"
        case .installed(let v):        return v
        case .outdated(let v):         return "\(v) — update available"
        case .broken:                  return "broken"
        case .unsupported(let p):      return "no binary for \(p)"
        }
    }
}

/// What to tell the user about other accounts on a machine, once an
/// install succeeds.
public struct MultiUserHint: Identifiable, Equatable {
    public let id = UUID()
    public let host: String
    /// False when the bridge landed in a home directory, where no other
    /// account can reach it.
    public let isShared: Bool
    /// The command another account runs to adopt the shared install.
    public let command: String
}

public final class MCPInstaller: ObservableObject {
    public static let shared = MCPInstaller()

    /// hostID → what we know.
    @Published public private(set) var status: [UUID: MCPHostStatus] = [:]
    /// hostID → a line describing what's happening right now, while an
    /// install runs. Nil when idle.
    @Published public private(set) var progress: [UUID: String] = [:]
    /// Set after a successful install; the UI shows it once and clears it.
    @Published public var multiUserHint: MultiUserHint?

    private let queue = DispatchQueue(label: "com.onyx.mcp-installer", qos: .utility)

    private init() {}

    public func status(for host: HostConfig) -> MCPHostStatus {
        status[host.id] ?? MCPHostStatus()
    }

    // MARK: - Detection

    /// Ask a host what it is and whether the bridge is already there.
    ///
    /// One round trip for both questions: this runs on the monitor's
    /// cadence across every host, and two commands per host per cycle is
    /// how a poller becomes a problem.
    public func refresh(host: HostConfig, appState: AppState) {
        guard appState.hostUsable(host) else {
            setStatus(MCPHostStatus(state: .unknown), for: host.id)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard let release = appState.acquireUtilityChannel("mcpStatus:\(host.id)",
                                                              host: host) else { return }
            defer { release() }

            let script = """
            \(MCPInstall.sharedOrHomeScript)
            echo "---UNAME---"; uname -s; uname -m
            echo "---BASE---"; echo "$SHARED_OR_HOME"
            B="$SHARED_OR_HOME/\(MCPInstall.relativeBinaryPath)"
            echo "---BIN---"
            if [ -x "$B" ]; then "$B" --version 2>&1 || echo "FAILED"; else echo "ABSENT"; fi
            \(Self.claudePickerScript)
            echo "---REG---"
            if [ -n "$ONYX_CLAUDE" ]; then
                "$ONYX_CLAUDE" mcp get onyx </dev/null >/dev/null 2>&1 \
                    && echo "REGISTERED" || echo "UNREGISTERED"
            else
                echo "NO_CLAUDE"
            fi
            """
            let (cmd, args, stdin) = appState.remoteScriptNoTTY(script, host: host)
            let result = RemoteExec.shared.run(cmd, args: args, stdin: stdin,
                                               softTimeout: 20,
                                               captureStdout: true, captureStderr: true,
                                               label: "mcpStatus:\(host.label)")
            let output = RemoteScript.cleanedOutput(result.stdout + result.stderr)
            self.setStatus(Self.parseStatus(output), for: host.id)
        }
    }

/// Find a `claude` that actually runs.
    ///
    /// A machine can carry more than one install — a Homebrew one under
    /// /opt/homebrew and a stale npm-global one under /usr/local — and
    /// PATH order decides which you get. On mac-studio ours resolved to
    /// the /usr/local one, which crashed inside cli.js, while the user's
    /// own shell found the Homebrew one and worked. Same command, same
    /// host, different binary.
    ///
    /// So PATH is honoured FIRST — it is the user's own answer — and
    /// only if that one can't even print its version do we look in the
    /// usual places. The criterion is "it runs", not "it exists".
    static let claudePickerScript = """
    ONYX_CLAUDE=""
    for c in "$(command -v claude 2>/dev/null)" /opt/homebrew/bin/claude \
             /usr/local/bin/claude "$HOME/.local/bin/claude"; do
        [ -n "$c" ] && [ -x "$c" ] || continue
        "$c" --version </dev/null >/dev/null 2>&1 || continue
        ONYX_CLAUDE="$c"
        break
    done
    """

    /// Read the detection script's output.
    ///
    /// Sections are found by their LAST occurrence: an interactive remote
    /// shell echoes the script back interleaved with its output, so the
    /// first "---BIN---" in the stream is frequently the echo of the line
    /// rather than the result of running it.
    static func parseStatus(_ output: String) -> MCPHostStatus {
        func section(_ marker: String) -> [String] {
            guard let range = output.range(of: marker, options: .backwards) else { return [] }
            let rest = output[range.upperBound...]
            let stop = rest.range(of: "---")?.lowerBound ?? rest.endIndex
            return rest[..<stop]
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let uname = section("---UNAME---")
        guard uname.count >= 2,
              let platform = RemotePlatform.parse(uname: uname[0], machine: uname[1]) else {
            return MCPHostStatus(state: .unknown, checkedAt: Date())
        }

        let base = section("---BASE---").first
        let path = base.map { MCPInstall.binaryPath(base: $0) }
        let bin = section("---BIN---")

        guard let first = bin.first else {
            return MCPHostStatus(state: .unknown, checkedAt: Date(), path: path)
        }
        if first == "ABSENT" {
            return MCPHostStatus(state: .notInstalled, checkedAt: Date(), path: path)
        }
        if first.hasPrefix("OnyxMCP ") {
            let version = String(first.dropFirst("OnyxMCP ".count))
            // The binary running is not the question. Claude Code has to
            // KNOW about it, and it reads MCP servers from ~/.claude.json
            // — which is why the previous version of this reported
            // success on hosts where Claude never listed the server.
            switch section("---REG---").first {
            case "REGISTERED":
                return MCPHostStatus(
                    state: version == MCPInstall.currentVersion
                        ? .installed(version: version)
                        : .outdated(version: version),
                    checkedAt: Date(), path: path)
            case "NO_CLAUDE":
                return MCPHostStatus(state: .broken("installed, but Claude Code isn't on this host"),
                                     checkedAt: Date(), path: path)
            case "UNREGISTERED":
                return MCPHostStatus(state: .broken("installed but not registered with Claude"),
                                     checkedAt: Date(), path: path)
            default:
                // No answer at all — say installed rather than inventing a
                // failure we didn't observe.
                return MCPHostStatus(state: .installed(version: version),
                                     checkedAt: Date(), path: path)
            }
        }
        // It's there and it didn't answer — report what it said instead of
        // calling it "not installed", which would send someone to install
        // a binary that's already sitting there failing.
        _ = platform
        return MCPHostStatus(state: .broken(first), checkedAt: Date(), path: path)
    }

    // MARK: - Install

    /// Install (or reinstall) the bridge and wire Claude Code to it.
    public func install(host: HostConfig, appState: AppState,
                        completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.performInstall(host: host, appState: appState)
            DispatchQueue.main.async {
                self.progress[host.id] = nil
                completion?(ok)
            }
            self.refresh(host: host, appState: appState)
        }
    }

    private func performInstall(host: HostConfig, appState: AppState) -> Bool {
        report("Checking \(host.label)…", for: host.id)

        guard appState.hostUsable(host) else {
            fail("\(host.label) isn't reachable", for: host.id)
            return false
        }
        guard let release = appState.acquireUtilityChannel("mcpInstall:\(host.id)",
                                                          host: host) else {
            fail("\(host.label) is busy — try again in a moment", for: host.id)
            return false
        }
        defer { release() }

        // 1. What is it, and where should this go?
        let probe = """
        \(MCPInstall.sharedOrHomeScript)
        echo "---UNAME---"; uname -s; uname -m
        echo "---BASE---"; echo "$SHARED_OR_HOME"
        """
        let (pcmd, pargs, pstdin) = appState.remoteScriptNoTTY(probe, host: host)
        let probed = RemoteExec.shared.run(pcmd, args: pargs, stdin: pstdin,
                                           softTimeout: 20,
                                           captureStdout: true, captureStderr: true,
                                           label: "mcpProbe:\(host.label)")
        let probeOut = RemoteScript.cleanedOutput(probed.stdout + probed.stderr)
        let status = Self.parseStatus(probeOut + "\n---BIN---\nABSENT")
        guard let base = status.path.map({ String($0.dropLast("/\(MCPInstall.relativeBinaryPath)".count)) }),
              case .notInstalled = status.state else {
            fail("Couldn't work out what \(host.label) is: \(RemoteScript.remoteComplaint(in: probeOut) ?? "no usable uname output")",
                 for: host.id)
            return false
        }

        let unameLines = probeOut.components(separatedBy: "---UNAME---").last?
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard unameLines.count >= 2,
              let platform = RemotePlatform.parse(uname: unameLines[0], machine: unameLines[1]) else {
            fail("\(host.label) reported an architecture Onyx doesn't recognise", for: host.id)
            return false
        }

        // 2. Do we even carry a binary for it?
        guard let localBinary = appState.bundledMCPBinary(for: platform) else {
            setStatus(MCPHostStatus(state: .unsupported(platform: platform.label),
                                    checkedAt: Date()), for: host.id)
            fail("This build has no bridge for \(platform.label)", for: host.id)
            return false
        }

        let remotePath = MCPInstall.binaryPath(base: base)
        report("Uploading the bridge to \(host.label) (\(platform.label))…", for: host.id)

        // 3. Upload beside the destination, then move into place. A bridge
        //    that's half-uploaded is worse than one that's absent: Claude
        //    would run a truncated file and fail in a way that points
        //    nowhere near here.
        let mk = "mkdir -p \"$(dirname \(Self.shellQuote(remotePath)))\""
        let (mkc, mka, mks) = appState.remoteScriptNoTTY(mk, host: host)
        _ = RemoteExec.shared.run(mkc, args: mka, stdin: mks, softTimeout: 20,
                                  captureStdout: false, captureStderr: false,
                                  label: "mcpMkdir:\(host.label)")

        let staging = remotePath + ".new"
        if host.isLocal {
            // localhost is a first-class target — the agent you're wiring
            // up is often the one on this machine. scp would need an ssh
            // daemon and a user@host that a local entry doesn't have, so
            // it's a plain file copy.
            do {
                try? FileManager.default.removeItem(atPath: staging)
                try FileManager.default.copyItem(atPath: localBinary.path, toPath: staging)
            } catch {
                fail("Couldn't copy the bridge into place: \(error.localizedDescription)",
                     for: host.id)
                return false
            }
        } else {
            let (scpCmd, scpArgs) = appState.scpCommandAbsolute(localPath: localBinary.path,
                                                                remotePath: staging,
                                                                host: host)
            let upload = RemoteExec.shared.run(scpCmd, args: scpArgs, stdin: nil,
                                               softTimeout: 180,
                                               captureStdout: true, captureStderr: true,
                                               label: "mcpUpload:\(host.label)")
            guard upload.exit == 0 else {
                let why = (upload.stderr + upload.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                fail("Upload failed: \(why.isEmpty ? "scp exit \(upload.exit)" : why)", for: host.id)
                return false
            }
        }

        report("Configuring Claude Code on \(host.label)…", for: host.id)

        // 4. Move into place, mark executable, verify, and merge settings —
        //    in one script, because each step only makes sense if the one
        //    before it worked.
        // Registration goes through `claude mcp add --scope user`, which
        // writes ~/.claude.json — the file Claude Code actually reads for
        // personal MCP servers. Writing mcpServers into
        // ~/.claude/settings.json (what this used to do) put it somewhere
        // Claude never looks, so the install reported success and the
        // server never appeared. The docs also describe ~/.claude.json as
        // Claude's own file, rewritten by it and holding the OAuth
        // session, so editing it by hand is the wrong tool regardless.
        //
        // Hooks stay in ~/.claude/settings.json, which IS their
        // documented home.
        let install = """
        set -e
        mv \(Self.shellQuote(staging)) \(Self.shellQuote(remotePath))
        chmod +x \(Self.shellQuote(remotePath))
        echo "---RUNS---"
        \(Self.shellQuote(remotePath)) --version
        \(Self.claudePickerScript)
        echo "---REG---"
        if [ -n "$ONYX_CLAUDE" ]; then
            # Remove first so a reinstall that changed the path replaces
            # the old entry instead of failing on a duplicate name.
            "$ONYX_CLAUDE" mcp remove onyx </dev/null >/dev/null 2>&1 || true
            # KEEP the output. Sending it to /dev/null left the app saying
            # "didn't take" with nothing to act on — the failure this
            # codebase keeps re-learning. Whatever claude says is the only
            # thing here worth reading.
            #
            # </dev/null on every claude call. The whole script arrives on
            # the remote shell's STDIN, so anything that reads stdin gets
            # the rest of the script instead of a terminal — and the
            # claude CLI is a Node program that crashed on exactly that:
            # by hand it worked, under Onyx it died inside cli.js. Giving
            # it an empty stdin also stops it eating the lines after it.
            ADD_OUT=$("$ONYX_CLAUDE" mcp add --scope user onyx -- \(Self.shellQuote(remotePath)) </dev/null 2>&1) && ADD_RC=0 || ADD_RC=$?
            GET_OUT=$("$ONYX_CLAUDE" mcp get onyx </dev/null 2>&1) && GET_RC=0 || GET_RC=$?
            if [ "$ADD_RC" = "0" ] && [ "$GET_RC" = "0" ]; then
                echo "REGISTERED"
            elif [ "$ADD_RC" = "0" ]; then
                echo "ADDED_NOT_VISIBLE"
                echo "claude mcp get said: $GET_OUT"
            else
                echo "ADD_FAILED"
                echo "claude mcp add (exit $ADD_RC) said: $ADD_OUT"
            fi
            echo "claude used: $ONYX_CLAUDE"
        else
            echo "NO_CLAUDE"
        fi
        \(Self.settingsMergeScript(binaryPath: remotePath))
        \(Self.multiUserScript(binaryPath: remotePath, base: base))
        echo "---DONE---"
        """
        let (icmd, iargs, istdin) = appState.remoteScriptNoTTY(install, host: host)
        let installed = RemoteExec.shared.run(icmd, args: iargs, stdin: istdin,
                                               softTimeout: 60,
                                               captureStdout: true, captureStderr: true,
                                               label: "mcpInstall:\(host.label)")
        let out = RemoteScript.cleanedOutput(installed.stdout + installed.stderr)

        guard out.range(of: "---DONE---", options: .backwards) != nil else {
            let why = RemoteScript.remoteComplaint(in: out)
                ?? out.components(separatedBy: "\n").last(where: { !$0.isEmpty })
                ?? "no output"
            fail("Install didn't finish on \(host.label): \(why)", for: host.id)
            return false
        }

        // Everything the registration step said, not just its verdict.
        let reg: [String] = {
            guard let r = out.range(of: "---REG---", options: .backwards) else { return [] }
            let rest = out[r.upperBound...]
            let stop = rest.range(of: "---DONE---")?.lowerBound ?? rest.endIndex
            return rest[..<stop]
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }()
        // The verdict is the first line; the rest is why, in claude's own
        // words, plus where the claude it used actually lives — a PATH
        // difference between your shell and ours is a prime suspect when
        // a command works by hand and not from here.
        let detail = reg.dropFirst().joined(separator: " · ")

        switch reg.first {
        case "REGISTERED":
            break
        case "NO_CLAUDE":
            fail("Bridge installed, but the `claude` command isn't on \(host.label)'s PATH for a non-interactive shell — nothing to register with",
                 for: host.id)
            return false
        case "ADD_FAILED", "ADDED_NOT_VISIBLE":
            fail("Bridge installed, but registering it failed on \(host.label). \(detail)",
                 for: host.id)
            return false
        default:
            let tail = out.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty }) ?? "no output"
            fail("Couldn't tell whether Claude registered the bridge on \(host.label): \(tail)",
                 for: host.id)
            return false
        }

        DiagnosticLog.shared.record("mcp", "installed and registered on \(host.label) at \(remotePath)")

        // A shared install can be adopted by the machine's other accounts;
        // a home-directory one can't, and saying so is more useful than
        // staying quiet about it.
        DispatchQueue.main.async {
            MCPInstaller.shared.multiUserHint =
                MultiUserHint(host: host.label,
                              isShared: MCPInstall.isSharedBase(base),
                              command: "sh \(MCPInstall.multiUserScriptPath(base: base))")
        }
        report("Installed on \(host.label)", for: host.id)
        return true
    }

    /// Leave a script beside the binary that another account can run to
    /// adopt it.
    ///
    /// Registration is per-user by definition — `--scope user` writes the
    /// running user's ~/.claude.json — so there is no way to install
    /// "for everyone" from here. What we CAN do is make the second
    /// account's job one command instead of a paragraph of instructions.
    ///
    /// Written only for a shared install: a bridge in someone's home
    /// directory isn't readable by anyone else, so the script would
    /// register a path its reader can't execute.
    static func multiUserScript(binaryPath: String, base: String) -> String {
        guard MCPInstall.isSharedBase(base) else { return "" }
        let path = MCPInstall.multiUserScriptPath(base: base)
        // Single-quoted heredoc: nothing in the body is expanded now, it
        // is expanded when the other user runs it.
        return """
        cat > \(Self.shellQuote(path)) <<'ONYXEOF'
        # Registers the shared Onyx MCP bridge for whoever runs this.
        # Safe to re-run; safe to run as any account on this machine.
        # No shebang on purpose: this heredoc travels through an
        # interactive remote shell, where a bare bang is history
        # expansion and takes the whole line with it. Run it as
        # "sh <path>", which is what the dialog tells you to do.
        set -e
        BIN=\(Self.shellQuote(binaryPath))
        # Written as "[ -x ] ||" rather than a negated test, for the same
        # reason as the missing shebang above.
        [ -x "$BIN" ] || {
            echo "Onyx bridge not found at $BIN" >&2
            exit 1
        }
        ONYX_CLAUDE=""
        for c in "$(command -v claude 2>/dev/null)" /opt/homebrew/bin/claude \\
                 /usr/local/bin/claude "$HOME/.local/bin/claude"; do
            [ -n "$c" ] && [ -x "$c" ] || continue
            "$c" --version </dev/null >/dev/null 2>&1 || continue
            ONYX_CLAUDE="$c"
            break
        done
        [ -n "$ONYX_CLAUDE" ] || {
            echo "No working 'claude' found on this PATH." >&2
            exit 1
        }
        "$ONYX_CLAUDE" mcp remove onyx </dev/null >/dev/null 2>&1 || true
        "$ONYX_CLAUDE" mcp add --scope user onyx -- "$BIN" </dev/null
        "$ONYX_CLAUDE" mcp get onyx </dev/null >/dev/null 2>&1 \\
            && echo "Onyx MCP registered for $(whoami)." \\
            || { echo "claude mcp add ran but the server isn't listed." >&2; exit 1; }
        ONYXEOF
        chmod 0755 \(Self.shellQuote(path)) 2>/dev/null || true
        """
    }

    /// Merge our hooks into ~/.claude/settings.json.
    ///
    /// Merge, never replace: people have their own hooks and their own MCP
    /// servers, and a setup step that quietly deletes them would be the
    /// worst thing in this file. python3 does it properly; without python3
    /// we only write a settings file when there ISN'T one, because a
    /// half-understood rewrite of somebody's config is not worth the
    /// convenience.
    static func settingsMergeScript(binaryPath: String) -> String {
        let hookCmd = MCPInstall.hookCommand(binaryPath: binaryPath)
        return """
        mkdir -p "$HOME/.claude"
        ONYX_BIN=\(Self.shellQuote(binaryPath))
        ONYX_HOOK=\(Self.shellQuote(hookCmd))
        if command -v python3 >/dev/null 2>&1; then
        python3 - "$HOME/.claude/settings.json" "$ONYX_BIN" "$ONYX_HOOK" <<'PYEOF'
        import json, sys, os
        path, binary, hook = sys.argv[1], sys.argv[2], sys.argv[3]
        try:
            with open(path) as f:
                settings = json.load(f)
        except Exception:
            settings = {}
        events = ["PreToolUse", "PostToolUse", "SessionStart", "Stop", "PermissionRequest"]
        hooks = settings.get("hooks") or {}
        for event in events:
            entry = {"type": "command", "command": hook + " " + event}
            if event == "PermissionRequest":
                entry["timeout"] = 120
            matchers = hooks.get(event) or [{"matcher": "", "hooks": []}]
            # Replace only OUR hook, leaving anyone else's in place.
            for m in matchers:
                m["hooks"] = [h for h in (m.get("hooks") or [])
                              if "OnyxMCP" not in str(h.get("command", ""))]
                m["hooks"].append(entry)
            hooks[event] = matchers
        settings["hooks"] = hooks
        tmp = path + ".onyx-tmp"
        with open(tmp, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\\n")
        os.replace(tmp, path)
        print("settings merged")
        PYEOF
        else
            # Hooks are a nested merge; without python3 we leave the file
            # alone rather than guess. The MCP registration above is the
            # part that matters and it went through the CLI.
            echo "hooks skipped (no python3 to merge with)"
        fi
        """
    }

    // MARK: - Plumbing

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func setStatus(_ s: MCPHostStatus, for id: UUID) {
        DispatchQueue.main.async { self.status[id] = s }
    }

    private func report(_ message: String, for id: UUID) {
        DispatchQueue.main.async { self.progress[id] = message }
    }

    private func fail(_ message: String, for id: UUID) {
        DiagnosticLog.shared.record("mcp", message, failure: true)
        DispatchQueue.main.async { self.progress[id] = message }
    }
}
