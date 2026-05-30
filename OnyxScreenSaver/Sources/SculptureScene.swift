import AppKit
import SceneKit

/// Owns the SceneKit scene for the screensaver. Manages a set of `HostTotem`s
/// keyed by host ID, synced from a `[HostStream]` snapshot.
///
/// Phase 2 wires the renderer up to a synthetic mock-data driver so we can
/// verify the visuals before standing up the file-based IPC. Phase 4 will
/// swap the mock driver for `CPUStreamReader`.
final class SculptureScene {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private var totems: [String: HostTotem] = [:]

    // Mock driver state (phase 2 only).
    private var mockBuffers: [String: [CPUSample]] = [:]
    private var mockStartTime: TimeInterval = 0
    private var mockTimer: Timer?

    init(isPreview: Bool) {
        scene.background.contents = NSColor.black
        setupCamera(isPreview: isPreview)
        setupLights()
        startMockDriver()
    }

    deinit {
        mockTimer?.invalidate()
    }

    // MARK: - Public API

    /// Sync the totem set to match `hosts`. Adds new totems, removes gone
    /// ones, lays out the survivors side-by-side, then pushes per-host
    /// samples into their totem.
    func update(hosts: [HostStream]) {
        let incomingIDs = Set(hosts.map { $0.hostID })
        let existingIDs = Set(totems.keys)

        for goneID in existingIDs.subtracting(incomingIDs) {
            totems[goneID]?.rootNode.removeFromParentNode()
            totems.removeValue(forKey: goneID)
        }

        for stream in hosts where totems[stream.hostID] == nil {
            let color = NSColor.fromOnyxHex(stream.color) ?? defaultColor(for: stream.hostID)
            let totem = HostTotem(hostID: stream.hostID, color: color)
            totems[stream.hostID] = totem
            scene.rootNode.addChildNode(totem.rootNode)
        }

        // Simple horizontal layout for phase 2. Phase 5's motion code will
        // take over and these become starting positions instead.
        let spacing: Float = 14
        let totalWidth = Float(max(hosts.count - 1, 0)) * spacing
        for (i, stream) in hosts.enumerated() {
            guard let totem = totems[stream.hostID] else { continue }
            let x = Float(i) * spacing - totalWidth / 2
            totem.rootNode.position = SCNVector3(x, 0, 0)
            totem.update(samples: stream.samples)
        }
    }

    // MARK: - Scene setup

    private func setupCamera(isPreview: Bool) {
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 500
        // Wider FOV so 3+ totems fit comfortably even in the preview window.
        camera.fieldOfView = isPreview ? 65 : 55
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 55)
        scene.rootNode.addChildNode(cameraNode)
    }

    private func setupLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 250
        ambient.light?.color = NSColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Two directional lights, one warm and one cool, at opposing angles.
        // Reads better than a single key light on a rotating object — the
        // back-lit side never goes fully black.
        let warm = SCNNode()
        warm.light = SCNLight()
        warm.light?.type = .directional
        warm.light?.intensity = 700
        warm.light?.color = NSColor(calibratedHue: 0.08, saturation: 0.25,
                                    brightness: 1.0, alpha: 1.0)
        warm.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(warm)

        let cool = SCNNode()
        cool.light = SCNLight()
        cool.light?.type = .directional
        cool.light?.intensity = 350
        cool.light?.color = NSColor(calibratedHue: 0.58, saturation: 0.3,
                                    brightness: 1.0, alpha: 1.0)
        cool.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi * 0.6, 0)
        scene.rootNode.addChildNode(cool)
    }

    // MARK: - Mock data driver (phase 2 only)

    /// Generates synthetic CPU history for three hosts so we can verify the
    /// renderer end-to-end before standing up file IPC.
    ///
    /// Each mock host uses a different sine period and phase offset so the
    /// rings scroll at different rates and the visual scan-cycle never lines
    /// up — keeps the screensaver from looking like a synchronized chart.
    private static let mockHosts: [(id: String, label: String, color: String, phase: Double, period: Double)] = [
        ("mock-1", "alpha", "#FF8800", 0.0, 7.0),
        ("mock-2", "beta",  "#22DDFF", 2.5, 11.0),
        ("mock-3", "gamma", "#88FF66", 4.0, 5.0),
    ]

    private func startMockDriver() {
        mockStartTime = Date().timeIntervalSince1970

        // Seed: pre-roll a full history so the totems start fully formed
        // instead of growing up from nothing while the user is watching.
        for k in stride(from: HostTotem.maxRings - 1, through: 0, by: -1) {
            advanceMock(secondsAgo: Double(k) * 0.4)
        }

        // Live tick: new sample every 0.4s so motion is clearly visible.
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.advanceMock(secondsAgo: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        mockTimer = timer
    }

    private func advanceMock(secondsAgo: Double) {
        let now = Date().timeIntervalSince1970
        let elapsed = now - mockStartTime - secondsAgo

        var streams: [HostStream] = []
        for h in Self.mockHosts {
            let raw = 50 + 45 * sin(2 * .pi * (elapsed + h.phase) / h.period)
            let sample = CPUSample(t: now - secondsAgo, cpu: raw)
            var buf = mockBuffers[h.id] ?? []
            buf.append(sample)
            if buf.count > HostTotem.maxRings {
                buf.removeFirst(buf.count - HostTotem.maxRings)
            }
            mockBuffers[h.id] = buf
            streams.append(HostStream(hostID: h.id, label: h.label,
                                      color: h.color, samples: buf))
        }
        update(hosts: streams)
    }

    // MARK: - Color fallback

    private static let fallbackHues: [CGFloat] = [0.08, 0.55, 0.32, 0.85, 0.0, 0.65]

    private func defaultColor(for hostID: String) -> NSColor {
        let idx = abs(hostID.hashValue) % Self.fallbackHues.count
        return NSColor(calibratedHue: Self.fallbackHues[idx],
                       saturation: 0.85, brightness: 1.0, alpha: 1.0)
    }
}
