//
// MCPServer.swift
//
// Responsibility: The Mac's MCP server — a Unix socket for local agents and
//                 a loopback TCP port the hosts reach through the
//                 ConnectionPair's `-R` forward — in front of OnyxCore's
//                 MCPMessageHandler and the Mac's own tools (MacMCPTools).
//

import Foundation
import Network
import OnyxVersion
import OnyxCore

// MARK: - MCP Socket Server

extension MCPSocketServer {
    /// Create a new instance.
    private static var sharedInstance: MCPSocketServer?
    private static let sharedLock = NSLock()

    /// The app's one server, started by whichever window asks first.
    /// Artifact slots belong to that window; Claude sessions and alerts
    /// are app-wide anyway.
    public static func shared(artifactManager: ArtifactManager,
                              claudeSessions: ClaudeSessionManager) -> MCPSocketServer {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let existing = sharedInstance { return existing }
        let server = MCPSocketServer(artifactManager: artifactManager, claudeSessions: claudeSessions)
        server.start()
        sharedInstance = server
        return server
    }

    /// The Mac's server: its tools, and ~/.onyx/mcp.sock (where the
    /// OnyxMCP bridge on this Mac looks) as well as loopback TCP.
    public convenience init(artifactManager: ArtifactManager, claudeSessions: ClaudeSessionManager) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let onyxDir = home.appendingPathComponent(".onyx")
        try? FileManager.default.createDirectory(at: onyxDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.init(handler: MCPMessageHandler(artifactManager: artifactManager, claudeSessions: claudeSessions),
                  unixSocketPath: onyxDir.appendingPathComponent("mcp.sock").path)
    }
}
