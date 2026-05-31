import AppKit
import SceneKit

/// A vertical totem of stacked cube rings — one host's CPU history rendered
/// as a 3D sculpture.
///
/// Layout:
/// - One ring per time slice. Newest sample sits at the top, oldest at the
///   bottom, so "scrolling" reads top-to-bottom as time advances.
/// - Each ring has 4-fold rotational symmetry: cube count is quantized into
///   `{4, 8, 12, 16, 20, 24}` based on CPU%. The radius scales with cube
///   count so the cubes stay roughly the same arc-distance apart — high CPU
///   "blooms" the ring outward.
/// - The whole totem slowly rotates on its vertical axis to keep the
///   silhouette interesting from any camera angle.
final class HostTotem {

    // MARK: - Tuning constants

    // Geometric scale halved (was 0.5 / 0.6 / 0.6) so totems read as dense
    // little towers instead of huge sparse cube stacks. Mass is unchanged
    // — the same CPU activity now packs into 1/8 the volume, which is the
    // "denser" feel the user asked for.
    static let cubeSize: CGFloat = 0.25
    static let ringSpacing: CGFloat = 0.3
    static let maxRings = 27
    /// Arc length we aim to keep between adjacent cubes in a ring. The radius
    /// is derived from this so dense rings widen instead of overlapping.
    static let arcSpacing: CGFloat = 0.3

    // MARK: - Public

    let hostID: String
    let rootNode = SCNNode()

    /// Per-frame motion state — drift velocity and current position.
    /// SculptureScene owns the integration; HostTotem just holds the value.
    var motion: MotionState

    // MARK: - Private

    private let stackNode = SCNNode()
    private let labelNode = SCNNode()
    /// Saturn-style outer ring of GPU activity blocks. Sibling of stackNode
    /// so it shares the slow vertical spin — the GPU history rotates with
    /// the CPU stack rather than reading as a separate fixed disc.
    private let saturnNode = SCNNode()
    private var baseColor: NSColor
    private var lastLabel: String?

    /// Saturn ring's radius — outside the widest cube ring (max ~1.15 at
    /// arcSpacing=0.3 and 24 cubes) with breathing room so it doesn't
    /// merge into the silhouette.
    private static let saturnRadius: CGFloat = 1.9

    init(hostID: String, color: NSColor, seed: Int = 0) {
        self.hostID = hostID
        self.baseColor = color
        // Position is zero here; SculptureScene overwrites it with a spawn
        // position right after construction, and `initialVelocity` derives
        // a tangent vector from that real position.
        // Collision radius is the widest possible ring's outer bound plus
        // a small visual buffer — sized to halved geometric scale.
        self.motion = MotionState(
            position: SCNVector3(0, 0, 0),
            velocity: SCNVector3(0, 0, 0),
            mass: 1.0,
            radius: 1.75
        )
        rootNode.addChildNode(stackNode)
        rootNode.addChildNode(labelNode)
        stackNode.addChildNode(saturnNode)

        // Slow rotation around the vertical axis. Lives on stackNode so the
        // (eventually drifting) rootNode position transform composes cleanly,
        // and so the Saturn ring spins together with the cube stack.
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = 45
        spin.repeatCount = .infinity
        stackNode.addAnimation(spin, forKey: "spin")
    }

    /// Update the host's visible label. Rebuilds the SCNText geometry only
    /// when the string actually changes — text mesh rebuild is the priciest
    /// operation in the totem.
    ///
    /// SCNText's font point-size doesn't map cleanly to scene units —
    /// `ofSize: 12` produces text that's several scene units tall. We keep
    /// the font at a size that renders cleanly (good glyph tessellation at
    /// flatness=0.4) and use the node's `scale` to control how big it
    /// actually appears in the scene.
    func setLabel(_ label: String) {
        guard label != lastLabel else { return }
        lastLabel = label
        labelNode.childNodes.forEach { $0.removeFromParentNode() }

        let text = SCNText(string: label, extrusionDepth: 0)
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        text.flatness = 0.4
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.white.withAlphaComponent(0.6)
        mat.lightingModel = .constant  // ignore scene lighting; pure white
        mat.isDoubleSided = true
        text.materials = [mat]

        let textNode = SCNNode(geometry: text)
        // Tweak this single constant if you want bigger/smaller labels.
        textNode.scale = SCNVector3(0.08, 0.08, 0.08)
        // Center the text on its own origin so it billboards cleanly.
        let (minB, maxB) = text.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (minB.x + maxB.x) / 2,
            (minB.y + maxB.y) / 2,
            (minB.z + maxB.z) / 2
        )
        // Float above the topmost ring of the totem.
        textNode.position = SCNVector3(0,
                                       Float(HostTotem.maxRings) * Float(HostTotem.ringSpacing) / 2 + 1.5,
                                       0)
        // Always face the camera regardless of totem rotation/drift.
        textNode.constraints = [SCNBillboardConstraint()]
        labelNode.addChildNode(textNode)
    }

    /// Rebuild the totem from a samples buffer. Cheap enough at totem scale
    /// (≤ ~960 cubes) and lets us avoid bookkeeping a ring pool while the
    /// layout/spacing rules are still settling. We may pool later if we ever
    /// see real cost.
    func update(samples: [CPUSample]) {
        // Recompute mass from recent CPU activity. The Motion engine reads
        // this every frame, so it picks up new values on the next render
        // tick without any explicit notification.
        motion.mass = Self.computeMass(from: samples)

        // Rebuild stack — but preserve saturnNode (and its blocks) since
        // it lives on stackNode as a sibling of the ring nodes. We'll
        // rebuild its contents separately below.
        stackNode.childNodes.forEach { node in
            if node !== self.saturnNode { node.removeFromParentNode() }
        }

        // Take the most recent maxRings samples. Index 0 in `recent` is the
        // oldest visible sample, last is newest — we render newest-on-top.
        let recent = Array(samples.suffix(Self.maxRings))
        let n = recent.count
        guard n > 0 else {
            rebuildSaturnRing(samples: [])
            return
        }

        // Center the stack vertically around y=0 so the camera frames it
        // without needing per-totem offset math.
        let totalHeight = CGFloat(Self.maxRings) * Self.ringSpacing
        let yBase = -totalHeight / 2

        for (i, sample) in recent.enumerated() {
            let cubeCount = quantizedCubeCount(forCPU: sample.cpu)
            // ageFraction: 0 = newest (top), 1 = oldest (bottom)
            let ageFraction = Double(n - 1 - i) / Double(max(Self.maxRings - 1, 1))
            let yOffset = yBase + CGFloat(i) * Self.ringSpacing
            let ringNode = makeRing(cubeCount: cubeCount,
                                    cpu: sample.cpu,
                                    yOffset: yOffset,
                                    ageFraction: ageFraction)
            stackNode.addChildNode(ringNode)
        }

        rebuildSaturnRing(samples: recent)
    }

    // MARK: - Internals

    /// Mass derived from recent CPU + GPU activity. Both contributions
    /// are cubic in their average over the most recent ~10 samples, so
    /// a small steady load reads light while sustained busy work reads
    /// very heavy. GPU coefficient is 3× the CPU coefficient — a fully
    /// utilized GPU is a serious gravitational presence, much more so
    /// than a busy CPU alone. Hosts with no GPU sensor get only the CPU
    /// contribution; their average isn't diluted by implicit zeros.
    ///
    /// Reference points (CPU%, GPU%):
    ///   ·   0,   0  →   1
    ///   ·  50, nil  →  10
    ///   · 100, nil  →  76
    ///   ·  50,  50  →  38
    ///   · 100, 100  → 301
    static func computeMass(from samples: [CPUSample]) -> Float {
        let recent = samples.suffix(10)
        guard !recent.isEmpty else { return 1.0 }

        // CPU contribution — always present.
        let cpuAvg = recent.map { max(0, min(100, $0.cpu)) }.reduce(0, +)
                     / Double(recent.count)
        let cpuTerm = 75.0 * pow(cpuAvg / 100.0, 3)

        // GPU contribution — only if at least one sample has a GPU reading.
        // We average just the non-nil values so a partial-GPU history
        // doesn't get diluted by samples taken before the host even
        // exposed a GPU sensor.
        let gpuValues = recent.compactMap { $0.gpu }
            .map { max(0, min(100, $0)) }
        let gpuTerm: Double
        if gpuValues.isEmpty {
            gpuTerm = 0
        } else {
            let gpuAvg = gpuValues.reduce(0, +) / Double(gpuValues.count)
            gpuTerm = 225.0 * pow(gpuAvg / 100.0, 3)
        }

        return Float(1.0 + cpuTerm + gpuTerm)
    }

    /// Quantize CPU% into one of six buckets so every ring has 4-fold rotational
    /// symmetry. 0% still draws a 4-cube ring — a totally idle host should
    /// still be visible as a thin spire.
    private func quantizedCubeCount(forCPU cpu: Double) -> Int {
        let clamped = max(0, min(100, cpu))
        // 6 buckets × 4 cubes: [0, 16.67) → 4, [16.67, 33.33) → 8, … → 24.
        let bucket = max(1, min(6, Int(ceil((clamped + 0.001) / 16.6667))))
        return bucket * 4
    }

    private func makeRing(cubeCount: Int, cpu: Double,
                          yOffset: CGFloat, ageFraction: Double) -> SCNNode {
        let ringNode = SCNNode()
        ringNode.position = SCNVector3(0, Float(yOffset), 0)

        // Solve for radius from desired arc-length between adjacent cubes.
        // Floor below cubeSize so a 4-cube ring is still wider than one cube.
        let radius = max(Self.cubeSize * 1.2,
                         Self.arcSpacing * CGFloat(cubeCount) / (2 * .pi))

        for i in 0..<cubeCount {
            let angle = 2 * Double.pi * Double(i) / Double(cubeCount)
            let x = radius * CGFloat(cos(angle))
            let z = radius * CGFloat(sin(angle))

            let cube = SCNNode(geometry: makeCubeGeometry(cpu: cpu, ageFraction: ageFraction))
            cube.position = SCNVector3(Float(x), 0, Float(z))
            // Orient cube so its face points outward — looks tidier than
            // axis-aligned cubes whose corners poke randomly toward the camera.
            cube.eulerAngles = SCNVector3(0, Float(-angle), 0)
            ringNode.addChildNode(cube)
        }

        return ringNode
    }

    /// Cube color is now driven by the CPU level (blue → yellow → red
    /// ramp matching the main-app monitor bars). Per-host identity is
    /// carried by a subtle baseColor emission tint so each totem still
    /// has a distinct cast in low-light areas, plus the floating label.
    private func makeCubeGeometry(cpu: Double, ageFraction: Double) -> SCNGeometry {
        let box = SCNBox(width: Self.cubeSize,
                         height: Self.cubeSize,
                         length: Self.cubeSize,
                         chamferRadius: Self.cubeSize * 0.14)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased

        // Diffuse: blue/yellow/red by CPU level, dimmed by age.
        let levelColor = Self.levelColor(forPct: cpu)
        let brightness = 1.0 - 0.45 * ageFraction
        material.diffuse.contents = levelColor.withBrightnessMultiplied(by: CGFloat(brightness))
        // Emission: per-host tint, very dim. Visible mostly in the shaded
        // sides of cubes — gives each machine a faint signature color
        // without overwhelming the CPU-level reading.
        material.emission.contents = baseColor.withBrightnessMultiplied(by: 0.12)

        // High metalness + low roughness = polished colored surface. Older
        // rings (deeper in the stack) get progressively rougher, so they
        // catch less environment light. Reads as "the past was duller".
        material.metalness.contents = NSNumber(value: 0.85)
        material.roughness.contents = NSNumber(value: 0.18 + 0.35 * ageFraction)
        material.isDoubleSided = false

        box.materials = [material]
        return box
    }

    // MARK: - Color ramp

    /// Blue / yellow / red ramp matching `monitorCPUBarColor` in the main
    /// app. Discrete bands (not interpolated) so the visual language is
    /// the same as the in-app monitor bars at a glance.
    ///   <= 40%  → blue
    ///   <= 80%  → yellow
    ///   >  80%  → red
    static func levelColor(forPct pct: Double) -> NSColor {
        let v = max(0, min(100, pct))
        if v > 80 { return NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1) }
        if v > 40 { return NSColor(srgbRed: 1.00, green: 0.82, blue: 0.42, alpha: 1) }
        return NSColor(srgbRed: 0.40, green: 0.80, blue: 1.00, alpha: 1)
    }

    // MARK: - Saturn GPU ring

    /// Build the outer Saturn-style ring showing recent GPU activity.
    /// Each non-zero GPU sample becomes a small angular block; empty
    /// samples are simply omitted so the ring's fill pattern reads as
    /// "when did the GPU run?". Hides itself if the host has no GPU
    /// data at all (all samples nil/zero).
    private func rebuildSaturnRing(samples: [CPUSample]) {
        saturnNode.childNodes.forEach { $0.removeFromParentNode() }

        let recent = Array(samples.suffix(Self.maxRings))
        guard !recent.isEmpty else { return }
        // If no samples carry a meaningful GPU reading, skip the ring
        // entirely — a host without a GPU should not grow a halo.
        let hasGPU = recent.contains { ($0.gpu ?? 0) > 0.5 }
        guard hasGPU else { return }

        let blockW = Self.cubeSize * 0.9   // radial thickness
        let blockH = Self.cubeSize * 1.4   // taller than CPU cubes — distinguishable
        let blockL = Self.cubeSize * 0.9   // tangent span
        let radius = Self.saturnRadius

        for (i, sample) in recent.enumerated() {
            guard let gpu = sample.gpu, gpu > 0.5 else { continue }
            // Newest sample at angle 0 (front of totem); older samples
            // sweep counter-clockwise around. Same direction as the
            // totem's spin so the freshest sample is briefly in front.
            let angle = 2 * Double.pi * Double(recent.count - 1 - i)
                        / Double(Self.maxRings)
            let x = radius * CGFloat(cos(angle))
            let z = radius * CGFloat(sin(angle))

            let box = SCNBox(width: blockW, height: blockH, length: blockL,
                             chamferRadius: blockW * 0.18)
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            let tint = Self.levelColor(forPct: gpu)
            mat.diffuse.contents = tint
            // Brighter emission than CPU cubes so the GPU ring reads as
            // its own visual layer rather than blending into the totem.
            mat.emission.contents = tint.withBrightnessMultiplied(by: 0.35)
            mat.metalness.contents = NSNumber(value: 0.6)
            mat.roughness.contents = NSNumber(value: 0.25)
            box.materials = [mat]

            let node = SCNNode(geometry: box)
            node.position = SCNVector3(Float(x), 0, Float(z))
            // Rotate so blockL is tangent to the ring (block "faces" outward).
            node.eulerAngles = SCNVector3(0, Float(-angle), 0)
            saturnNode.addChildNode(node)
        }
    }
}
