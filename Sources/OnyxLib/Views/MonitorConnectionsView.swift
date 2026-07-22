import SwiftUI

struct ConnectionPoolSection: View {
    @ObservedObject var appState: AppState
    /// Observe the pair registry directly — `stateGeneration` bumps on
    /// every per-host slot mutation. SwiftUI re-renders this whole view
    /// tree (column + expanded panel) in the same pass, so they CAN'T
    /// get out of sync the way they did under the old cached-dict + 10s
    /// timer approach (where the column showed "no mux" but the
    /// expanded panel showed "alive" because they sampled the state
    /// at different times).
    @ObservedObject private var registry = ConnectionPairRegistry.shared
    /// Which hostID currently has its diagnostic panel expanded inline.
    @State private var expandedDiagHost: UUID?
    /// Cached diagnostics indexed by hostID. Re-fetched when the row is
    /// expanded; cleared when collapsed.
    @State private var muxDiagnostics: [UUID: SSHMuxDiagnostic] = [:]
    @State private var connectTests: [UUID: SSHConnectTest] = [:]
    @State private var connectInFlight: Set<UUID> = []

    /// Merge pool entries with pending entries, deduplicating by ID
    private var allConnections: [ConnectionInfo] {
        var seen = Set<String>()
        var result: [ConnectionInfo] = []
        // Pool entries first (they're authoritative)
        for conn in appState.connectionPool {
            seen.insert(conn.id)
            result.append(conn)
        }
        // Pending entries that aren't already in pool
        for conn in appState.pendingConnections where !seen.contains(conn.id) {
            seen.insert(conn.id)
            result.append(conn)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONNECTIONS")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(appState.accentColor)
                    .tracking(2)
                Spacer()
                let conns = allConnections
                let running = conns.filter { $0.isRunning || $0.connectionStatus.isTransient }.count
                let total = conns.count
                if total > 0 {
                    Text("\(running)/\(total)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            let conns = allConnections
            if conns.isEmpty {
                Text("No connections")
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("")
                        .frame(width: 8)
                    Text("SESSION")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("HOST")
                        .frame(width: 80, alignment: .trailing)
                    Text("STATUS")
                        .frame(width: 85, alignment: .trailing)
                }
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(.gray.opacity(0.4))

                ForEach(conns) { conn in
                    HStack(spacing: 0) {
                        if conn.connectionStatus.isTransient {
                            // Pulsing dot for transient states
                            Circle()
                                .fill(Color(hex: conn.statusColor))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 3)
                                .opacity(0.6)
                                .modifier(PulseModifier())
                        } else {
                            Circle()
                                .fill(Color(hex: conn.statusColor))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 3)
                        }
                        Text(conn.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(conn.hostLabel)
                            .frame(width: 80, alignment: .trailing)
                            .lineLimit(1)
                        Text(conn.status)
                            .frame(width: 85, alignment: .trailing)
                            .foregroundColor(Color(hex: conn.statusColor).opacity(0.8))
                    }
                    .monitorFont(size: 11)
                    .foregroundColor(.white.opacity(conn.connectionStatus.isTransient ? 0.5 : 0.7))
                }

                // SSH mux status per remote host
                let remoteHosts = appState.hosts.filter { !$0.isLocal }
                if !remoteHosts.isEmpty {
                    Divider().background(Color.white.opacity(0.06)).padding(.vertical, 4)

                    HStack(spacing: 0) {
                        Text("")
                            .frame(width: 8)
                        Text("SSH MUX")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("STATUS")
                            .frame(width: 96, alignment: .trailing)
                    }
                    .monitorFont(size: 9, weight: .medium)
                    .foregroundColor(.gray.opacity(0.4))

                    ForEach(remoteHosts) { host in
                        // Read directly from the registry. Both this and
                        // the expanded panel below source from the same
                        // call, in the same SwiftUI pass — divergence is
                        // structurally impossible. SwiftUI re-renders
                        // on any registry.stateGeneration bump because
                        // we @ObservedObject the registry above.
                        let alive = ConnectionPairRegistry.shared.isMuxAlive(for: host)
                        let expanded = expandedDiagHost == host.id
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: { toggleDiagnostic(for: host) }) {
                                HStack(spacing: 0) {
                                    Circle()
                                        .fill(Color(hex: alive ? "6BFF8E" : "FF6B6B"))
                                        .frame(width: 5, height: 5)
                                        .padding(.trailing, 3)
                                    Text(host.label)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                    Image(systemName: expanded
                                          ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundColor(.gray.opacity(0.4))
                                        .padding(.trailing, 6)
                                    Text(alive ? "multiplexed" : "no mux")
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(width: 96, alignment: .trailing)
                                        .foregroundColor(Color(hex: alive ? "6BFF8E" : "FF6B6B").opacity(0.8))
                                }
                                .monitorFont(size: 11)
                                .foregroundColor(.white.opacity(0.7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded {
                                SSHDiagnosticPanel(
                                    host: host,
                                    diagnostic: muxDiagnostics[host.id],
                                    connectTest: connectTests[host.id],
                                    isTesting: connectInFlight.contains(host.id),
                                    onReset: { resetMux(for: host) },
                                    onTestConnect: { runConnectTest(for: host) }
                                )
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
        }
        // No timer-based refresh needed — keeper.stateGeneration
        // bumps push updates to this view automatically. Dead /
        // failover / re-establish events surface within one render
        // cycle of when the keeper observed them.
    }

    // refreshMuxStatus / muxStatus have been removed — the registry's
    // ObservableObject + stateGeneration is now the single source the
    // view binds to. Per-row alive flags are read directly from
    // ConnectionPairRegistry.shared.isMuxAlive at render time.

    private func toggleDiagnostic(for host: HostConfig) {
        if expandedDiagHost == host.id {
            expandedDiagHost = nil
            return
        }
        expandedDiagHost = host.id
        // Fetch fresh diagnostic in the background — the `ssh -O check`
        // is bounded by its 3s kill timer, so this can never block the UI
        // for long.
        DispatchQueue.global(qos: .userInitiated).async {
            let diag = appState.diagnoseSSHMux(for: host)
            DispatchQueue.main.async {
                muxDiagnostics[host.id] = diag
            }
        }
    }

    private func resetMux(for host: HostConfig) {
        appState.resetSSHMux(for: host)
        // Re-run the diagnostic immediately so the user sees the new
        // (empty) state right away. The status column updates via the
        // keeper's @Published stateGeneration; no manual sync needed.
        DispatchQueue.global(qos: .userInitiated).async {
            let diag = appState.diagnoseSSHMux(for: host)
            DispatchQueue.main.async {
                muxDiagnostics[host.id] = diag
            }
        }
    }

    private func runConnectTest(for host: HostConfig) {
        connectInFlight.insert(host.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = appState.testSSHConnection(for: host)
            DispatchQueue.main.async {
                connectTests[host.id] = result
                connectInFlight.remove(host.id)
            }
        }
    }
}

/// Inline diagnostic panel for a single host. Shown under the SSH MUX row
/// when the user expands it. Renders the captured ssh command + output +
/// socket state, with actions to reset the mux or run a fresh
/// connection test.
private struct SSHDiagnosticPanel: View {
    let host: HostConfig
    let diagnostic: SSHMuxDiagnostic?
    let connectTest: SSHConnectTest?
    let isTesting: Bool
    let onReset: () -> Void
    let onTestConnect: () -> Void
    @State private var lastReapResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Supervisor (ConnectionPair) state. Goes first because this
            // is what the user actually wants to know — "is the supervisor
            // keeping things alive for me?" The legacy point-in-time
            // diagnostic still appears below.
            if let diag = ConnectionPairRegistry.shared.pairDiagnostics(for: host) {
                let active = diag.slots[diag.activeIndex]
                let standby = diag.slots[1 - diag.activeIndex]
                row("ACTIVE",
                    slotSummary(active, label: diag.activeIndex == 0 ? "A" : "B"),
                    color: active.phase == .alive ? "6BFF8E" : "FF6B6B")
                row("STANDBY",
                    slotSummary(standby, label: diag.activeIndex == 0 ? "B" : "A"),
                    color: standby.phase == .alive ? "6BFF8E"
                          : (standby.phase == .establishing ? "FFD06B" : "FF6B6B"))
                row("STATE", "\(diag.state)", color: nil)
                if let rot = diag.lastRotationAt {
                    row("ROTATE",
                        "last \(formatAge(Date().timeIntervalSince(rot))) ago · "
                          + "next in \(formatAge(max(0, ConnectionPair.rotationInterval - Date().timeIntervalSince(rot))))",
                        color: nil)
                }
            } else {
                row("PAIR", "not yet observed", color: nil)
            }
            Divider().background(Color.white.opacity(0.06)).padding(.vertical, 2)
            if let d = diagnostic {
                row("STATUS", d.summary, color: d.muxAlive ? "6BFF8E" : "FF6B6B")
                row("SOCKET",
                    d.socketExists
                        ? "\(d.controlPath) — \(formatAge(d.socketAgeSeconds))"
                        : "(missing)",
                    color: nil)
                row("EXIT", d.checkExitCode.map(String.init) ?? "(no exit)",
                    color: nil)
                if !d.checkOutput.isEmpty {
                    Text("SSH OUTPUT")
                        .monitorFont(size: 9, weight: .medium)
                        .foregroundColor(.gray.opacity(0.5))
                        .tracking(1)
                        .padding(.top, 2)
                    ScrollView {
                        Text(d.checkOutput)
                            .monitorFont(size: 10)
                            .foregroundColor(.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 80)
                }
                Text(d.checkCommand)
                    .monitorFont(size: 9)
                    .foregroundColor(.gray.opacity(0.5))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("Loading diagnostic…")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.4))
            }

            if let t = connectTest {
                Divider().background(Color.white.opacity(0.06))
                Text(t.success ? "CONNECT OK" : "CONNECT FAILED (exit \(t.exitCode.map(String.init) ?? "?"))")
                    .monitorFont(size: 9, weight: .medium)
                    .foregroundColor(Color(hex: t.success ? "6BFF8E" : "FF6B6B"))
                    .tracking(1)
                if !t.output.isEmpty {
                    ScrollView {
                        Text(t.output)
                            .monitorFont(size: 10)
                            .foregroundColor(.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 120)
                }
            }

            HStack(spacing: 8) {
                Button(action: onReset) {
                    Text("Reset mux")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                Button(action: onTestConnect) {
                    Text(isTesting ? "Testing…" : "Test connection")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
                Spacer()
                // Kill switch — disables the entire supervisor when the
                // user suspects it's misbehaving. Stops all new SSH
                // calls, freezes existing slot state for the UI.
                Button(action: {
                    ConnectionPairRegistry.shared.setEnabled(!ConnectionPairRegistry.shared.enabled)
                }) {
                    Text(ConnectionPairRegistry.shared.enabled ? "Disable keeper" : "Enable keeper")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ConnectionPairRegistry.shared.enabled
                                    ? Color.onyxRed.opacity(0.2)
                                    : Color.onyxGreen.opacity(0.2))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.top, 4)

            // Global, host-independent: reap every ssh process the
            // keeper has spawned (or that anyone has spawned with a
            // ControlPath in our mux dir). Equivalent to running the
            // ssh-leak-cleanup.sh script. Use when accumulated orphans
            // have started tripping the remote sshd MaxStartups.
            HStack(spacing: 8) {
                Button(action: {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = ConnectionPairRegistry.shared.reapAll()
                        DispatchQueue.main.async {
                            lastReapResult = "Killed \(result.killed), refused \(result.refused)"
                        }
                    }
                }) {
                    Text("Reap all SSH (nuclear)")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.onyxRed.opacity(0.25))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                Button(action: {
                    let dump = ConnectionPairRegistry.shared.inventoryDump()
                    // Drop on the pasteboard so the user can share it.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dump, forType: .string)
                    lastReapResult = "Inventory copied to clipboard"
                }) {
                    Text("Copy inventory")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                if let summary = lastReapResult {
                    Text(summary)
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.6))
                }
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(4)
        .padding(.leading, 14)
    }

    private func row(_ label: String, _ value: String, color: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .monitorFont(size: 10)
                .foregroundColor(color.map { Color(hex: $0) } ?? .white.opacity(0.7))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatAge(_ seconds: TimeInterval?) -> String {
        guard let s = seconds else { return "?" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }

    /// Compact one-line summary of a slot for the pair rows. Shows
    /// phase and age since establish.
    private func slotSummary(_ slot: ConnectionPair.Slot, label: String) -> String {
        let phaseTag: String
        switch slot.phase {
        case .alive: phaseTag = "alive"
        case .suspect: phaseTag = "alive (suspect)"
        case .establishing: phaseTag = "establishing…"
        case .dead: phaseTag = "DEAD"
        case .absent: phaseTag = "absent"
        }
        var parts = ["slot \(label)", phaseTag]
        if let est = slot.establishedAt, slot.phase == .alive {
            parts.append("age \(formatAge(Date().timeIntervalSince(est)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Simple pulse animation for transient connection states
struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 1.0 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Claude Code Sessions
