import SwiftUI
import EventKit

// MARK: - Monitor font scaling
//
// All text in MonitorView and its descendants scales with the user's
// UI font size preference (Settings → UI font size). The "design"
// sizes used at each call site are the values that look right at the
// default scale of 1.0 (when uiFontSize = 12). At other sizes they
// scale proportionally so the visual hierarchy stays intact.

private struct MonitorFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Scale factor applied to all `.monitorFont(...)` calls inside
    /// MonitorView. Injected at the MonitorView root from
    /// `appearance.uiFontSize / 12`.
    var monitorFontScale: CGFloat {
        get { self[MonitorFontScaleKey.self] }
        set { self[MonitorFontScaleKey.self] = newValue }
    }
}

extension View {
    /// Use this instead of `.font(.system(size:weight:design:))` for
    /// any text or icon inside MonitorView. The `size` argument is the
    /// design intent at the default UI scale; the ambient
    /// `monitorFontScale` multiplies it. Default design is
    /// `.monospaced` since that's what 95% of MonitorView uses; pass
    /// `.default` explicitly for icons.
    func monitorFont(size: CGFloat,
                     weight: Font.Weight = .regular,
                     design: Font.Design = .monospaced) -> some View {
        modifier(MonitorFontModifier(baseSize: size, weight: weight, design: design))
    }
}

private struct MonitorFontModifier: ViewModifier {
    @Environment(\.monitorFontScale) private var scale
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * scale, weight: weight, design: design))
    }
}

/// NPU chip text. Prefer active-time residency over the interval — it
/// catches bursts that begin and end between polls. Fall back to the
/// point-in-time runtime-PM state (`active`/`suspended`); anything else
/// means the kernel isn't power-managing the device, so its state tells
/// us nothing and we say so rather than inventing "idle".
private func npuChipValue(_ sample: MonitorSample) -> String {
    if let pct = sample.npuActivePercent {
        // Sub-1% is real activity, just brief — don't round it to "0%"
        // and imply the NPU was untouched.
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }
    switch sample.npuState {
    case "active":    return "busy"
    case "suspended": return "idle"
    default:          return "—"
    }
}

private func npuTooltip(_ sample: MonitorSample) -> String {
    var lines = [sample.npuName ?? "NPU"]
    if sample.npuActivePercent != nil {
        lines.append("Share of the last interval the NPU was powered up")
        lines.append("(residency, not utilization — the driver exposes no % busy)")
    } else {
        switch sample.npuBusy {
        case true?:  lines.append("Powered up — a client is using it")
        case false?: lines.append("Runtime-suspended — nothing is using it")
        default:     lines.append("Runtime power management is off, so busy/idle can't be read")
        }
    }
    if let fw = sample.npuFirmware { lines.append("Firmware \(fw)") }
    return lines.joined(separator: "\n")
}

private func formatMB(_ mb: Double) -> String {
    if mb >= 1024 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return "\(Int(mb)) MB"
}

struct MonitorView: View {
    @ObservedObject var appState: AppState
    // Observe these high-frequency managers DIRECTLY rather than through
    // appState. They publish every ~5s; if their change forwarded into
    // appState.objectWillChange it would re-render the entire app tree
    // (terminal, file browser, notes…) every tick. Observing them here scopes
    // the 5s redraw to the monitor overlay subtree. See the perf work and the
    // removed forwarding sinks in AppState.
    @ObservedObject private var monitor: MonitorManager
    @ObservedObject private var dockerStats: DockerStatsManager
    /// One EventKit client for every at-a-glance layout (simple + both
    /// fleet views). Owned here rather than inside each body so cycling
    /// `S` doesn't tear one down and build another — which would mean an
    /// access check and a re-fetch on every press, and an empty column
    /// for the first second after each.
    @StateObject private var overlayReminders = RemindersManager()

    init(appState: AppState) {
        self.appState = appState
        self.monitor = appState.monitor
        self.dockerStats = appState.dockerStats
    }

    /// "Retrying every 5s · 12 consecutive failures · last good sample 3m ago".
    /// Says how long this has been broken and whether it was EVER working,
    /// which is the first question when a host is stuck.
    private var retryStatus: String {
        var parts = ["Retrying every \(Int(MonitorManager.activeInterval))s"]
        let failures = monitor.consecutiveFailures
        if failures > 0 {
            parts.append("\(failures) consecutive failure\(failures == 1 ? "" : "s")")
        }
        if let last = monitor.lastSuccessAt {
            let secs = Int(Date().timeIntervalSince(last))
            let ago = secs < 60 ? "\(secs)s" : (secs < 3600 ? "\(secs / 60)m" : "\(secs / 3600)h")
            parts.append("last good sample \(ago) ago")
        } else {
            parts.append("no successful poll yet")
        }
        // A skipped cycle runs no ssh at all, so the message above is
        // frozen from an older attempt — say so instead of implying we're
        // still hitting the same wall every 5 seconds.
        if let skip = monitor.lastSkip {
            parts.append("paused: \(skip)")
        }
        return parts.joined(separator: " · ")
    }

    /// One scrollable overlay column. Indicators are hidden — scrolling works
    /// via trackpad/wheel, and the user asked for the cleanest possible chrome.
    /// The caller sets the column's width (equal-split or fixed) via a frame.
    @ViewBuilder
    private func monitorColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 8)   // a little slack at the scroll end
        }
    }

    /// The single-key hint under the headline.
    ///
    /// P (12/24hr) and C (all containers) are deliberately absent: they're
    /// set-once preferences that belong in Settings, and the keys still
    /// work for anyone with the muscle memory. Listing every key trained
    /// people to read past the line entirely.
    private var shortcutHint: String {
        "(T \(intervalHint) · M memory · R due-soon · D side panel"
            + " · S \(appState.monitorLayout.label) · F \(appState.fleetMode.label) · X peek)"
    }

    /// What T means right now. In fleet modes it can't change the sample
    /// rate — the fleet sweep is a fixed 10s shared with the screensaver —
    /// so it changes the window instead, and says so rather than implying
    /// a resolution the data doesn't have.
    private var intervalHint: String {
        if appState.fleetMode == .currentHost {
            return monitor.useShortInterval ? "5s" : "1m"
        }
        return monitor.useShortInterval ? "10m window" : "1h window"
    }

    var body: some View {
        ZStack {
            // The overlay's tint. Driven by the opacity setting (via
            // monitorTintOpacity) so the overlay is at least as transparent
            // as the terminal: near the slider floor it vanishes to just the
            // floating widgets over the desktop, at the top it's a solid
            // privacy shield. The terminal beneath is already hidden, so this
            // is the only thing between the widgets and the desktop.
            Color.black.opacity(AppearanceConfig.monitorTintOpacity(for: appState.effectiveWindowOpacity))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                // Time + stats row: aux clocks left, main clock center, chips right
                ZStack {
                    // LEFT: Extra timezone clocks
                    if !appState.appearance.extraTimezones.isEmpty {
                        HStack(spacing: 20) {
                            ForEach(appState.appearance.extraTimezones.prefix(3), id: \.self) { tzId in
                                if let tz = TimeZone(identifier: tzId) {
                                    ExtraClockView(
                                        timeZone: tz,
                                        accentColor: appState.accentColor,
                                        use12Hour: appState.appearance.use12HourClock
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // CENTER: Main clock
                    TimeDisplay(accentColor: appState.accentColor, use12Hour: appState.appearance.use12HourClock)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // RIGHT: Stat chips. With no sample the row would be
                    // silently empty, which reads as "this host has no
                    // stats" rather than "stats are failing" — say which.
                    if monitor.latestSample == nil, let error = monitor.lastError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .monitorFont(size: 11, design: .default)
                                .foregroundColor(Color.onyxRed.opacity(0.8))
                            Text("stats unavailable")
                                .monitorFont(size: 11)
                                .foregroundColor(Color.onyxRed.opacity(0.7))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.onyxRed.opacity(0.08))
                        .cornerRadius(6)
                        .help(error)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let sample = monitor.latestSample {
                        HStack(spacing: 12) {
                            if let cpu = sample.cpuUsage {
                                StatChip(label: "CPU", value: "\(Int(cpu))%", accentColor: Color.onyxBlue)
                            }
                            if let used = sample.memUsed, let total = sample.memTotal, total > 0 {
                                StatChip(label: "MEM", value: "\(formatMB(used)) / \(formatMB(total))", accentColor: Color.onyxAmber)
                            }
                            if let gpu = sample.gpuUsage {
                                StatChip(label: "GPU", value: "\(Int(gpu))%", accentColor: Color.onyxPurple)
                            }
                            // NPU: the driver exposes no utilization counter,
                            // so this reports what it does know — whether the
                            // accelerator is powered up for a client or
                            // runtime-suspended.
                            if sample.npuState != nil {
                                let live = (sample.npuActivePercent ?? 0) > 0
                                    || sample.npuBusy == true
                                StatChip(label: "NPU",
                                         value: npuChipValue(sample),
                                         accentColor: live
                                             ? Color.onyxGreen : Color.onyxPurple)
                                    .help(npuTooltip(sample))
                            }
                            if let temp = sample.gpuTemp {
                                StatChip(label: "TEMP", value: "\(temp)°C", accentColor: Color.onyxRed)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 40)

                // Everything below is rendered whether or not stats are
                // coming in. Reminders, PRs, pipelines and session notes
                // don't depend on the stats poll, and losing the whole
                // overlay because one SSH command is failing is a bad
                // trade — the failure is reported inside the stats column
                // instead.
                Group {
                    // Interval label
                    HStack(spacing: 4) {
                        Text(monitor.useShortInterval ? "5s intervals" : "1m intervals")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                        // Numbers are real but the command ran past its
                        // budget — say so rather than either hiding it or
                        // calling the host broken.
                        if monitor.pollIsSlow {
                            Text("· stats slow")
                                .monitorFont(size: 10)
                                .foregroundColor(Color.onyxAmber.opacity(0.6))
                                .help("The stats command didn't finish within its time budget — the readings below are what it had sent by then.")
                        }
                        Text(shortcutHint)
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.25))
                    }

                    // Claude Code sessions banner (if any active) — stays
                    // full-width above the split.
                    if !appState.claudeSessions.activeSessions.isEmpty || !appState.claudeSessions.pendingPermissions.isEmpty {
                        ClaudeSessionsSection(appState: appState)
                            .padding(.horizontal, 40)
                    }

                    // A fired page watch outranks everything else on this
                    // screen: it's the one thing here you were actively
                    // waiting for, and it stays until acknowledged so it
                    // can't scroll past while you're asleep.
                    WatchFiredBanner()
                        .padding(.horizontal, 40)
                    WatchStatusLine()
                        .padding(.horizontal, 40)

                    if appState.monitorLayout == .simple {
                        SimpleMonitorBody(
                            appState: appState,
                            monitor: monitor,
                            dockerStats: dockerStats,
                            timing: appState.timing,
                            accentColor: appState.accentColor,
                            reminders: overlayReminders
                        )
                        .padding(.horizontal, 40)
                    } else {
                    // Main region: three independently-scrollable columns.
                    // Two columns left of the divider (timing bar+stats +
                    // reminders | heatmap + work-tracking widgets) and one to
                    // the right (~35%: CPU/MEM/GPU charts, containers,
                    // connections). Each scrolls on its own so a long list
                    // never pushes content off the bottom of the screen.
                    GeometryReader { geo in
                        let rightWidth = max(280, geo.size.width * 0.35)
                        HStack(alignment: .top, spacing: 0) {
                            // Column 1 + Column 2, left of the divider.
                            HStack(alignment: .top, spacing: 16) {
                                // Column 1: timing bar chart + stats (the tall
                                // half), then reminders beneath it.
                                monitorColumn {
                                    if appState.timing.isConfigured {
                                        TimingBarSection(timing: appState.timing, accentColor: appState.accentColor)
                                    }
                                    RemindersSection(appState: appState)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                                // Column 2: the (shorter) heatmap centered up
                                // top, then the work-tracking widgets in the
                                // order work flows: note → PR → pipeline.
                                monitorColumn {
                                    if appState.timing.isConfigured {
                                        TimingHeatmapSection(timing: appState.timing, accentColor: appState.accentColor)
                                    }
                                    SessionNotesSection(appState: appState)
                                    PullRequestsSection(appState: appState)
                                    PipelinesSection(appState: appState)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.trailing, 20)

                            Divider()
                                .background(Color.white.opacity(0.1))

                            // Column 3: CPU/MEM/GPU charts, containers, connections.
                            // This is the only part that needs the stats
                            // poll, so this is the only part that shows its
                            // failure. The connection pool below stays put
                            // either way — it's how you diagnose the failure.
                            monitorColumn {
                                if monitor.latestSample == nil {
                                    StatsUnavailableCard(
                                        error: monitor.lastError,
                                        status: retryStatus,
                                        hostLabel: appState.activeHost?.label ?? "host"
                                    )
                                }

                                // `F` retargets these charts at the fleet.
                                // The column is narrow, so the fleet views
                                // get a fixed budget and their own floor on
                                // chart height rather than the full-height
                                // arithmetic the simple layout can afford.
                                if appState.fleetMode == .topHosts {
                                    FleetStackedCharts(appState: appState, monitor: monitor,
                                                       accentColor: appState.accentColor,
                                                       availableHeight: 320,
                                                       minChartHeight: 14)
                                } else if appState.fleetMode == .fleetMax {
                                    FleetMergedCharts(appState: appState, monitor: monitor,
                                                      accentColor: appState.accentColor,
                                                      availableHeight: 320)
                                } else {
                                let cpuData = monitor.bucketedCPU()
                                if !cpuData.isEmpty {
                                    GridChart(
                                        title: "CPU",
                                        values: cpuData,
                                        accentColor: Color.onyxBlue
                                    )
                                } else if monitor.latestSample != nil {
                                    // We have samples, just no usable CPU
                                    // line — a parse problem, not a poll one.
                                    CPUUnavailableCard(
                                        message: monitor.cpuDiagnostic
                                            ?? "CPU usage unavailable on this host."
                                    )
                                }

                                let memData = monitor.showMemoryChart ? monitor.bucketedMemory() : []
                                let gpuData = monitor.bucketedGPU()
                                let hasMem = !memData.isEmpty && monitor.showMemoryChart
                                let hasGpu = !gpuData.isEmpty
                                let subChartHeight: CGFloat = 100

                                if hasMem && hasGpu {
                                    let halfHeight = (subChartHeight - 16) / 2
                                    GridChart(title: "MEMORY", values: memData,
                                              accentColor: Color.onyxAmber, height: halfHeight)
                                    GridChart(title: "GPU", values: gpuData,
                                              accentColor: Color.onyxPurple, height: halfHeight)
                                } else if hasMem {
                                    GridChart(title: "MEMORY", values: memData,
                                              accentColor: Color.onyxAmber, height: subChartHeight)
                                } else if hasGpu {
                                    GridChart(title: "GPU", values: gpuData,
                                              accentColor: Color.onyxPurple, height: subChartHeight)
                                }
                                }

                                if dockerStats.isAvailable {
                                    DockerStatsSection(appState: appState, dockerStats: dockerStats)
                                }
                                ConnectionPoolSection(appState: appState)
                            }
                            .frame(width: rightWidth, alignment: .topLeading)
                            .padding(.leading, 20)
                        }
                    }
                    .padding(.horizontal, 40)
                    } // end else (detailed view)
                }

                Spacer()
            }
            .padding(.top, 40)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMonitorInterval)) { _ in
            monitor.toggleInterval()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMemoryChart)) { _ in
            monitor.showMemoryChart.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAllContainers)) { _ in
            // Still works for the muscle memory; the setter writes the
            // same persisted preference the Settings toggle does.
            dockerStats.showAllContainers.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleClockFormat)) { _ in
            appState.appearance.use12HourClock.toggle()
            appState.saveAppearance()
        }
        .onAppear {
            dockerStats.startPolling()
            monitor.setOverlayVisible(true)   // fast 5s cadence while on screen
            // Trigger an immediate pool status publish via notification
            NotificationCenter.default.post(name: .refreshPoolStatus, object: nil)
        }
        .onDisappear {
            dockerStats.stopPolling()
            monitor.setOverlayVisible(false)  // drop to slow background cadence
        }
        // Scale every `.monitorFont(...)` in this view tree by the user's
        // UI font size preference. Default (uiFontSize == 12) → 1.0.
        .environment(\.monitorFontScale, appState.appearance.uiFontSize / 12.0)
    }
}

/// Main-thread-only cache of `DateFormatter`s by (format, time zone). The
/// clock views re-render every second; allocating a fresh `DateFormatter`
/// each time — one of Foundation's most expensive objects to create — was
/// pure churn. Reused across renders after the first.
enum ClockFormatters {
    private static var cache: [String: DateFormatter] = [:]

    static func string(_ date: Date, format: String, timeZone: TimeZone? = nil) -> String {
        let key = "\(format)|\(timeZone?.identifier ?? "_")"
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            let f = DateFormatter()
            f.dateFormat = format
            if let tz = timeZone { f.timeZone = tz }
            cache[key] = f
            formatter = f
        }
        return formatter.string(from: date)
    }
}

struct TimeDisplay: View {
    let accentColor: Color
    var use12Hour: Bool = false
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(timeDigits)
                    .monitorFont(size: 36, weight: .ultraLight)
                    .foregroundColor(.white.opacity(0.9))

                if use12Hour {
                    Text(ampmSuffix)
                        .monitorFont(size: 14, weight: .light)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            HStack(spacing: 8) {
                Text(dateString)
                    .monitorFont(size: 12, weight: .light)
                    .foregroundColor(accentColor.opacity(0.6))

                Text(utcString)
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }

    private var timeDigits: String {
        ClockFormatters.string(currentTime, format: use12Hour ? "h:mm:ss" : "HH:mm:ss")
    }

    private var ampmSuffix: String {
        ClockFormatters.string(currentTime, format: "a")
    }

    private var dateString: String {
        ClockFormatters.string(currentTime, format: "EEEE, MMMM d")
    }

    private var utcString: String {
        "UTC " + ClockFormatters.string(currentTime, format: "HH:mm",
                                        timeZone: TimeZone(identifier: "UTC"))
    }
}

struct ExtraClockView: View {
    let timeZone: TimeZone
    let accentColor: Color
    var use12Hour: Bool = false
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(timeString)
                .monitorFont(size: 16, weight: .ultraLight)
                .foregroundColor(.white.opacity(0.7))

            Text(label)
                .monitorFont(size: 9)
                .foregroundColor(accentColor.opacity(0.4))
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }

    private var timeString: String {
        ClockFormatters.string(currentTime,
                               format: use12Hour ? "h:mm a" : "HH:mm",
                               timeZone: timeZone)
    }

    private var label: String {
        // Use abbreviation if available, otherwise city name from identifier
        let abbrev = timeZone.abbreviation(for: currentTime) ?? ""
        let city = timeZone.identifier.split(separator: "/").last.map(String.init) ?? timeZone.identifier
        let displayCity = city.replacingOccurrences(of: "_", with: " ")
        return abbrev.isEmpty ? displayCity : "\(displayCity) \(abbrev)"
    }
}

struct StatChip: View {
    let label: String
    let value: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)
            Text(value)
                .monitorFont(size: 13, weight: .medium)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }
}

/// Activity Monitor-style grid chart: each time bucket is a column of small squares.
/// More squares "lit" = higher usage. Drawn with Canvas to avoid sub-pixel gaps
/// from SwiftUI layout rounding of individual Rectangle views.
struct GridChart: View {
    let title: String
    let values: [Double] // 0-100 per bucket
    let accentColor: Color
    var height: CGFloat = 100
    let rows = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)

            Canvas { context, size in
                let cols = values.count
                guard cols > 0 else { return }
                let gap: CGFloat = 1
                let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
                let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                guard cellW > 0 && cellH > 0 else { return }

                let dimColor = Color.white.opacity(0.03)

                for col in 0..<cols {
                    let litCount = Int((values[col] / 100.0) * Double(rows))
                    let x = CGFloat(col) * (cellW + gap)

                    for row in 0..<rows {
                        let y = CGFloat(row) * (cellH + gap)
                        let isLit = row >= (rows - litCount)
                        let rect = CGRect(
                            x: x.rounded(.down),
                            y: y.rounded(.down),
                            width: (x + cellW).rounded(.down) - x.rounded(.down),
                            height: (y + cellH).rounded(.down) - y.rounded(.down)
                        )
                        context.fill(
                            Path(rect),
                            with: .color(isLit ? colorForLevel(values[col]) : dimColor)
                        )
                    }
                }
            }
            .frame(height: height)
            .clipped()
        }
    }

    private func colorForLevel(_ pct: Double) -> Color {
        if pct > 90 { return Color.onyxRed.opacity(0.9) }
        if pct > 70 { return Color.onyxAmber.opacity(0.8) }
        return Color.onyxBlue.opacity(0.7)
    }
}

/// Stands in for the charts when the stats poll isn't returning samples.
/// Carries the actual failure and how long it's been going, so the rest
/// of the overlay can carry on being useful around it.
struct StatsUnavailableCard: View {
    let error: String?
    let status: String
    let hostLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATS")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(error == nil ? Color.onyxBlue : Color.onyxRed)
                .tracking(2)

            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .monitorFont(size: 12, design: .default)
                            .foregroundColor(Color.onyxRed.opacity(0.9))
                        Text(error)
                            .monitorFont(size: 11)
                            .foregroundColor(Color.onyxRed.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .colorScheme(.dark)
                        Text("Fetching stats from \(hostLabel)…")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.6))
                        Spacer(minLength: 0)
                    }
                }

                Text(status)
                    .monitorFont(size: 9)
                    .foregroundColor(.gray.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.03))
        }
    }
}

struct CPUUnavailableCard: View {
    let message: String
    var height: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(Color.onyxBlue)
                .tracking(2)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .monitorFont(size: 11, design: .default)
                    .foregroundColor(Color.onyxAmber.opacity(0.8))
                Text(message)
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.7))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(Color.white.opacity(0.03))
        }
    }
}

/// The banner a fired page watch gets. Persistent until dismissed —
/// these fire once, often weeks after being set, and a toast you missed
/// is the same as no watch at all.
struct WatchFiredBanner: View {
    @ObservedObject private var store = PageWatchStore.shared

    var body: some View {
        let fired = store.fired
        if !fired.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fired) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color.onyxGreen)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.watch.label.uppercased())
                                .monitorFont(size: 11, weight: .medium)
                                .foregroundColor(Color.onyxGreen)
                                .tracking(1)
                            Text(entry.watch.trigger == .disappears
                                 ? "The line you were waiting to lose is gone from the page."
                                 : "The page changed the way you were waiting for.")
                                .monitorFont(size: 10)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer(minLength: 8)
                        Button(action: { open(entry.watch.url) }) {
                            Text("open")
                                .monitorFont(size: 10)
                                .foregroundColor(Color.onyxBlue)
                        }
                        .buttonStyle(.plain)
                        Button(action: { store.acknowledge(entry.id) }) {
                            Text("dismiss")
                                .monitorFont(size: 10)
                                .foregroundColor(.gray.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.onyxGreen.opacity(0.10))
                    .cornerRadius(6)
                }
            }
        }
    }

    private func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

/// One dim line per armed watch: what it's watching and when it last
/// looked.
///
/// The point isn't the timestamp, it's the freshness. A watch you're
/// counting on can fail silently for a week — the app quit, the network
/// changed, the page started 403ing — and "armed" and "broken" look
/// identical unless something says when it last actually ran. So the
/// stamp goes where you already look every day, and goes amber when it's
/// older than three intervals.
struct WatchStatusLine: View {
    @ObservedObject private var store = PageWatchStore.shared

    var body: some View {
        // Fired watches have the loud banner above; this is only for the
        // ones still waiting.
        let armed = store.entries.filter { $0.state.firedAt == nil && $0.watch.isRunnable }
        if !armed.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(armed) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "binoculars")
                            .font(.system(size: 9))
                            .foregroundColor(.gray.opacity(0.35))
                        Text(entry.watch.label)
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.45))
                            .lineLimit(1)
                        Text(detail(entry))
                            .monitorFont(size: 10)
                            .foregroundColor(color(entry))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func detail(_ entry: WatchEntry) -> String {
        if let err = entry.state.lastError { return "· \(err)" }
        guard let last = entry.state.lastCheck else { return "· not checked yet" }
        return "· checked \(Self.ago(last))"
    }

    private func color(_ entry: WatchEntry) -> Color {
        if entry.state.lastError != nil { return Color.onyxRed.opacity(0.65) }
        guard let last = entry.state.lastCheck else { return .gray.opacity(0.35) }
        let stale = TimeInterval(entry.watch.intervalMinutes * 60) * 3
        return Date().timeIntervalSince(last) > stale
            ? Color.onyxAmber.opacity(0.7)
            : .gray.opacity(0.35)
    }

    /// Relative, because "checked 4m ago" answers the question and
    /// "14:32" makes you do arithmetic to find out whether it's stuck.
    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
