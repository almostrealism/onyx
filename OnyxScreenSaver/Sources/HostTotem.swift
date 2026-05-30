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

    static let cubeSize: CGFloat = 0.5
    static let ringSpacing: CGFloat = 0.6
    static let maxRings = 40
    /// Arc length we aim to keep between adjacent cubes in a ring. The radius
    /// is derived from this so dense rings widen instead of overlapping.
    static let arcSpacing: CGFloat = 0.6

    // MARK: - Public

    let hostID: String
    let rootNode = SCNNode()

    // MARK: - Private

    private let stackNode = SCNNode()
    private var baseColor: NSColor

    init(hostID: String, color: NSColor) {
        self.hostID = hostID
        self.baseColor = color
        rootNode.addChildNode(stackNode)

        // Slow rotation around the vertical axis. Lives on stackNode so the
        // (eventually drifting) rootNode position transform composes cleanly.
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = 45
        spin.repeatCount = .infinity
        stackNode.addAnimation(spin, forKey: "spin")
    }

    /// Rebuild the totem from a samples buffer. Cheap enough at totem scale
    /// (≤ ~960 cubes) and lets us avoid bookkeeping a ring pool while the
    /// layout/spacing rules are still settling. We may pool later if we ever
    /// see real cost.
    func update(samples: [CPUSample]) {
        stackNode.childNodes.forEach { $0.removeFromParentNode() }

        // Take the most recent maxRings samples. Index 0 in `recent` is the
        // oldest visible sample, last is newest — we render newest-on-top.
        let recent = Array(samples.suffix(Self.maxRings))
        let n = recent.count
        guard n > 0 else { return }

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
                                    yOffset: yOffset,
                                    ageFraction: ageFraction)
            stackNode.addChildNode(ringNode)
        }
    }

    // MARK: - Internals

    /// Quantize CPU% into one of six buckets so every ring has 4-fold rotational
    /// symmetry. 0% still draws a 4-cube ring — a totally idle host should
    /// still be visible as a thin spire.
    private func quantizedCubeCount(forCPU cpu: Double) -> Int {
        let clamped = max(0, min(100, cpu))
        // 6 buckets × 4 cubes: [0, 16.67) → 4, [16.67, 33.33) → 8, … → 24.
        let bucket = max(1, min(6, Int(ceil((clamped + 0.001) / 16.6667))))
        return bucket * 4
    }

    private func makeRing(cubeCount: Int, yOffset: CGFloat, ageFraction: Double) -> SCNNode {
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

            let cube = SCNNode(geometry: makeCubeGeometry(ageFraction: ageFraction))
            cube.position = SCNVector3(Float(x), 0, Float(z))
            // Orient cube so its face points outward — looks tidier than
            // axis-aligned cubes whose corners poke randomly toward the camera.
            cube.eulerAngles = SCNVector3(0, Float(-angle), 0)
            ringNode.addChildNode(cube)
        }

        return ringNode
    }

    private func makeCubeGeometry(ageFraction: Double) -> SCNGeometry {
        let box = SCNBox(width: Self.cubeSize,
                         height: Self.cubeSize,
                         length: Self.cubeSize,
                         chamferRadius: Self.cubeSize * 0.08)
        let material = SCNMaterial()
        // Fade from full saturation (newest) down to ~0.4 (oldest).
        let brightness = 1.0 - 0.6 * ageFraction
        material.diffuse.contents = baseColor.withBrightnessMultiplied(by: CGFloat(brightness))
        material.specular.contents = NSColor.white
        material.lightingModel = .blinn
        box.materials = [material]
        return box
    }
}
