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
struct FleetStackedBody: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitor: MonitorManager
    /// The fleet sweep writes here; observing it is what makes these
    /// layouts live rather than frozen at whatever was buffered when the
    /// overlay opened.
    @ObservedObject private var streams = CPUStreamStore.shared
    let accentColor: Color
    @Environment(\.monitorFontScale) private var fontScale

    var body: some View {
        GeometryReader { geo in
            let series = FleetSeries.build(streams: streams.snapshot(),
                                           hosts: appState.hosts)
            if series.isEmpty {
                FleetEmptyState(appState: appState)
            } else {
                // Every host contributes the same number of charts so the
                // rows stay the same height as each other — a row that
                // happens to have a GPU shouldn't be shorter than one that
                // doesn't. Chart count is decided once, by what the fleet
                // as a whole has.
                let showGPU = series.contains { $0.gpu != nil }
                let showMem = monitor.showMemoryChart && series.contains { $0.mem != nil }
                let perHost = 1 + (showGPU ? 1 : 0) + (showMem ? 1 : 0)

                let headerHeight: CGFloat = 18 * fontScale
                let rowSpacing: CGFloat = 14
                let available = geo.size.height
                    - CGFloat(series.count) * headerHeight
                    - CGFloat(max(0, series.count - 1)) * rowSpacing
                // A floor of 22pt: below that a chart is a smear, and it's
                // better to overflow (and let the user close a host or
                // turn memory off) than to draw something unreadable.
                let chartHeight = max(22, available / CGFloat(series.count * perHost) - 4)

                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(series) { host in
                        VStack(alignment: .leading, spacing: 4) {
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
                }
            }
        }
    }
}

/// One merged CPU chart, one merged GPU chart, per-host memory beneath.
struct FleetMergedBody: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitor: MonitorManager
    @ObservedObject private var streams = CPUStreamStore.shared
    let accentColor: Color
    @Environment(\.monitorFontScale) private var fontScale

    var body: some View {
        GeometryReader { geo in
            let series = FleetSeries.build(streams: streams.snapshot(),
                                           hosts: appState.hosts)
            if series.isEmpty {
                FleetEmptyState(appState: appState)
            } else {
                let cpu = FleetSeries.mergedMaxCPU(series)
                let gpu = FleetSeries.mergedMax(series, \.gpu)
                let memHosts = monitor.showMemoryChart
                    ? series.filter { $0.mem != nil }
                    : []

                // Memory takes a fixed slice off the bottom; the merged
                // charts split what's left. They're the headline, so they
                // keep the majority of the height at every window size.
                let memHeight: CGFloat = memHosts.isEmpty ? 0 : 110 * fontScale
                let chartArea = max(0, geo.size.height - memHeight - 16)
                let chartHeight = gpu.isEmpty ? chartArea - 24 : (chartArea / 2) - 24

                VStack(alignment: .leading, spacing: 12) {
                    Text("FLEET MAX — \(series.count) HOST\(series.count == 1 ? "" : "S")")
                        .monitorFont(size: 9, weight: .medium)
                        .foregroundColor(.gray.opacity(0.4))
                        .tracking(2)

                    GridChart(title: "CPU · MAX ACROSS HOSTS", values: cpu,
                              accentColor: Color.onyxBlue,
                              height: max(40, chartHeight))
                    if !gpu.isEmpty {
                        GridChart(title: "GPU · MAX ACROSS HOSTS", values: gpu,
                                  accentColor: Color.onyxPurple,
                                  height: max(40, chartHeight))
                    } else {
                        // Say so rather than just leaving a gap. A missing
                        // chart is indistinguishable from a broken one,
                        // and this exact silence hid an AMD host whose GPU
                        // was pinned at 100%.
                        Text("NO GPU REPORTED BY ANY HOST")
                            .monitorFont(size: 10, weight: .medium)
                            .foregroundColor(.gray.opacity(0.35))
                            .tracking(2)
                        Text("AMD cards are read on their own 30s probe, and only on Linux hosts.")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.25))
                    }

                    if !memHosts.isEmpty {
                        // Side by side, so each host's memory gets a
                        // slice of the width. These deliberately DON'T
                        // share the time axis above them — they can't,
                        // at this width — so they're labelled per host
                        // and read as their own small multiples.
                        HStack(alignment: .bottom, spacing: 10) {
                            ForEach(memHosts) { host in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.label.uppercased())
                                        .monitorFont(size: 9, weight: .medium)
                                        .foregroundColor(accentColor.opacity(0.6))
                                        .tracking(1)
                                        .lineLimit(1)
                                    GridChart(title: "MEM",
                                              values: host.mem ?? [],
                                              accentColor: Color.onyxAmber,
                                              height: max(30, memHeight - 40))
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
