import XCTest
import SwiftUI
import AppKit
@testable import OnyxCore
@testable import OnyxLib

/// The ⌘J list with containers in it: each container is one line, its
/// logs and processes no longer rows of their own, and its own tmux
/// sessions indented beneath it. Set ONYX_SESSIONLIST_RENDER_DIR to look.
@MainActor
final class SessionListContainerTests: XCTestCase {

    func testAContainerIsOneLine() throws {
        let state = AppState()
        let host = HostConfig(label: "build-02", ssh: SSHConfig(host: "build-02.lan", user: "me", tmuxSession: "main"))
        state.hosts = [host]
        var sessions = [
            TmuxSession(name: "main", source: .host(hostID: host.id)),
            TmuxSession(name: "deploy", source: .host(hostID: host.id)),
        ]
        for container in ["api-worker", "postgres", "redis"] {
            sessions.append(TmuxSession(name: "\(container) logs", source: .dockerLogs(hostID: host.id, containerName: container)))
            sessions.append(TmuxSession(name: "\(container) top", source: .dockerTop(hostID: host.id, containerName: container)))
        }
        sessions.append(TmuxSession(name: "shell", source: .docker(hostID: host.id, containerName: "api-worker")))
        state.allSessions = sessions
        state.activeSession = sessions.first { $0.source.isDockerLogs && $0.source.containerName == "postgres" }

        let groups = try XCTUnwrap(state.hostGroupedSessions.first).groups
        let containers = groups.filter { $0.source.isDocker }
        XCTAssertEqual(containers.count, 3, "one group per container, logs and processes included")
        let rows = groups.reduce(0) { n, g in
            n + (g.source.isDocker ? 1 + g.sessions.filter { !$0.source.isUtility }.count : g.sessions.count)
        }
        XCTAssertEqual(rows, 2 + 3 + 1, "two host sessions, three containers, one session inside one")

        // The list's rows, at the panel's width (it draws nothing inside
        // a ScrollView, so the rows on their own).
        let view = VStack(alignment: .leading, spacing: 0) { HostGroupedSessionRows(appState: state) }
            .frame(width: 260, alignment: .topLeading)
            .background(Color(white: 0.06))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["ONYX_SESSIONLIST_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("session-list.png"))
        }
    }
}
