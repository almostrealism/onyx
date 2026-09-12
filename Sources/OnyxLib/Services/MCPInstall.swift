//
// MCPInstall.swift
//
// Responsibility: Deciding WHAT to install where — which bundled bridge
//                 binary matches a host, where it should live, and what
//                 the remote's `uname` output means. Pure functions over
//                 strings; the doing lives in MCPInstaller.
// Scope: Service. No I/O, no SSH, no state — which is what makes the
//        decisions testable without a host to install onto.
//
// One install, not two. There used to be a separate "setup hooks" action
// that uploaded the same binary and wrote the same settings file; having
// two half-overlapping setups meant a host could be in a state where one
// had run and the other hadn't, and nothing said which. There is now a
// single MCP install and hooks are part of it.
//

import Foundation

/// A host's platform, as far as the installer cares.
public struct RemotePlatform: Equatable {
    public enum OS: String, Equatable {
        case macOS
        case linux
    }
    public let os: OS
    /// Normalised: "arm64" or "x86_64".
    public let arch: String

    public init(os: OS, arch: String) {
        self.os = os
        self.arch = arch
    }

    /// The bundled artifact that runs here, e.g. "OnyxMCP-linux-arm64".
    public var artifactName: String {
        "OnyxMCP-\(os == .macOS ? "macos" : "linux")-\(arch)"
    }

    /// How a person would say it.
    public var label: String {
        "\(os == .macOS ? "macOS" : "Linux") \(arch)"
    }

    /// Read `uname -s` / `uname -m` output.
    ///
    /// The architecture names are a mess in practice — Apple reports
    /// `arm64`, Linux reports `aarch64` for the same silicon, and x86 has
    /// three spellings — so they're normalised here rather than at each
    /// call site.
    public static func parse(uname os: String, machine: String) -> RemotePlatform? {
        let sys = os.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mach = machine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let resolvedOS: OS
        switch sys {
        case "darwin": resolvedOS = .macOS
        case "linux":  resolvedOS = .linux
        default:       return nil
        }

        let resolvedArch: String
        switch mach {
        case "arm64", "aarch64", "armv8l":     resolvedArch = "arm64"
        case "x86_64", "amd64", "x64", "i686": resolvedArch = "x86_64"
        default: return nil
        }

        return RemotePlatform(os: resolvedOS, arch: resolvedArch)
    }
}

public enum MCPInstall {

    /// The bridge version this build of Onyx ships.
    ///
    /// MUST match `onyxMCPVersion` in Sources/OnyxMCP/main.swift —
    /// MCPInstallVersionTests reads that file and fails if the two drift.
    /// A host running an older bridge otherwise reports "ready" forever,
    /// which is how a protocol fix can be shipped and quietly not applied
    /// anywhere.
    public static let currentVersion = "0.18"

    /// Where the bridge goes, relative to the chosen base directory.
    public static let relativeBinaryPath = ".onyx/bin/OnyxMCP"

    /// Default install base for a platform.
    ///
    /// On macOS, `/Users/Shared` when it exists: an install there is
    /// usable by every account on the machine, which matters because the
    /// agent you're wiring up may not run as you. Everywhere else it's
    /// the home directory, which always exists and is always writable.
    ///
    /// Returned as a shell expression rather than a resolved path — the
    /// remote knows its own `$HOME` and we would only be guessing.
    public static func defaultBase(for platform: RemotePlatform) -> String {
        platform.os == .macOS ? "${SHARED_OR_HOME}" : "$HOME"
    }

    /// The shell that resolves the macOS preference at install time.
    ///
    /// `/Users/Shared` has to be both present AND writable: it exists on
    /// every Mac but a managed machine can make it read-only, and finding
    /// that out by way of a failed upload is a bad way to find out.
    public static let sharedOrHomeScript = """
    SHARED_OR_HOME="$HOME"
    if [ -d /Users/Shared ] && [ -w /Users/Shared ]; then SHARED_OR_HOME=/Users/Shared; fi
    """

    /// Full path to the installed binary under a base directory.
    public static func binaryPath(base: String) -> String {
        base.hasSuffix("/") ? base + relativeBinaryPath : base + "/" + relativeBinaryPath
    }

    /// The command Claude Code should run for hooks, given an install path.
    public static func hookCommand(binaryPath: String) -> String {
        "\(binaryPath) --hook"
    }

    /// Where the adopt-me script lives, beside the binary.
    public static func multiUserScriptPath(base: String) -> String {
        binaryPath(base: base) + "-install-for-user.sh"
    }

    /// Only a shared install can be adopted by another account.
    ///
    /// A bridge under one user's home directory is not readable — let
    /// alone runnable — by anyone else, so offering the other accounts a
    /// command would be offering them a broken one.
    public static func isSharedBase(_ base: String) -> Bool {
        base == "/Users/Shared"
    }
}
