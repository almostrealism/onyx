//
// JDTLSBootstrap.swift
//
// Responsibility: Stateless builders for the remote scripts that (a) probe a
//                 host for the code-intelligence prerequisites (Java 21+,
//                 python3, and the jdtls launcher) and (b) install jdtls into
//                 the host's ~/.onyx/jdtls. Plus a parser for the probe output.
// Scope: Service. Pure functions — no I/O. Callers pair these with
//        AppState.remoteScript to run them (noexec-safe) and parse the result.
//
// The install pins a jdtls build rather than "latest" moving under us; bump it
// deliberately. See docs/lsp-code-navigation-plan.md (M3, bootstrap).
//

import Foundation

public enum JDTLSBootstrap {
    /// Pinned jdtls distribution. (Eclipse publishes snapshots; we pin the URL
    /// so an upgrade is a code change, not a surprise.)
    public static let downloadURL =
        "https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz"

    /// Minimum Java major version jdtls requires to run.
    public static let minJavaMajor = 21

    /// Result of the preflight probe.
    public struct Preflight: Equatable {
        public var javaMajor: Int?      // nil = java not found / unparseable
        public var hasPython: Bool
        public var hasJDTLS: Bool

        public var javaOK: Bool { (javaMajor ?? 0) >= JDTLSBootstrap.minJavaMajor }
        /// jdtls missing but everything needed to install + run it is present.
        public var canInstall: Bool { !hasJDTLS && javaOK && hasPython }
    }

    /// Script that prints three parseable lines: the raw `java -version` line,
    /// python3 presence, and whether the jdtls launcher exists.
    /// `jdtlsPath` is used unquoted so a leading `~` expands on the remote.
    public static func preflightScript(jdtlsPath: String) -> String {
        """
        echo "JAVA_LINE=$(java -version 2>&1 | head -1)"
        command -v python3 >/dev/null 2>&1 && echo "PY=yes" || echo "PY=no"
        [ -f \(jdtlsPath) ] && echo "JDTLS=yes" || echo "JDTLS=no"
        """
    }

    /// Parse the preflight probe output.
    public static func parsePreflight(_ output: String) -> Preflight {
        var javaMajor: Int?
        var hasPython = false
        var hasJDTLS = false
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("JAVA_LINE=") {
                javaMajor = parseJavaMajor(String(line.dropFirst("JAVA_LINE=".count)))
            } else if line == "PY=yes" {
                hasPython = true
            } else if line == "JDTLS=yes" {
                hasJDTLS = true
            }
        }
        return Preflight(javaMajor: javaMajor, hasPython: hasPython, hasJDTLS: hasJDTLS)
    }

    /// Extract the major version from a `java -version` first line such as
    /// `openjdk version "21.0.2" 2024-01-16 LTS` (→ 21) or the legacy
    /// `java version "1.8.0_401"` (→ 8).
    static func parseJavaMajor(_ line: String) -> Int? {
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
        let version = String(line[line.index(after: open)..<close])
        let parts = version.split(separator: ".")
        guard let first = parts.first, let firstNum = Int(first) else { return nil }
        if firstNum == 1, parts.count >= 2 { return Int(parts[1]) }  // 1.8 → 8
        return firstNum
    }

    /// Install directory implied by a jdtls launcher path (`…/bin/jdtls` →
    /// `…`). Falls back to the default if the path isn't the standard shape.
    public static func installDir(forJDTLSPath path: String) -> String {
        let suffix = "/bin/jdtls"
        if path.hasSuffix(suffix) { return String(path.dropLast(suffix.count)) }
        return "~/.onyx/jdtls"
    }

    /// Script that downloads and extracts jdtls into `installDir`. Prints
    /// `INSTALL_OK` on success so the caller can confirm.
    public static func installScript(installDir: String) -> String {
        let tmp = "/tmp/onyx-jdtls-$$.tgz"
        return """
        set -e
        mkdir -p \(installDir)
        curl -fsSL -o \(tmp) "\(downloadURL)"
        tar xzf \(tmp) -C \(installDir)
        rm -f \(tmp)
        [ -f \(installDir)/bin/jdtls ] && echo "INSTALL_OK" || echo "INSTALL_FAIL"
        """
    }

    public static func installSucceeded(in output: String) -> Bool {
        output.contains("INSTALL_OK")
    }
}
