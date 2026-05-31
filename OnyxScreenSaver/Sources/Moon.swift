import AppKit
import SceneKit

/// A small sphere orbiting one totem on a fixed elliptical path. One moon
/// per docker container on the host. The orbit is purely kinematic — no
/// gravity calculation, no collisions — so moons don't perturb the totem
/// dynamics in any way. The motion engine doesn't see them.
///
/// Orbit parameters (semi-major axis, eccentricity, inclination,
/// ascending-node longitude, period, phase offset) are derived
/// deterministically from a hash of the container name + a host seed,
/// so the same container always orbits the same way within a session and
/// stays distinguishable from sibling containers.
///
/// Color is the only thing that changes at runtime — driven by the
/// container's current CPU%, using the same blue→yellow→red ramp as
/// the totem cubes and the in-app monitor bars.
final class Moon {

    /// Visual size — fixed across containers. Color is the dynamic
    /// channel; container name and CPU are the per-moon signal. Sized
    /// to clearly read as a separate visual element from the GPU
    /// Saturn ring's much smaller blocks.
    static let moonRadius: CGFloat = 0.35

    let containerName: String
    let rootNode = SCNNode()

    private let sphere: SCNSphere
    private let material: SCNMaterial

    // MARK: - Orbital parameters (all immutable for a given moon)
    let semiMajor: Float        // a — orbit size in scene units
    let eccentricity: Float     // e — 0 = circle, 1 = parabolic
    let inclination: Float      // i — tilt of orbital plane from totem's XZ
    let ascendingNode: Float    // Ω — rotation of plane about Y axis
    let period: Float           // T — seconds per full orbit
    let phaseOffset: Float      // mean-anomaly offset at t=0

    init(containerName: String, hostSeed: Int) {
        self.containerName = containerName

        sphere = SCNSphere(radius: Self.moonRadius)
        sphere.segmentCount = 20

        material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.metalness.contents = NSNumber(value: 0.5)
        material.roughness.contents = NSNumber(value: 0.3)
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        rootNode.addChildNode(node)

        // Deterministic per-container orbit. Mix container hash with
        // host seed using a SplitMix64-style hash so two hosts with the
        // same container name still get different orbits.
        var h = UInt64(bitPattern: Int64(containerName.hashValue))
                ^ UInt64(bitPattern: Int64(hostSeed))
        h &+= 0x9E3779B97F4A7C15  // golden ratio in 2⁶⁴
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        h =  h ^ (h >> 31)
        let r0 = Float((h >>  0) & 0xff) / 255.0
        let r1 = Float((h >>  8) & 0xff) / 255.0
        let r2 = Float((h >> 16) & 0xff) / 255.0
        let r3 = Float((h >> 24) & 0xff) / 255.0
        let r4 = Float((h >> 32) & 0xff) / 255.0
        let r5 = Float((h >> 40) & 0xff) / 255.0

        // Orbit sizes are picked so moons clear the totem silhouette
        // (≈ 1.15u max) and the GPU Saturn ring (1.9u outer) with a
        // generous gap. Semi-major axis 3.5–6.0 means perihelion stays
        // > 2u from the totem center even at e=0.4.
        semiMajor = 3.5 + r0 * 2.5
        eccentricity = 0.05 + r1 * 0.35
        // Inclination is locked at π/2: every orbital plane contains the
        // totem's vertical axis (a "polar" orbit). This makes moons read
        // as distinct from the horizontal GPU Saturn ring — they always
        // sweep top-to-bottom rather than going around the equator like
        // the Saturn blocks do. Variety comes from ascendingNode, which
        // rotates each orbital plane around the vertical axis so
        // different containers orbit on different meridians.
        inclination = .pi / 2
        // We still keep r2 in the hash mix — it influences `ascendingNode`
        // below — so the seed entropy isn't wasted.
        ascendingNode = (r3 + r2 * 0.5).truncatingRemainder(dividingBy: 1) * 2 * .pi
        // Period: 10–24s. Slow enough to read without feeling sluggish.
        period = 10 + r4 * 14
        phaseOffset = r5 * 2 * .pi
    }

    /// Recompute the moon's local position based on absolute scene time.
    /// Called once per render frame by SculptureScene.
    func updatePosition(time: TimeInterval) {
        // Uniform angular motion in the eccentric-anomaly sense (NOT
        // strict Kepler — the moon moves at a constant rate around the
        // ellipse, which trades real-world fidelity for a steadier
        // visual cadence). Adequate for a screensaver.
        let E = Float(time) * (2 * .pi / period) + phaseOffset

        // Position in the orbital plane (sun at origin = totem center).
        // x along the major axis; semi-minor axis b = a√(1 - e²).
        let a = semiMajor
        let b = a * sqrt(max(0, 1 - eccentricity * eccentricity))
        let xLocal = a * cos(E)
        let zLocal = b * sin(E)
        let yLocal: Float = 0

        // Rotate by inclination around X axis: lifts the orbit plane.
        let cosI = cos(inclination), sinI = sin(inclination)
        let y1 = yLocal * cosI - zLocal * sinI
        let z1 = yLocal * sinI + zLocal * cosI
        let x1 = xLocal

        // Rotate by ascending-node longitude around Y: spins the plane
        // around the vertical so adjacent moons don't all share the
        // same orbital "lane".
        let cosN = cos(ascendingNode), sinN = sin(ascendingNode)
        let x = x1 * cosN - z1 * sinN
        let z = x1 * sinN + z1 * cosN

        rootNode.position = SCNVector3(x, y1, z)
    }

    /// Set the moon's color from the container's CPU%. Same level ramp
    /// as the totem cube rings — blue/yellow/red bands.
    func setCPU(_ cpu: Double) {
        let tint = HostTotem.levelColor(forPct: cpu)
        material.diffuse.contents = tint
        // Brighter emission than the totem cubes — moons should pop as
        // colored dots even when the env map lights them dimly.
        material.emission.contents = tint.withBrightnessMultiplied(by: 0.45)
    }
}
