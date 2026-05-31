import AppKit
import SceneKit

/// Owns the SceneKit scene for the screensaver. Manages a set of `HostTotem`s
/// keyed by host ID, synced from a `[HostStream]` snapshot.
///
/// Data source priority:
/// 1. Live data from `CPUStreamReader` (the Onyx app's cpu-stream.json).
/// 2. Synthetic "mock" data when no live file is present or it's gone stale.
///    Keeps the System Settings preview lively even on a fresh install where
///    Onyx hasn't run yet.
final class SculptureScene: NSObject, SCNSceneRendererDelegate {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private var totems: [String: HostTotem] = [:]
    private var insertionCounter = 0
    private var lastRenderTime: TimeInterval = 0

    private let reader = CPUStreamReader()
    private var liveDataActive = false

    // Mock driver state — used when live data isn't available.
    private var mockBuffers: [String: [CPUSample]] = [:]
    private var mockStartTime: TimeInterval = 0
    private var mockTimer: Timer?

    init(isPreview: Bool) {
        super.init()
        scene.background.contents = NSColor.black
        setupCamera(isPreview: isPreview)
        setupLights()

        // Live reader runs everywhere — the System Settings preview also
        // benefits if Onyx is running and broadcasting real data.
        reader.onUpdate = { [weak self] hosts in self?.handleLiveUpdate(hosts: hosts) }
        reader.onIdle = { [weak self] in self?.handleIdle() }
        reader.start()

        // Mock driver starts immediately so we have something on screen
        // during the first 500ms before the reader has fired its first tick.
        // It pauses the moment live data arrives.
        startMockDriver()
    }

    deinit {
        mockTimer?.invalidate()
        reader.stop()
    }

    // MARK: - Data source coordination

    private func handleLiveUpdate(hosts: [HostStream]) {
        // Onyx is running but has zero hosts configured (fresh install,
        // or every host removed). Treat as idle so the user still sees
        // *something* — the mock visualization is more interesting than
        // an empty scene.
        if hosts.isEmpty {
            handleIdle()
            return
        }
        // First fresh sample from the live stream — kill the mock driver,
        // clear any mock totems, and start rendering real data.
        if !liveDataActive {
            liveDataActive = true
            stopMockDriver()
            removeAllTotems()
        }
        update(hosts: hosts)
    }

    private func handleIdle() {
        // Live stream went away (Onyx quit, file stale). Fall back to mock
        // so the user still has something pretty to look at instead of
        // staring at a black screen.
        if liveDataActive {
            liveDataActive = false
            removeAllTotems()
        }
        if mockTimer == nil {
            startMockDriver()
        }
    }

    // MARK: - Update / layout

    /// Sync the totem set to match `hosts`. Adds new totems, removes gone
    /// ones, pushes per-host samples into each totem. Positions are
    /// motion-driven (see `renderer(_:updateAtTime:)`); we only seed the
    /// starting position for newly-added totems.
    func update(hosts: [HostStream]) {
        let incomingIDs = Set(hosts.map { $0.hostID })
        let existingIDs = Set(totems.keys)

        for goneID in existingIDs.subtracting(incomingIDs) {
            totems[goneID]?.rootNode.removeFromParentNode()
            totems.removeValue(forKey: goneID)
        }

        for stream in hosts where totems[stream.hostID] == nil {
            let color = NSColor.fromOnyxHex(stream.color) ?? defaultColor(for: stream.hostID)
            let totem = HostTotem(hostID: stream.hostID, color: color,
                                  seed: insertionCounter)
            insertionCounter += 1
            // Spawn at a stable offset around origin so newcomers don't pop
            // in on top of existing totems — the motion engine then takes
            // them wherever they want to drift.
            totem.motion.position = spawnPosition(for: insertionCounter)
            totem.rootNode.position = totem.motion.position
            totems[stream.hostID] = totem
            scene.rootNode.addChildNode(totem.rootNode)
        }

        for stream in hosts {
            totems[stream.hostID]?.update(samples: stream.samples)
            totems[stream.hostID]?.setLabel(stream.label)
        }
    }

    /// Initial position around the origin, spread on a circle so the first
    /// few totems start well-separated rather than clumped near origin.
    private func spawnPosition(for index: Int) -> SCNVector3 {
        let angle = Float(index) * (2 * .pi / 5)
        let radius: Float = 14
        return SCNVector3(radius * cos(angle), 0, radius * sin(angle))
    }

    // MARK: - SCNSceneRendererDelegate

    /// SceneKit calls this once per frame. We compute dt, advance motion
    /// state for every totem, then write the resulting positions back onto
    /// their nodes.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt: Float
        if lastRenderTime > 0 {
            dt = Float(time - lastRenderTime)
        } else {
            dt = 1.0 / 60.0  // first frame — pretend 60fps
        }
        lastRenderTime = time
        guard !totems.isEmpty else { return }

        // Collect → advance → write back. The Motion engine doesn't know
        // about SceneKit nodes; we hand it raw position/velocity pairs.
        let ids = totems.keys.sorted()  // stable order for reproducible math
        var states = ids.map { totems[$0]!.motion }
        Motion.advance(&states, dt: dt)
        for (i, id) in ids.enumerated() {
            guard let totem = totems[id] else { continue }
            totem.motion = states[i]
            totem.rootNode.position = states[i].position
        }
    }

    private func removeAllTotems() {
        for (_, totem) in totems {
            totem.rootNode.removeFromParentNode()
        }
        totems.removeAll()
    }

    // MARK: - Scene setup

    private func setupCamera(isPreview: Bool) {
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 500
        camera.fieldOfView = isPreview ? 65 : 55
        // Subtle depth-of-field — keeps the foreground crisp but blurs the
        // back of the scene slightly, makes the 3D space feel deeper without
        // ever looking out of focus.
        camera.wantsDepthOfField = true
        camera.focusDistance = 55
        camera.fStop = 8
        cameraNode.camera = camera
        // Pulled back a touch and tilted slightly down: a 3/4 view reads as
        // more dimensional than dead-on, and a 6° downward tilt makes the
        // tops of the totems just visible without distorting the silhouette.
        cameraNode.position = SCNVector3(0, 4, 58)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 30, 0, 0)
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

    // MARK: - Mock data driver (idle fallback)

    /// Synthetic three-host CPU history. Used when no live stream is
    /// available — e.g. System Settings preview without Onyx running, or
    /// the rare gap where Onyx has been quit and the file has gone stale.
    private static let mockHosts: [(id: String, label: String, color: String, phase: Double, period: Double)] = [
        ("mock-1", "alpha", "#FF8C42", 0.0, 7.0),
        ("mock-2", "beta",  "#22DDFF", 2.5, 11.0),
        ("mock-3", "gamma", "#88FF66", 4.0, 5.0),
    ]

    private func startMockDriver() {
        mockStartTime = Date().timeIntervalSince1970
        mockBuffers.removeAll()

        // Pre-roll so the totems start fully formed.
        for k in stride(from: HostTotem.maxRings - 1, through: 0, by: -1) {
            advanceMock(secondsAgo: Double(k) * 0.4)
        }

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.advanceMock(secondsAgo: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        mockTimer = timer
    }

    private func stopMockDriver() {
        mockTimer?.invalidate()
        mockTimer = nil
        mockBuffers.removeAll()
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
