//
// TmuxInstall.swift
//
// Responsibility: Finding out whether a host has tmux, and if not, how to
//                 install it there — the probe script, its parser, and the
//                 platform's install command.
// Scope: Service. Pure functions.
//
// Onyx's terminals are tmux sessions, so a host without tmux can't have
// one: the attach exits 127 ("command not found") the moment it starts.
// The probe runs only then, never on a healthy host. It looks on the same
// PATH the attach uses (`RemoteWire.extraPath`) — tmux from Homebrew or a
// snap counts.
//

import Foundation

public enum TmuxInstall {

    /// The package managers we know how to drive, in the order we'd pick
    /// one when a host has several. brew comes after the system's own on
    /// Linux (Linuxbrew is a user's choice, the distro's is the default)
    /// and is preferred on macOS (`plan` handles that).
    public static let knownManagers = ["apt-get", "dnf", "yum", "zypper", "pacman", "apk", "pkg", "brew", "port"]

    static let marker = "ONYX-TMUX|"

    /// One line: `ONYX-TMUX|yes-or-no|uname|id|id_like|managers|privilege`.
    /// Remote-script rules: no `!` (zsh history expansion), no unmatched
    /// globs, under ~1KB with the wrapper (RemoteScriptBudgetTests).
    public static var probeScript: String {
        let managers = knownManagers.joined(separator: " ")
        return """
        export \(RemoteWire.extraPath)
        t=no; command -v tmux >/dev/null 2>&1 && t=yes
        m=""; for p in \(managers); do command -v $p >/dev/null 2>&1 && m="$m $p"; done
        os=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
        like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release 2>/dev/null | tr -d '"')
        s=none; command -v sudo >/dev/null 2>&1 && s=sudo; [ "$(id -u)" = 0 ] && s=root
        echo "\(marker)$t|$(uname -s)|$os|$like|$m|$s"
        """
    }

    /// The probe's answer, or nil if it didn't come back. Takes the LAST
    /// line that looks evaluated: over a terminal the script is echoed,
    /// and the echo of its last line can land after the real output.
    public static func parse(_ output: String) -> TmuxProbe? {
        let line = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.hasPrefix(marker) && !$0.contains("$") }
        guard let line else { return nil }
        let fields = line.dropFirst(marker.count)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 6, fields[0] == "yes" || fields[0] == "no" else { return nil }
        return TmuxProbe(present: fields[0] == "yes",
                         system: fields[1],
                         osID: fields[2],
                         osLike: fields[3].split(separator: " ").map(String.init),
                         managers: fields[4].split(separator: " ").map(String.init)
                            .filter { knownManagers.contains($0) },
                         privilege: TmuxProbe.Privilege(rawValue: fields[5]) ?? .none)
    }

    public static let helpURL = "https://github.com/tmux/tmux/wiki/Installing"

    /// How to install tmux on the probed host.
    public static func plan(for probe: TmuxProbe, hostID: UUID, hostLabel: String) -> TmuxInstallPlan {
        let isMac = probe.system == "Darwin"
        let order = isMac ? ["brew", "port"] : knownManagers
        guard let manager = order.first(where: probe.managers.contains) else {
            let advice = isMac
                ? "Onyx installs it with Homebrew, which this Mac doesn't have. Install Homebrew from brew.sh, then run: brew install tmux"
                : "Onyx couldn't find a package manager it knows there. Install tmux the way that system installs software, then check again."
            return TmuxInstallPlan(hostID: hostID, hostLabel: hostLabel, manager: nil, command: nil,
                                   passwordPrompt: nil, advice: advice,
                                   helpURL: isMac ? "https://brew.sh" : helpURL)
        }

        let steps = installSteps(manager)
        let command: String
        let prompt: String?
        if manager == "brew" {
            // Homebrew refuses to run as root, and never needs sudo.
            command = steps.joined(separator: " && ")
            prompt = nil
        } else {
            switch probe.privilege {
            case .root:
                command = steps.joined(separator: " && ")
                prompt = nil
            case .sudo:
                command = steps.map { "sudo " + $0 }.joined(separator: " && ")
                prompt = "sudo"
            case .none:
                command = "su -c \"\(steps.joined(separator: " && "))\""
                prompt = "su"
            }
        }

        let how: String
        switch prompt {
        case "sudo": how = "It runs in a terminal, where sudo will ask for your password."
        case "su": how = "There's no sudo there, so it uses su, which asks for root's password."
        default: how = "It runs in a terminal, so you can watch it."
        }
        return TmuxInstallPlan(hostID: hostID, hostLabel: hostLabel, manager: manager,
                               command: command, passwordPrompt: prompt,
                               advice: "Onyx can install it with \(manager). \(how)",
                               helpURL: nil)
    }

    /// Each step runs with the same privilege. No single quotes: the
    /// command travels inside `$SHELL -lc '…'`.
    static func installSteps(_ manager: String) -> [String] {
        switch manager {
        case "apt-get": return ["apt-get update", "apt-get install -y tmux"]
        case "dnf": return ["dnf install -y tmux"]
        case "yum": return ["yum install -y tmux"]
        case "zypper": return ["zypper --non-interactive install tmux"]
        case "pacman": return ["pacman -S --noconfirm --needed tmux"]
        case "apk": return ["apk add tmux"]
        case "pkg": return ["pkg install -y tmux"]
        case "brew": return ["brew install tmux"]
        case "port": return ["port install tmux"]
        default: return []
        }
    }

    /// What the install terminal runs: say what's happening, run it, and
    /// check — exiting 0 only if tmux is now there. On failure it waits for
    /// Return, so the error stays on screen until it's been read. Goes
    /// inside `$SHELL -lc '…'`, so it has no single quotes and no `!`.
    public static func terminalScript(_ plan: TmuxInstallPlan) -> String? {
        guard let command = plan.command, let manager = plan.manager else { return nil }
        return [
            "export \(RemoteWire.extraPath)",
            "echo",
            "echo \"Installing tmux with \(manager):\"",
            "echo \"  \(command.replacingOccurrences(of: "\"", with: "\\\""))\"",
            "echo",
            command,
            "if command -v tmux >/dev/null 2>&1; then echo; echo \"tmux is installed. Connecting…\"; sleep 1; exit 0; fi",
            "echo; echo \"tmux is still not installed. Press Return to close.\"; read x; exit 1",
        ].joined(separator: "; ")
    }
}
