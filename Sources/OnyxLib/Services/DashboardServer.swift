import Foundation
import Network

/// Lightweight HTTP server that serves a live-updating monitoring dashboard.
/// Designed to be opened as a browser new-tab page for at-a-glance system status.
public class DashboardServer {
    private var listener: NWListener?
    private weak var appState: AppState?
    /// private(set) var port: UInt16?
    public private(set) var port: UInt16?

    /// Fixed port so browser bookmarks/new-tab settings work across restarts
    public static let defaultPort: UInt16 = 19433

    /// Create a new instance.
    public init(appState: AppState) {
        self.appState = appState
    }

    /// Start.
    public func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.defaultPort)!)

            listener = try NWListener(using: params)
            listener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener?.port {
                    self?.port = port.rawValue
                    print("Dashboard HTTP server ready on http://127.0.0.1:\(port.rawValue)/")
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .global(qos: .utility))
        } catch {
            print("Dashboard server failed to start: \(error)")
        }
    }

    /// Stop.
    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, _ in
            guard let self = self, let data = content, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the HTTP request line
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            let response: (String, String, String) // (status, contentType, body)
            switch path {
            case "/api/stats":
                response = ("200 OK", "application/json", self.jsonStats())
            case "/":
                response = ("200 OK", "text/html; charset=utf-8", Self.dashboardHTML)
            default:
                response = ("404 Not Found", "text/plain", "Not found")
            }

            let httpResponse = """
            HTTP/1.1 \(response.0)\r
            Content-Type: \(response.1)\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            Content-Length: \(response.2.utf8.count)\r
            \r
            \(response.2)
            """

            connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - JSON API

    private func jsonStats() -> String {
        guard let appState = appState else { return "{}" }

        var dict: [String: Any] = [:]

        // Latest sample
        if let sample = appState.monitor.latestSample {
            var s: [String: Any] = [:]
            if let cpu = sample.cpuUsage { s["cpu"] = Int(cpu) }
            if let used = sample.memUsed { s["memUsed"] = Int(used) }
            if let total = sample.memTotal { s["memTotal"] = Int(total) }
            if let gpu = sample.gpuUsage { s["gpu"] = Int(gpu) }
            if let temp = sample.gpuTemp { s["gpuTemp"] = temp }
            if let name = sample.gpuName { s["gpuName"] = name }
            if let l1 = sample.loadAvg1 { s["load1"] = String(format: "%.2f", l1) }
            if let l5 = sample.loadAvg5 { s["load5"] = String(format: "%.2f", l5) }
            if let l15 = sample.loadAvg15 { s["load15"] = String(format: "%.2f", l15) }
            dict["sample"] = s
        }

        // CPU history (last 60 buckets)
        let cpuData = appState.monitor.bucketedCPU()
        if !cpuData.isEmpty { dict["cpuHistory"] = cpuData.map { Int($0) } }

        // GPU history
        let gpuData = appState.monitor.bucketedGPU()
        if !gpuData.isEmpty { dict["gpuHistory"] = gpuData.map { Int($0) } }

        // Connections
        let conns = appState.connectionPool + appState.pendingConnections.filter { pending in
            !appState.connectionPool.contains(where: { $0.id == pending.id })
        }
        dict["connections"] = conns.map { conn in
            [
                "label": conn.label,
                "host": conn.hostLabel,
                "status": conn.status,
                "color": conn.statusColor,
            ] as [String: Any]
        }

        // Host
        dict["host"] = appState.activeHost?.label ?? "local"
        dict["session"] = appState.activeSession?.displayLabel ?? ""

        // Serialize
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return "{}" }
        return jsonString
    }

    // MARK: - Dashboard HTML

    static let dashboardHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>Onyx Monitor</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        background: #0a0a0a;
        color: #d9d9d9;
        font-family: 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace;
        font-size: 13px;
        padding: 40px;
        min-height: 100vh;
    }
    .header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 24px;
    }
    .time {
        font-size: 36px;
        font-weight: 200;
        color: rgba(255,255,255,0.9);
        letter-spacing: 2px;
    }
    .date {
        font-size: 12px;
        color: rgba(102,204,255,0.6);
        margin-top: 2px;
    }
    .chips {
        display: flex;
        gap: 12px;
    }
    .chip {
        padding: 8px 14px;
        background: rgba(255,255,255,0.04);
        border-radius: 6px;
        text-align: center;
    }
    .chip .label {
        font-size: 9px;
        font-weight: 500;
        letter-spacing: 2px;
        margin-bottom: 2px;
    }
    .chip .value {
        font-size: 13px;
        font-weight: 500;
        color: rgba(255,255,255,0.85);
    }
    .chip.cpu .label { color: #66CCFF; }
    .chip.mem .label { color: #FFD06B; }
    .chip.gpu .label { color: #C06BFF; }
    .chip.temp .label { color: #FF6B6B; }

    .divider {
        height: 1px;
        background: rgba(255,255,255,0.1);
        margin: 20px 0;
    }
    .row {
        display: flex;
        gap: 24px;
        margin-bottom: 20px;
    }
    .col { flex: 1; }
    .section-title {
        font-size: 10px;
        font-weight: 500;
        letter-spacing: 2px;
        color: #66CCFF;
        margin-bottom: 8px;
    }
    .chart-container {
        height: 100px;
        display: flex;
        align-items: flex-end;
        gap: 1px;
        margin-bottom: 16px;
    }
    .chart-container.small { height: 50px; }
    .bar {
        flex: 1;
        background: rgba(255,255,255,0.03);
        border-radius: 1px;
        position: relative;
        min-width: 2px;
    }
    .bar .fill {
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        border-radius: 1px;
        transition: height 0.3s ease;
    }
    .conn-row {
        display: flex;
        align-items: center;
        padding: 4px 0;
        font-size: 11px;
        gap: 8px;
    }
    .conn-dot {
        width: 5px;
        height: 5px;
        border-radius: 50%;
        flex-shrink: 0;
    }
    .conn-label { flex: 1; color: rgba(255,255,255,0.7); }
    .conn-host { width: 80px; text-align: right; color: rgba(255,255,255,0.7); }
    .conn-status { width: 85px; text-align: right; }
    .empty { color: rgba(255,255,255,0.3); font-size: 11px; }
    .meta {
        font-size: 10px;
        color: rgba(255,255,255,0.25);
        text-align: center;
        margin-top: 12px;
    }
    @keyframes pulse {
        0%, 100% { opacity: 0.3; }
        50% { opacity: 1; }
    }
    .pulsing { animation: pulse 1.6s ease-in-out infinite; }
    </style>
    </head>
    <body>
    <div class="header">
        <div>
            <div class="time" id="time">--:--:--</div>
            <div class="date" id="date"></div>
        </div>
        <div class="chips" id="chips"></div>
    </div>
    <div class="divider"></div>
    <div class="row">
        <div class="col">
            <div class="section-title">CPU</div>
            <div class="chart-container" id="cpuChart"></div>
            <div class="section-title">GPU</div>
            <div class="chart-container small" id="gpuChart"></div>
        </div>
        <div class="col">
            <div class="section-title">CONNECTIONS</div>
            <div id="connections"><span class="empty">No connections</span></div>
        </div>
    </div>
    <div class="meta" id="meta"></div>

    <script>
    function updateClock() {
        const now = new Date();
        document.getElementById('time').textContent =
            now.toTimeString().split(' ')[0];
        document.getElementById('date').textContent =
            now.toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
    }

    function barColor(pct) {
        if (pct > 90) return 'rgba(255,107,107,0.9)';
        if (pct > 70) return 'rgba(255,208,107,0.8)';
        return 'rgba(102,204,255,0.7)';
    }

    function gpuBarColor(pct) {
        if (pct > 90) return 'rgba(255,107,107,0.9)';
        if (pct > 70) return 'rgba(255,208,107,0.8)';
        return 'rgba(192,107,255,0.7)';
    }

    function renderChart(id, data, colorFn) {
        const el = document.getElementById(id);
        if (!data || data.length === 0) {
            el.innerHTML = '<span class="empty">No data</span>';
            return;
        }
        el.innerHTML = data.map(v =>
            `<div class="bar"><div class="fill" style="height:${v}%;background:${colorFn(v)}"></div></div>`
        ).join('');
    }

    function renderConnections(conns) {
        const el = document.getElementById('connections');
        if (!conns || conns.length === 0) {
            el.innerHTML = '<span class="empty">No connections</span>';
            return;
        }
        el.innerHTML = conns.map(c => {
            const transient = ['connecting','reconnecting','enumerating'].includes(c.status);
            return `<div class="conn-row">
                <div class="conn-dot ${transient ? 'pulsing' : ''}" style="background:#${c.color}"></div>
                <div class="conn-label">${c.label}</div>
                <div class="conn-host">${c.host}</div>
                <div class="conn-status" style="color:#${c.color}CC">${c.status}</div>
            </div>`;
        }).join('');
    }

    function renderChips(s) {
        const el = document.getElementById('chips');
        let html = '';
        if (s.cpu !== undefined) html += `<div class="chip cpu"><div class="label">CPU</div><div class="value">${s.cpu}%</div></div>`;
        if (s.memUsed !== undefined && s.memTotal) {
            const used = s.memUsed >= 1024 ? (s.memUsed/1024).toFixed(1)+' GB' : s.memUsed+' MB';
            const total = s.memTotal >= 1024 ? (s.memTotal/1024).toFixed(1)+' GB' : s.memTotal+' MB';
            html += `<div class="chip mem"><div class="label">MEM</div><div class="value">${used} / ${total}</div></div>`;
        }
        if (s.gpu !== undefined) html += `<div class="chip gpu"><div class="label">GPU</div><div class="value">${s.gpu}%</div></div>`;
        if (s.gpuTemp !== undefined) html += `<div class="chip temp"><div class="label">TEMP</div><div class="value">${s.gpuTemp}°C</div></div>`;
        el.innerHTML = html;
    }

    async function refresh() {
        try {
            const res = await fetch('/api/stats');
            const data = await res.json();
            if (data.sample) renderChips(data.sample);
            renderChart('cpuChart', data.cpuHistory, barColor);
            renderChart('gpuChart', data.gpuHistory, gpuBarColor);
            renderConnections(data.connections);
            const host = data.host || '';
            const session = data.session || '';
            document.getElementById('meta').textContent =
                host ? `${host} — ${session}` : '';
        } catch(e) {
            document.getElementById('meta').textContent = 'Onyx not running';
        }
    }

    updateClock();
    setInterval(updateClock, 1000);
    refresh();
    setInterval(refresh, 5000);
    </script>
    </body>
    </html>
    """
}
