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
    private let originBall = OriginBall()
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
        setupEnvironment()
        setupCamera(isPreview: isPreview)
        setupLights()

        // The origin ball sits at center; hidden until the publisher
        // sends a positive weeklyHours value.
        scene.rootNode.addChildNode(originBall.rootNode)
        originBall.setHours(nil)

        // Live reader runs everywhere — the System Settings preview also
        // benefits if Onyx is running and broadcasting real data.
        reader.onUpdate = { [weak self] hosts, weeklyHours in
            self?.handleLiveUpdate(hosts: hosts, weeklyHours: weeklyHours)
        }
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

    private func handleLiveUpdate(hosts: [HostStream], weeklyHours: Double?) {
        // The Timing ball is independent of host data — update it
        // unconditionally so it grows/shrinks with hours worked even
        // during gaps in CPU samples.
        originBall.setHours(weeklyHours)

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
        originBall.setHours(nil)
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
            // in on top of existing totems. Initial velocity is tangential
            // to that offset so the totem starts on an orbit-friendly arc
            // rather than barreling toward center.
            let spawn = spawnPosition(for: insertionCounter)
            totem.motion.position = spawn
            totem.motion.velocity = Motion.initialVelocity(
                position: spawn, seed: insertionCounter)
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
        let radius: Float = 20
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
        // The origin ball joins the array as the last element so totems
        // collide and exchange gravity with it like any other body.
        let ids = totems.keys.sorted()  // stable order for reproducible math
        var states = ids.map { totems[$0]!.motion }
        let ballIncluded = !originBall.rootNode.isHidden
        if ballIncluded { states.append(originBall.motion) }

        Motion.advance(&states, dt: dt)

        for (i, id) in ids.enumerated() {
            guard let totem = totems[id] else { continue }
            totem.motion = states[i]
            totem.rootNode.position = states[i].position
        }
        if ballIncluded {
            originBall.motion = states[ids.count]
            originBall.rootNode.position = originBall.motion.position
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

    /// Image-based lighting for the PBR materials. The metallic cubes have
    /// nothing to reflect unless we give SceneKit an environment map — the
    /// usual choice is an HDRI, but we don't want to ship asset files for
    /// a single screensaver. So we synthesize an equirectangular 2:1 image
    /// at runtime: a vertical gradient from a warm overhead "ceiling" tone
    /// through neutral mid-gray "horizon" to a dim, slightly-cool "floor".
    /// Polished metals reflecting this gradient pick up the soft warm-on-top
    /// shading that reads as "indoor studio lighting" without anyone having
    /// to model an actual room.
    private func setupEnvironment() {
        scene.lightingEnvironment.contents = Self.proceduralEnvironment()
        // Bumped to 2.5 — the procedural environment is in SDR range
        // (NSImage can't hold values > 1.0 per channel), so the intensity
        // multiplier is how we "fake HDR" for visible specular pop.
        scene.lightingEnvironment.intensity = 2.5
    }

    /// Synthesize the equirectangular environment image at runtime so we
    /// don't ship an HDRI. Gradient backdrop + a few sharp bright bands
    /// running horizontally; on a low-roughness metallic totem, the
    /// bands appear as crisp reflected streaks that move across the cube
    /// faces as the totem rotates — clearly readable as "reflection",
    /// which the smooth gradient on its own wasn't.
    private static func proceduralEnvironment() -> NSImage {
        let size = NSSize(width: 1024, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        // 1) Three-stop vertical gradient: warm top → neutral horizon → cool floor.
        let ceiling = NSColor(calibratedHue: 0.09, saturation: 0.40,
                              brightness: 0.55, alpha: 1.0)
        let horizon = NSColor(calibratedHue: 0.58, saturation: 0.20,
                              brightness: 0.25, alpha: 1.0)
        let floor   = NSColor(calibratedHue: 0.62, saturation: 0.35,
                              brightness: 0.05, alpha: 1.0)
        NSGradient(colorsAndLocations:
            (ceiling, 0.0),
            (horizon, 0.55),
            (floor,   1.0)
        )?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // 2) Sharp bright bands near the top — read as overhead light strips.
        //    Equirectangular convention: y=size.height is the top of the
        //    sphere (zenith), y=0 is the bottom. We place bands close to
        //    the top so they appear "overhead" in the scene.
        NSColor.white.setFill()
        let bands: [(yFrac: CGFloat, heightFrac: CGFloat, alpha: CGFloat)] = [
            (0.88, 0.012, 1.00),  // brightest, thinnest — primary highlight
            (0.78, 0.008, 0.70),  // secondary
            (0.66, 0.006, 0.45),  // tertiary, fading toward horizon
        ]
        for band in bands {
            NSColor(white: 1.0, alpha: band.alpha).setFill()
            let rect = NSRect(x: 0,
                              y: size.height * band.yFrac,
                              width: size.width,
                              height: size.height * band.heightFrac)
            rect.fill()
        }

        // 3) A subtle warm tint over the band region so the reflections
        //    pick up some color rather than pure white.
        NSColor(calibratedHue: 0.10, saturation: 0.55,
                brightness: 0.6, alpha: 0.25).setFill()
        NSRect(x: 0, y: size.height * 0.62,
               width: size.width, height: size.height * 0.32).fill()

        return img
    }

    private func setupLights() {
        // With IBL doing most of the work for the metallic cubes, we add
        // only a single subtle directional key — enough to bias shading so
        // the silhouettes don't read as flat. Ambient is intentionally
        // off; the env map's lower hemisphere fills that role.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 250
        key.light?.color = NSColor(calibratedHue: 0.09, saturation: 0.25,
                                   brightness: 1.0, alpha: 1.0)
        key.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(key)
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
