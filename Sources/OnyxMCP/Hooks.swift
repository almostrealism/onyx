//
// Hooks.swift
//
// Responsibility: Claude Code's hooks for this bridge — writing them into
//                 the user's Claude settings, checking that they're there,
//                 and saying where a hook event came from.
// Scope: The bridge, so it builds on Linux: Foundation only.
//
// Hooks are how Onyx lists Claude sessions. They are a separate path from
// the MCP tools: `notify` travels over the long-lived bridge Claude starts
// once per session, while every hook is a fresh `OnyxMCP --hook` process
// that Claude runs on every tool call and WAITS FOR — up to the entry's
// timeout, or 60 seconds when it has none. A host can have a
// working bridge and no working hooks, and that looked like "Onyx MCP is
// connected, but this machine's sessions never show up". Three ways it
// happened, all silent:
//
//   - The hooks were never written. The installer merged them with
//     python3 and, without it, printed "hooks skipped" into output nobody
//     read. A Mac without the Command Line Tools has a python3 that only
//     offers to install them, so the merge failed there too.
//   - The account running Claude isn't the one the install ran as. The
//     script for other accounts registered the bridge and wrote no hooks.
//   - The hooks ran but couldn't reach Onyx in time, and said nothing.
//
// So writing hooks moved here, where it needs nothing but the bridge
// itself, and every hook run is recorded in the ledger (see main.swift).
//

import Foundation
#if canImport(Glibc)
import Glibc
#endif

enum ClaudeHooks {

    /// The events Onyx listens to.
    static let events = ["PreToolUse", "PostToolUse", "SessionStart", "Stop", "PermissionRequest"]

    /// Claude Code's user settings file. `CLAUDE_CONFIG_DIR` moves it.
    static func settingsPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return (dir as NSString).appendingPathComponent("settings.json")
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/.claude/settings.json"
    }

    /// Whether a hook entry is one of ours.
    static func isOurs(_ command: String) -> Bool {
        command.contains("OnyxMCP") && command.contains("--hook")
    }

    // MARK: - Writing

    /// `settings` with Onyx's hooks in it. Anybody else's hooks, and every
    /// other setting, are left exactly as they were; an older Onyx hook is
    /// replaced rather than duplicated.
    static func merged(_ settings: [String: Any], binaryPath: String) -> [String: Any] {
        var out = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            // An explicit timeout on every entry. Without one Claude waits
            // up to its 60-second default, and a hook that blocked cost
            // that on every tool call. The bridge enforces its own 3s
            // deadline (HookWatchdog); this is the backstop.
            var entry: [String: Any] = ["type": "command", "command": "\(binaryPath) --hook \(event)",
                                        "timeout": event == "PermissionRequest" ? 120 : 5]

            var matchers = hooks[event] as? [[String: Any]] ?? []
            if matchers.isEmpty { matchers = [["matcher": "", "hooks": []]] }
            for i in matchers.indices {
                let existing = matchers[i]["hooks"] as? [[String: Any]] ?? []
                var kept = existing.filter { !isOurs($0["command"] as? String ?? "") }
                kept.append(entry)
                matchers[i]["hooks"] = kept
            }
            hooks[event] = matchers
        }
        out["hooks"] = hooks
        return out
    }

    enum InstallError: Error, CustomStringConvertible {
        case unreadable(String)
        case notJSON(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .unreadable(let why): return "couldn't read the settings file: \(why)"
            case .notJSON(let path):
                return "\(path) isn't valid JSON, so it was left alone — fix or move it, then reinstall"
            case .writeFailed(let why): return "couldn't write the settings file: \(why)"
            }
        }
    }

    /// Write our hooks into the settings file, creating it if needed.
    ///
    /// A file that exists but doesn't parse is refused, not replaced:
    /// it is somebody's configuration, and an empty object in its place
    /// would lose all of it. (The python3 merge this replaces did exactly
    /// that.)
    static func install(binaryPath: String, settingsPath path: String) throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: path) {
            guard let data = fm.contents(atPath: path) else {
                throw InstallError.unreadable(path)
            }
            let trimmed = (String(bytes: data, encoding: .utf8) ?? "x")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.notJSON(path)
                }
                settings = object
            }
        }

        let result = merged(settings, binaryPath: binaryPath)
        let data: Data
        do {
            var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            options.insert(.withoutEscapingSlashes)
            data = try JSONSerialization.data(withJSONObject: result, options: options)
        } catch {
            throw InstallError.writeFailed("\(error)")
        }

        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Beside the target, then renamed over it: a crash mid-write
            // must not leave half a settings file.
            let tmp = path + ".onyx-tmp"
            try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: tmp))
            guard rename(tmp, path) == 0 else {
                throw InstallError.writeFailed(String(cString: strerror(errno)))
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed("\(error)")
        }
    }

    // MARK: - Checking

    struct Health: Equatable {
        /// Events with no Onyx hook at all.
        var missing: [String]
        /// The binary our hooks run, if they're there.
        var binary: String?
        /// That binary doesn't exist or isn't executable.
        var binaryBroken: Bool
        /// `disableAllHooks` is set, so nothing runs whatever is listed.
        var disabled: Bool
        /// The settings file couldn't be read as JSON.
        var unreadable: Bool

        var ok: Bool { missing.isEmpty && !binaryBroken && !disabled && !unreadable }

        /// One line, starting with a verdict word the app parses.
        var line: String {
            if unreadable { return "HOOKS_UNREADABLE settings.json isn't valid JSON" }
            if disabled { return "HOOKS_DISABLED disableAllHooks is set in settings.json" }
            if missing.count == ClaudeHooks.events.count { return "HOOKS_MISSING none configured" }
            if !missing.isEmpty { return "HOOKS_PARTIAL missing \(missing.joined(separator: ", "))" }
            if binaryBroken { return "HOOKS_BROKEN they run \(binary ?? "?"), which isn't there" }
            return "HOOKS_OK \(binary ?? "")"
        }
    }

    /// What the settings say about our hooks.
    static func health(settings: [String: Any]?,
                       isExecutable: (String) -> Bool) -> Health {
        guard let settings else {
            return Health(missing: [], binary: nil, binaryBroken: false, disabled: false, unreadable: true)
        }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var missing: [String] = []
        var binary: String?
        for event in events {
            let matchers = hooks[event] as? [[String: Any]] ?? []
            let commands = matchers.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
                .compactMap { $0["command"] as? String }
                .filter(isOurs)
            if let first = commands.first {
                if binary == nil, let range = first.range(of: " --hook") {
                    binary = String(first[..<range.lowerBound])
                }
            } else {
                missing.append(event)
            }
        }
        let broken = binary.map { !isExecutable(expandHome($0)) } ?? false
        return Health(missing: missing, binary: binary, binaryBroken: broken,
                      disabled: settings["disableAllHooks"] as? Bool ?? false,
                      unreadable: false)
    }

    /// Read the settings file and judge it. A missing file is "nothing
    /// configured", not an error.
    static func health(atPath path: String) -> Health {
        let fm = FileManager.default
        let isExecutable: (String) -> Bool = { fm.isExecutableFile(atPath: $0) }
        guard fm.fileExists(atPath: path) else {
            return health(settings: [:], isExecutable: isExecutable)
        }
        guard let data = fm.contents(atPath: path) else {
            return health(settings: nil, isExecutable: isExecutable)
        }
        if (String(bytes: data, encoding: .utf8) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return health(settings: [:], isExecutable: isExecutable)
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return health(settings: object, isExecutable: isExecutable)
    }

    static func expandHome(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        if path.hasPrefix("$HOME/") { return home + path.dropFirst("$HOME".count) }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    // MARK: - Backing off

    static let backOffWindow: TimeInterval = 30
    static let slowFailureMillis = 1000

    /// Whether to skip trying: the last hook failed SLOWLY (it hung rather
    /// than being refused), less than `backOffWindow` ago, and nothing has
    /// been delivered since.
    static func shouldBackOff(lastFailed: Ledger.HookRun?, lastDelivered: Ledger.HookRun?,
                              now: Date = Date()) -> Bool {
        guard let failed = lastFailed, failed.millis >= slowFailureMillis else { return false }
        if let delivered = lastDelivered, delivered.at >= failed.at { return false }
        return now.timeIntervalSince(failed.at) < backOffWindow
    }

    // MARK: - Where an event came from

    /// Who is running this hook: the machine, the account, and the tmux
    /// session when there is one. Sent with every event so the desktop
    /// can say which host a Claude session is on — and so it can list the
    /// hosts it has heard from, which is the first question when one is
    /// missing.
    ///
    /// When this account can't ask tmux — Claude was started with `su -`
    /// or `sudo -iu` inside someone else's tmux, which clears `TMUX` and
    /// leaves the server's socket unreadable to us — the event carries
    /// this process's ancestors instead (`pids`, nearest first). The
    /// desktop connects as the tmux owner, so it can ask which pane's
    /// shell is among them.
    static func origin(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any] {
        var out: [String: Any] = ["machine": machineName()]
        if let user = environment["USER"] ?? environment["LOGNAME"], !user.isEmpty {
            out["user"] = user
        }
        if environment["TMUX"] != nil, let session = tmuxSession(pane: environment["TMUX_PANE"]) {
            out["session"] = session
        } else {
            let pids = ancestorPIDs()
            if !pids.isEmpty { out["pids"] = pids }
        }
        return out
    }

    /// This process's parent, its parent, and so on — up to `limit`, and
    /// stopping before launchd/init. Read from the kernel, not `ps`: this
    /// runs inside the hook's 3-second deadline.
    static func ancestorPIDs(limit: Int = 16) -> [Int] {
        var out: [Int] = []
        var pid = Int(getppid())
        while pid > 1, out.count < limit, !out.contains(pid) {
            out.append(pid)
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        return out
    }

    static func parentPID(of pid: Int) -> Int? {
        #if os(Linux)
        // /proc/<pid>/stat: "pid (comm) state ppid ...". comm may hold
        // spaces and parentheses, so read from after the LAST ')'.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int(fields[1]) : nil
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int(info.kp_eproc.e_ppid)
        #endif
    }

    /// `gethostname`, not ProcessInfo.hostName: on macOS the latter can do
    /// a reverse DNS lookup, and this runs inside a 3-second deadline.
    static func machineName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown" }
        let name = String(cString: buffer)
        // "mac-studio.local" and "mac-studio" are the same machine.
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    /// The tmux session this pane belongs to, or nil. Bounded: a wedged
    /// tmux server must not cost the hook its budget.
    static func tmuxSession(pane: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["tmux", "display-message", "-p"]
        if let pane, !pane.isEmpty { args += ["-t", pane] }
        args.append("#S")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let name = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// This binary's absolute path — what a hook entry should run.
func ownPath() -> String {
    #if os(Linux)
    if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
        return resolved
    }
    #endif
    if let path = Bundle.main.executablePath { return path }
    return CommandLine.arguments[0]
}

/// A hard deadline for one hook run.
///
/// A hook runs on every tool call, and Claude waits for it: up to the
/// entry's timeout, or 60 seconds when there is none. One host measured
/// 31 seconds per hook, so every tool call stalled for a minute while Onyx
/// was unreachable. Nothing in the hook may take that long, whatever it is
/// stuck on. So a watchdog ends the run at the deadline, after writing
/// down the step it was stuck in. That makes the next stall a diagnosis
/// (`OnyxMCP --status`, "last failed") instead of a mystery.
enum HookWatchdog {
    private static let lock = NSLock()
    private static var current = "starting"

    /// What the hook is doing right now, in words for the ledger.
    static var stage: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    static func enter(_ stage: String) {
        lock.lock(); current = stage; lock.unlock()
    }

    /// The deadline for an event. A permission request waits on a person,
    /// so it gets the two minutes Claude gives it; everything else must
    /// never be felt.
    static func deadline(for event: String) -> TimeInterval {
        event == "PermissionRequest" ? 125 : 3
    }

    static func start(event: String, started: Date, ledger: Ledger) {
        let seconds = deadline(for: event)
        let thread = Thread {
            Thread.sleep(forTimeInterval: seconds)
            let stuck = stage
            let run = Ledger.HookRun(event: event, at: started,
                                     millis: Int(Date().timeIntervalSince(started) * 1000),
                                     route: nil,
                                     detail: "gave up after \(Int(seconds))s while \(stuck)")
            _ = ledger.sawHookIfUnlocked(run, delivered: false)
            FileHandle.standardError.write(Data(
                "OnyxMCP: hook \(event) gave up after \(Int(seconds))s while \(stuck)\n".utf8))
            exit(0)
        }
        thread.start()
    }
}
