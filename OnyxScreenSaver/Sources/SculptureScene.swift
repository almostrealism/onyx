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
/// How the Timing.app data is visualized as gravitational bodies.
///
/// - `.perProject` (default): one ball per project, each colored by that
///   project's Timing color, each sized/massed by its individual hours,
///   spread out around origin in random positions. The result is a
///   multi-pole gravity field — totems get pulled by different wells,
///   never settle into a single boring orbit.
/// - `.unified` (legacy fallback): one ball at origin, color blended
///   from all projects weighted by hours, sized/massed by total hours.
///   Preserved as a fallback in case the per-project dynamics turn out
///   to misbehave in some edge case.
enum BallMode {
    case perProject
    case unified
}

final class SculptureScene: NSObject, SCNSceneRendererDelegate {

    /// Flip to `.unified` to restore the previous single-blended-ball
    /// behavior. Kept as a compile-time switch so the alternative
    /// configuration remains immediately runnable without code reverts.
    static let ballMode: BallMode = .perProject

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private var totems: [String: HostTotem] = [:]
    /// Project-key → ball. In unified mode the key is the sentinel
    /// `"_unified"`; in per-project mode it's the project title.
    private var balls: [String: OriginBall] = [:]
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

        // Balls (one in unified mode, N in per-project mode) get created
        // by syncBalls when a stream snapshot arrives. Until then, no
        // balls in the scene — the totems fly freely.

        // Live reader runs everywhere — the System Settings preview also
        // benefits if Onyx is running and broadcasting real data.
        reader.onUpdate = { [weak self] hosts, weeklyHours, weeklyProjects in
            self?.handleLiveUpdate(hosts: hosts,
                                   weeklyHours: weeklyHours,
                                   weeklyProjects: weeklyProjects)
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

    private func handleLiveUpdate(hosts: [HostStream],
                                   weeklyHours: Double?,
                                   weeklyProjects: [ProjectShare]?) {
        // Timing balls are independent of host data — sync them every
        // update so they appear/grow/shrink as hours change, even during
        // gaps in CPU samples.
        syncBalls(weeklyHours: weeklyHours, weeklyProjects: weeklyProjects)

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
        syncBalls(weeklyHours: nil, weeklyProjects: nil)
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
            totems[stream.hostID]?.syncContainers(stream.containers ?? [])
        }
    }

    // MARK: - Ball management

    /// Reconcile the `balls` dict against the latest stream snapshot.
    /// In `.perProject` mode this adds one ball per project (at a stable-
    /// for-the-session random position), removes balls for projects that
    /// vanished, and updates size/tint/mass for the survivors. In
    /// `.unified` mode it just maintains a single ball at origin.
    private func syncBalls(weeklyHours: Double?, weeklyProjects: [ProjectShare]?) {
        switch Self.ballMode {
        case .unified:
            // Strip any per-project balls that might exist from a mode
            // flip (shouldn't happen at runtime, but be defensive).
            for (key, ball) in balls where key != "_unified" {
                ball.rootNode.removeFromParentNode()
                balls.removeValue(forKey: key)
            }
            let ball = balls["_unified"] ?? {
                let b = OriginBall(position: SCNVector3(0, 0, 0))
                balls["_unified"] = b
                scene.rootNode.addChildNode(b.rootNode)
                return b
            }()
            ball.setHours(weeklyHours)
            ball.setProjects(weeklyProjects)

        case .perProject:
            let projects = weeklyProjects ?? []
            let incomingKeys = Set(projects.map(\.title))

            // Drop the unified-mode sentinel and any project balls that
            // disappeared since the last snapshot.
            for (key, ball) in balls where key == "_unified" || !incomingKeys.contains(key) {
                ball.rootNode.removeFromParentNode()
                balls.removeValue(forKey: key)
            }

            for project in projects {
                let ball = balls[project.title] ?? {
                    let b = OriginBall(position: nextProjectBallPosition())
                    balls[project.title] = b
                    scene.rootNode.addChildNode(b.rootNode)
                    return b
                }()
                ball.setHours(project.hours > 0.1 ? project.hours : nil)
                if let tint = NSColor.fromOnyxHex(project.color) {
                    ball.setTint(tint)
                }
            }
        }
    }

    /// Spread the per-project balls around origin on a random shell so
    /// the gravity field has multiple poles, with generous separation
    /// between them. Per-project balls are visually smaller than busy
    /// totems (radius ∝ project-hours, and most projects don't run 35h),
    /// so tight clustering leaves no visual breathing room — totems
    /// just weave through a dense knot. Spreading them across most of
    /// the visible region gives the eye real empty space between wells.
    private func nextProjectBallPosition() -> SCNVector3 {
        // Try with the generous minimum separation first.
        if let p = tryPlaceBall(radiusRange: 16...24, minSeparation: 16) { return p }
        // Tight week with many projects — relax separation a bit.
        if let p = tryPlaceBall(radiusRange: 14...26, minSeparation: 12) { return p }
        // Absolute fallback — accept anything in the wider band so we
        // don't pile on top of existing balls at origin.
        if let p = tryPlaceBall(radiusRange: 12...28, minSeparation: 8) { return p }
        // Truly desperate (many balls or pathological randomness).
        let theta = Float.random(in: 0...(2 * .pi))
        return SCNVector3(18 * cos(theta), 0, 18 * sin(theta))
    }

    private func tryPlaceBall(radiusRange: ClosedRange<Float>,
                              minSeparation: Float) -> SCNVector3? {
        for _ in 0..<40 {
            let theta = Float.random(in: 0...(2 * .pi))
            let phi = Float.random(in: -(.pi / 3.5)...(.pi / 3.5))
            let radius = Float.random(in: radiusRange)
            let candidate = SCNVector3(
                radius * cos(phi) * cos(theta),
                radius * sin(phi),
                radius * cos(phi) * sin(theta)
            )
            let tooClose = balls.values.contains { existing in
                Motion.length(Motion.sub(existing.motion.position, candidate)) < minSeparation
            }
            if !tooClose { return candidate }
        }
        return nil
    }

    /// Initial position on a random point of a shell around origin —
    /// distinct every launch so the screensaver never opens with the
    /// same staging twice. We sample on a partial hemisphere (not full
    /// sphere) so totems don't spawn directly behind the camera, then
    /// jitter the radius too.
    private func spawnPosition(for index: Int) -> SCNVector3 {
        let theta = Float.random(in: 0...(2 * .pi))          // azimuth
        let phi = Float.random(in: -(.pi / 3.5)...(.pi / 3)) // elevation, biased slightly up
        // Spawn outside the project-ball shell (16-24) so totems start
        // beyond the gravity cluster and fall inward, rather than
        // appearing already-collided.
        let radius = Float.random(in: 24...32)
        return SCNVector3(
            radius * cos(phi) * cos(theta),
            radius * sin(phi),
            radius * cos(phi) * sin(theta)
        )
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
        // Every visible ball joins the array so totems exchange gravity
        // and collisions with each well like any other body.
        let totemIDs = totems.keys.sorted()  // stable order for reproducible math
        var states = totemIDs.map { totems[$0]!.motion }
        let activeBalls = balls.values.filter { !$0.rootNode.isHidden }
        for ball in activeBalls { states.append(ball.motion) }

        Motion.advance(&states, dt: dt)

        for (i, id) in totemIDs.enumerated() {
            guard let totem = totems[id] else { continue }
            totem.motion = states[i]
            totem.rootNode.position = states[i].position
            // Container moons orbit on a kinematic path — independent
            // of the gravity sim, just driven by wall-clock time.
            // Moons are children of rootNode so they inherit the
            // totem's world position automatically.
            totem.updateMoonPositions(time: time)
        }
        // Anchored balls don't actually move, but read-back keeps the
        // MotionState in sync in case the engine ever stops anchoring them.
        for (i, ball) in activeBalls.enumerated() {
            ball.motion = states[totemIDs.count + i]
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
