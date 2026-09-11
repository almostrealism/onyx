import SwiftUI

/// The bell that lights when an agent has said something about a session.
///
/// Appears beside the session's note in the monitor, and on its chip in
/// the favourites bar — the bar is the fallback, because a session with
/// no note has no row in the monitor for the indicator to sit next to.
///
/// Clicking shows the history and marks it seen, so the light can go out
/// and come back on for the next one. "Seen" is not "deleted": the
/// history stays, because the alert you were away for is the one you
/// most want to read afterwards.
struct SessionAlertIndicator: View {
    let sessionKey: String?
    let accentColor: Color
    var size: CGFloat = 11

    @ObservedObject private var alerts = AlertStore.shared
    @State private var showing = false

    var body: some View {
        let unseen = alerts.unseenCount(for: sessionKey)
        let history = alerts.alerts(for: sessionKey)

        // No light and no history means nothing to offer — take up no
        // space rather than leaving a dead target in the row.
        if !history.isEmpty {
            Button(action: { showing = true }) {
                HStack(spacing: 3) {
                    Image(systemName: unseen > 0 ? "bell.badge.fill" : "bell")
                        .font(.system(size: size))
                        .foregroundColor(unseen > 0 ? Color.onyxAmber : .gray.opacity(0.35))
                    if unseen > 1 {
                        Text("\(unseen)")
                            .font(.system(size: size - 2, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.onyxAmber)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(unseen > 0 ? "\(unseen) unread from your agent" : "Earlier messages from your agent")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AlertHistoryPopover(alerts: history, accentColor: accentColor)
                    .onAppear {
                        AlertStore.shared.markSeen(for: sessionKey)
                        // Stop the dock bouncing too: the user is looking
                        // at the thing it was bouncing about.
                        AlertDelivery.shared.clearAttention()
                    }
            }
        }
    }
}

/// The list behind the bell.
private struct AlertHistoryPopover: View {
    let alerts: [SessionAlert]
    let accentColor: Color

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FROM YOUR AGENT")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(accentColor)
                .tracking(2)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(alerts) { alert in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                // Only urgent earns a colour; if everything
                                // is highlighted then nothing is.
                                if alert.urgent {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color.onyxAmber)
                                }
                                Text(alert.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                Spacer(minLength: 8)
                                Text(Self.stamp.string(from: alert.at))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.45))
                            }
                            if let body = alert.body {
                                Text(body)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // Shown only when the aim missed: it explains
                            // why this is in the general list rather than
                            // against a session.
                            if alert.sessionKey == nil, let label = alert.target?.label,
                               !label.isEmpty {
                                Text("aimed at \(label) — no session matched")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Color.onyxRed.opacity(0.6))
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 320)
    }
}
