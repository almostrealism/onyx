import SwiftUI

// MARK: - Fleet monitor layouts
//
// Two ways to look at every machine at once, both fed by CPUFleetPoller's
// existing 10s sweep — neither opens a single extra SSH connection.
//
//  STACKED  one row per host, charts full-width and shrinking vertically
//           as hosts are added. Full width is the whole point: every row
//           shares a time axis, so a spike on the trainer box and a spike
//           on the build box line up in the same column.
//
//  MERGED   one CPU chart and one GPU chart for the entire fleet, each
//           column the MAX across hosts — "if anyone is busy, we're
//           busy". Memory can't merge that way (it's an absolute number
//           over wildly different totals), so per-host memory charts sit
//           in a row underneath, side by side.

/// Rows of full-width charts, one host per row.
///
/// Charts only: the side panel and the bottom strip belong to whichever
/// layout is hosting these, so `F` swaps the chart area without
/// disturbing anything around it.
struct FleetStackedCharts: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitor: MonitorManager
    /// The fleet sweep writes here; observing it is what makes these
    /// charts live rather than frozen at whatever was buffered when the
    /// overlay opened.
    @ObservedObject private var streams = CPUStreamStore.shared
    let accentColor: Color
    /// Height to divide between the rows.
    let availableHeight: CGFloat
    /// Below this, a chart is a smear — used to decide whether memory
    /// rows are worth drawing at all in a cramped column.
    var minChartHeight: CGFloat = 22
    @Environment(\.monitorFontScale) private var fontScale

    var body: some View {
        let series = FleetSeries.build(
            streams: streams.snapshot(), hosts: appState.hosts,
            bucketSeconds: FleetSeries.bucketSeconds(shortInterval: monitor.useShortInterval))

        if series.isEmpty {
            FleetEmptyState(appState: appState)
        } else {
            // Every host contributes the same number of charts so the rows
            // stay the same height as each other — a row that happens to
            // have a GPU shouldn't be shorter than one that doesn't. Chart
            // count is decided once, by what the fleet as a whole has.
            let showGPU = series.contains { $0.gpu != nil }
            let showMem = monitor.showMemoryChart && series.contains { $0.mem != nil }
            let perHost = 1 + (showGPU ? 1 : 0) + (showMem ? 1 : 0)

            let headerHeight: CGFloat = 16 * fontScale
            let rowSpacing: CGFloat = 10
            let available = availableHeight
                - CGFloat(series.count) * headerHeight
                - CGFloat(max(0, series.count - 1)) * rowSpacing
            let chartHeight = max(minChartHeight,
                                  available / CGFloat(series.count * perHost) - 4)

            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(series) { host in
                    VStack(alignment: .leading, spacing: 3) {
                        FleetHostHeader(host: host, accentColor: accentColor)
                        GridChart(title: "CPU", values: host.cpu,
                                  accentColor: Color.onyxBlue, height: chartHeight)
                        if showGPU {
                            GridChart(title: "GPU", values: host.gpu ?? [],
                                      accentColor: Color.onyxPurple, height: chartHeight)
                        }
                        if showMem {
                            GridChart(title: "MEM", values: host.mem ?? [],
                                      accentColor: Color.onyxAmber, height: chartHeight)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// One merged CPU chart, one merged GPU chart, per-host memory beneath.
struct FleetMergedCharts: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitor: MonitorManager
    @ObservedObject private var streams = CPUStreamStore.shared
    let accentColor: Color
    let availableHeight: CGFloat
    @Environment(\.monitorFontScale) private var fontScale

    var body: some View {
        let series = FleetSeries.build(
            streams: streams.snapshot(), hosts: appState.hosts,
            bucketSeconds: FleetSeries.bucketSeconds(shortInterval: monitor.useShortInterval))

        if series.isEmpty {
            FleetEmptyState(appState: appState)
        } else {
            let cpu = FleetSeries.mergedMaxCPU(series)
            let gpu = FleetSeries.mergedMax(series, \.gpu)
            let memHosts = monitor.showMemoryChart ? series.filter { $0.mem != nil } : []

            // Memory takes a fixed slice off the bottom; the merged charts
            // split what's left. They're the headline, so they keep the
            // majority of the height at every size.
            let memHeight: CGFloat = memHosts.isEmpty ? 0 : min(110 * fontScale,
                                                                availableHeight * 0.3)
            let chartArea = max(0, availableHeight - memHeight - 20)
            let chartHeight = gpu.isEmpty ? chartArea - 20 : (chartArea / 2) - 20

            VStack(alignment: .leading, spacing: 10) {
                Text("FLEET MAX — \(series.count) HOST\(series.count == 1 ? "" : "S")")
                    .monitorFont(size: 9, weight: .medium)
                    .foregroundColor(.gray.opacity(0.4))
                    .tracking(2)

                GridChart(title: "CPU · MAX ACROSS HOSTS", values: cpu,
                          accentColor: Color.onyxBlue, height: max(30, chartHeight))
                if !gpu.isEmpty {
                    GridChart(title: "GPU · MAX ACROSS HOSTS", values: gpu,
                              accentColor: Color.onyxPurple, height: max(30, chartHeight))
                } else {
                    // Say so rather than just leaving a gap. A missing chart
                    // is indistinguishable from a broken one, and this exact
                    // silence hid an AMD host whose GPU was pinned at 100%.
                    Text("NO GPU REPORTED BY ANY HOST")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(.gray.opacity(0.35))
                        .tracking(2)
                    Text("AMD cards are read on their own 30s probe, and only on Linux hosts.")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.25))
                }

                if !memHosts.isEmpty {
                    // Side by side, so each host's memory gets a slice of the
                    // width. These deliberately DON'T share the time axis
                    // above them — they can't, at this width — so they're
                    // labelled per host and read as small multiples.
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(memHosts) { host in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.label.uppercased())
                                    .monitorFont(size: 9, weight: .medium)
                                    .foregroundColor(accentColor.opacity(0.6))
                                    .tracking(1)
                                    .lineLimit(1)
                                GridChart(title: "MEM", values: host.mem ?? [],
                                          accentColor: Color.onyxAmber,
                                          height: max(24, memHeight - 34))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

/// Top containers across the WHOLE fleet, not just the selected host.
///
/// The fleet sweep already collects each host's running containers (it
/// feeds the screensaver's orbiting moons), so this costs nothing extra —
/// it's the same data, ranked across machines instead of within one.
///
/// The bar is scaled to the busiest container on screen rather than to
/// total cores, because the stream doesn't carry a per-host core count
/// and 200% means very different things on a 4-core and a 64-core box.
/// So read the bar as "relative to the busiest thing running", which is
/// the question this strip is answering anyway.
struct FleetContainersStrip: View {
    @ObservedObject private var streams = CPUStreamStore.shared

    private let maxShown = 3

    var body: some View {
        let ranked = streams.snapshot()
            .flatMap { stream in
                (stream.containers ?? []).map { (host: stream.label, container: $0) }
            }
            .sorted { $0.container.cpu > $1.container.cpu }
            .prefix(maxShown)

        if !ranked.isEmpty {
            let scale = CGFloat(max(100, ranked.first?.container.cpu ?? 100))
            HStack(spacing: 10) {
                ForEach(Array(ranked), id: \.container.name) { entry in
                    FleetContainerPill(host: entry.host,
                                       name: entry.container.name,
                                       cpu: entry.container.cpu,
                                       scale: scale)
                }
            }
        }
    }
}

/// Same shape as the single-host pill, with the machine named — a
/// container called "api" tells you nothing when four hosts run one.
private struct FleetContainerPill: View {
    let host: String
    let name: String
    let cpu: Double
    let scale: CGFloat

    var body: some View {
        let pct = CGFloat(cpu)
        let color = monitorCPUBarColor(pct, maxPct: scale)
        HStack(spacing: 6) {
            Text(host)
                .monitorFont(size: 9)
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
            Text(name)
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(monitorCompactCPU(String(format: "%.1f%%", cpu)))
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.04)
                    Rectangle()
                        .fill(color.opacity(0.22))
                        .frame(width: geo.size.width * min(pct / scale, 1.0))
                }
            }
        )
        .cornerRadius(4)
    }
}

/// Host label plus its current readings, sized to be legible as a row
/// header when the chart under it is only a few points tall.
private struct FleetHostHeader: View {
    let host: FleetHostSeries
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(host.label.uppercased())
                .monitorFont(size: 11, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(1)
            Text("CPU \(Int(host.cpu.last ?? 0))%")
                .monitorFont(size: 10)
                .foregroundColor(.gray.opacity(0.55))
            if let gpu = host.gpu?.last {
                Text("GPU \(Int(gpu))%")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.55))
            }
            if let mem = host.mem?.last {
                Text("MEM \(Int(mem))%")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Why the fleet view is blank — never just an empty rectangle. The
/// honest answers differ, and the fix differs with them.
private struct FleetEmptyState: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let remotes = appState.hosts.filter { !$0.isLocal }
        let paused = remotes.filter(\.paused)

        VStack(alignment: .leading, spacing: 6) {
            Text(headline(remotes: remotes, paused: paused))
                .monitorFont(size: 12)
                .foregroundColor(.gray.opacity(0.5))
            if !remotes.isEmpty && paused.count < remotes.count {
                Text("The fleet sweep samples every 10s and only over connections that are already up.")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func headline(remotes: [HostConfig], paused: [HostConfig]) -> String {
        if remotes.isEmpty {
            return "No remote hosts configured — add one in Settings."
        }
        if paused.count == remotes.count {
            return "Every remote host is paused. Un-pause one in Settings to see it here."
        }
        return "Waiting for the first fleet samples…"
    }
}
