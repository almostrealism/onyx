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

    init(appState: AppState) {
        self.appState = appState
        self.monitor = appState.monitor
        self.dockerStats = appState.dockerStats
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

                    // RIGHT: Stat chips
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
                            if let temp = sample.gpuTemp {
                                StatChip(label: "TEMP", value: "\(temp)°C", accentColor: Color.onyxRed)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 40)

                if let _ = monitor.latestSample {
                    // Interval label
                    HStack(spacing: 4) {
                        Text(monitor.useShortInterval ? "5s intervals" : "1m intervals")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                        Text("(T interval · M memory · C containers · P 12/24hr · S simple · X peek)")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.25))
                    }

                    // Claude Code sessions banner (if any active) — stays
                    // full-width above the split.
                    if !appState.claudeSessions.activeSessions.isEmpty || !appState.claudeSessions.pendingPermissions.isEmpty {
                        ClaudeSessionsSection(appState: appState)
                            .padding(.horizontal, 40)
                    }

                    if appState.showSimpleMonitor {
                        SimpleMonitorBody(
                            appState: appState,
                            monitor: monitor,
                            dockerStats: dockerStats,
                            timing: appState.timing,
                            accentColor: appState.accentColor
                        )
                        .padding(.horizontal, 40)
                    } else {
                    // Main region: vertical split. Left ~65% holds timing,
                    // CPU/MEM/GPU charts, then reminders directly underneath.
                    // Right ~35% holds containers then connections.
                    GeometryReader { geo in
                        let rightWidth = max(280, geo.size.width * 0.35)
                        HStack(alignment: .top, spacing: 0) {
                            VStack(alignment: .leading, spacing: 16) {
                                if appState.timing.isConfigured {
                                    TimingChartSection(timing: appState.timing, accentColor: appState.accentColor)
                                }
                                // Two-column layout below the timing chart:
                                // - Left:  reminders (often long; gets
                                //          a column to itself)
                                // - Right: session notes → PRs → pipelines
                                //          (the work-tracking column,
                                //          ordered the way work flows:
                                //          jot a note, work on it, open
                                //          a PR, watch the pipeline)
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        RemindersSection(appState: appState)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    VStack(alignment: .leading, spacing: 16) {
                                        SessionNotesSection(appState: appState)
                                        PullRequestsSection(appState: appState)
                                        PipelinesSection(appState: appState)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.trailing, 20)

                            Divider()
                                .background(Color.white.opacity(0.1))

                            VStack(alignment: .leading, spacing: 16) {
                                let cpuData = monitor.bucketedCPU()
                                if !cpuData.isEmpty {
                                    GridChart(
                                        title: "CPU",
                                        values: cpuData,
                                        accentColor: Color.onyxBlue
                                    )
                                } else {
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
                } else if let error = monitor.lastError {
                    // Even when stats failed, surface the connection pool
                    // so the user can diagnose any host's mux state — that
                    // diagnostic panel is exactly what's needed to figure
                    // out *why* the stats aren't coming in.
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .monitorFont(size: 20, design: .default)
                                .foregroundColor(Color.onyxRed)
                            Text(error)
                                .monitorFont(size: 12)
                                .foregroundColor(Color.onyxRed.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                            Text("Retrying every 5s... (attempt \(monitor.pollCount))")
                                .monitorFont(size: 10)
                                .foregroundColor(.gray.opacity(0.4))
                        }
                        ConnectionPoolSection(appState: appState)
                            .frame(maxWidth: 480)
                    }
                    .padding(.horizontal, 40)
                } else {
                    VStack(spacing: 16) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .colorScheme(.dark)
                            Text("Fetching stats from \(appState.activeHost?.label ?? "host")...")
                                .monitorFont(size: 12)
                                .foregroundColor(.gray.opacity(0.5))
                        }
                        // Connection pool is always useful — especially
                        // while we're stuck waiting for the active host's
                        // first sample.
                        ConnectionPoolSection(appState: appState)
                            .frame(maxWidth: 480)
                    }
                    .padding(.horizontal, 40)
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

