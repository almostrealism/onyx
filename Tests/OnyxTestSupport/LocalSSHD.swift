//
// LocalSSHD.swift
//
// A real OpenSSH server for tests: the system's own sshd, started as the
// user running the tests on a loopback port, with its own host key, its
// own authorized_keys and nothing of the user's touched. It can only log
// in as that same user, which is all a test needs.
//
// It exists so both transports — ssh/scp processes and the in-process
// client — are tested against the thing they will meet in the field,
// rather than against a fake that agrees with them by construction.
//

import Foundation

public final class LocalSSHD {

    /// Where everything lives; removed by `stop()`.
    public let directory: URL
    public let port: Int
    /// A client key authorized to log in (OpenSSH format, no passphrase).
    public let clientKey: URL
    /// A known_hosts file already trusting the server's key.
    public let knownHosts: URL
    /// The server's public host key line ("ssh-ed25519 AAAA…").
    public let hostPublicKey: String
    public var user: String { NSUserName() }
    /// The name to connect to. Loopback, but NOT spelled "127.0.0.1" or
    /// "localhost": Onyx treats those as this Mac (`HostConfig.isLocal`)
    /// and runs everything as a local process, so a test using them would
    /// never reach the server at all — which is exactly what the first
    /// version of these tests did, quietly passing.
    public let hostName = "127.1"

    private let process: Process

    /// Why a server couldn't be started; tests skip on it.
    public struct Unavailable: Error, CustomStringConvertible {
        public let description: String
    }

    /// Start one. Throws `Unavailable` when this machine can't, which a
    /// test turns into a skip.
    public static func start() throws -> LocalSSHD {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else {
            throw Unavailable(description: "no sshd on this machine")
        }
        return try LocalSSHD()
    }

    private init() throws {
        let fm = FileManager.default
        // /tmp, not the per-user temp folder: sshd puts paths on its own
        // command line and in socket names, and short paths keep clear of
        // every length limit.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("onyx-sshd-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        clientKey = directory.appendingPathComponent("client")
        knownHosts = directory.appendingPathComponent("known_hosts")
        let hostKey = directory.appendingPathComponent("hostkey")

        for key in [hostKey, clientKey] {
            try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
        }
        let authorized = directory.appendingPathComponent("authorized_keys")
        try fm.copyItem(at: clientKey.appendingPathExtension("pub"), to: authorized)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorized.path)

        hostPublicKey = try String(contentsOf: hostKey.appendingPathExtension("pub"), encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")

        port = Self.freePort()
        try "[127.1]:\(port),[127.0.0.1]:\(port) \(hostPublicKey)\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        let config = directory.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        PidFile \(directory.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorized.path)
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        PermitUserEnvironment no
        AllowTcpForwarding yes
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel VERBOSE

        """.write(to: config, atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        // -D: stay in the foreground, so the test owns the process.
        process.arguments = ["-D", "-f", config.path, "-E", directory.appendingPathComponent("log").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Ready when it accepts a connection.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.accepts(port: port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let said = log
        stop()
        throw Unavailable(description: "sshd didn't start: \(said)")
    }

    /// What sshd logged — the first thing to read when a test fails.
    public var log: String {
        (try? String(contentsOf: directory.appendingPathComponent("log"), encoding: .utf8)) ?? ""
    }

    /// Options that point an `ssh`/`scp` process at this server's key and
    /// known_hosts instead of the user's.
    public var sshOptions: [String] {
        ["-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "IdentitiesOnly=yes",
         "-o", "IdentityAgent=none"]
    }

    public func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }

    // MARK: - Helpers

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Unavailable(description: "\(path) failed (\(p.terminationStatus))")
        }
    }

    /// A port nothing is listening on right now.
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func accepts(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
