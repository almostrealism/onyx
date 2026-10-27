//
// PadAgentViews.swift
//
// Responsibility: What agents look like on an iPad — a permission prompt
//                 as a sheet, an alert as a banner, and the sidebar's
//                 AGENTS section (which hosts' agents reach this iPad, the
//                 recent alerts, and whether prompts wait for Onyx).
// Scope: View.
//

import SwiftUI
import OnyxCore
import OnyxUI

/// An agent is blocked until this is answered: Claude asked to run a tool,
/// and the prompt waits here (two minutes, then it falls back to asking in
/// its terminal).
struct PadPermissionSheet: View {
    let request: PermissionRequest
    let sessions: ClaudeSessionManager
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AN AGENT IS ASKING")
                .monitorFont(size: 11, weight: .medium).foregroundColor(Color.onyxAmber).tracking(2)
            Text(request.toolName).monitorFont(size: 20, weight: .medium)
            Text(request.summary)
                .monitorFont(size: 13)
                .foregroundColor(.white.opacity(0.85))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .textSelection(.enabled)
            Text("Claude session \(request.sessionId.prefix(8)) · \(request.timestamp.formatted(date: .omitted, time: .shortened))")
                .monitorFont(size: 10).foregroundColor(.gray)
            HStack(spacing: 12) {
                Button(role: .destructive, action: { sessions.denyPermission(request.id) }) {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button(action: { sessions.approvePermission(request.id) }) {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
            }
            Text("⏎ allows, ⎋ denies. Unanswered, it goes back to the agent's terminal in two minutes.")
                .monitorFont(size: 9).foregroundColor(.gray)
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }
}

/// The newest alert, for a few seconds, over the top of the window.
struct PadAlertBanner: View {
    @ObservedObject var agents: PadAgents
    let accent: Color
    @State private var shown: PadAlert?

    var body: some View {
        VStack {
            if let alert = shown {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.badge").foregroundColor(alert.urgent ? Color.onyxAmber : accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.title).monitorFont(size: 13, weight: .medium)
                        if let body = alert.body { Text(body).monitorFont(size: 11).foregroundColor(.white.opacity(0.8)) }
                        if let place = place(alert) { Text(place).monitorFont(size: 9).foregroundColor(.gray) }
                    }
                    Spacer()
                    Button(action: { shown = nil }) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        .onReceive(agents.$alerts) { alerts in
            guard let newest = alerts.first, newest.id != shown?.id, Date().timeIntervalSince(newest.at) < 5 else { return }
            shown = newest
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if shown?.id == newest.id { shown = nil } }
        }
    }

    private func place(_ alert: PadAlert) -> String? {
        let parts = [alert.session, alert.host].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " on ")
    }
}

/// The sidebar's AGENTS section.
struct PadAgentsSection: View {
    @ObservedObject var agents: PadAgents
    let hosts: [PadHost]
    let accent: Color
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        Section {
            ForEach(hosts.filter { agents.reach[$0.id] != nil }) { host in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color(agents.reach[host.id])).frame(width: 6, height: 6).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.label).monitorFont(size: 11)
                        Text(text(agents.reach[host.id])).monitorFont(size: 9).foregroundColor(.gray)
                    }
                }
            }
            Toggle(isOn: Binding(get: { appearance.config.claudeHooksGatePermissions },
                                 set: { appearance.config.claudeHooksGatePermissions = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission prompts wait for Onyx").monitorFont(size: 11)
                    Text("Shared with your Macs.").monitorFont(size: 9).foregroundColor(.gray)
                }
            }
            .tint(accent)
            ForEach(agents.alerts.prefix(5)) { alert in
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).monitorFont(size: 11).lineLimit(2)
                    Text(([alert.session, alert.host].compactMap { $0 } + [alert.at.formatted(date: .omitted, time: .shortened)])
                            .joined(separator: " · "))
                        .monitorFont(size: 9).foregroundColor(.gray)
                }
                .swipeActions { Button("Dismiss") { agents.dismiss(alert) } }
            }
        } header: {
            Text("AGENTS").monitorFont(size: 10, weight: .medium)
        }
    }

    private func color(_ reach: PadAgents.Reach?) -> Color {
        switch reach {
        case .reaching: return Color.onyxGreen
        case .elsewhere: return Color.gray
        case .failed: return Color.onyxRed
        default: return Color.onyxAmber
        }
    }

    private func text(_ reach: PadAgents.Reach?) -> String {
        switch reach {
        case .reaching: return "its agents reach this iPad"
        case .elsewhere(let why): return why
        case .failed(let why): return "can't forward: \(why)"
        default: return "connecting…"
        }
    }
}
