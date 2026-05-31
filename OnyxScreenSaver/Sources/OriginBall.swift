import AppKit
import SceneKit

/// The Timing.app ball — a single sphere near origin whose size and mass
/// scale with the number of hours worked this week.
///
/// Sizing convention (the user's spec, with calibration constants):
///   radius ∝ hours  — visually, "the more hours, the bigger the ball"
///   mass   ∝ hours³ — gravitationally, "the more hours, the more the
///                     ball dominates the scene"
///
/// The cubic mass scaling means the gravity well grows much faster than
/// the visual footprint: a slow-week 10h ball is mostly cosmetic, a
/// near-target 35h ball is a major attractor, a crunch-week 50h+ ball
/// drags everything into its orbit.
final class OriginBall {

    let rootNode = SCNNode()

    /// Motion state — the scene merges this into its `Motion.advance`
    /// pass so the ball participates in gravity and collisions like any
    /// other body. Its high mass keeps it nearly stationary.
    var motion: MotionState

    /// Calibration: at this hours threshold, the ball is meant to be
    /// "a major gravity well". Used to compute the actual r/m scale
    /// factors so the rest of the code reads cleanly in physical units.
    static let calibrationHours: Float = 35

    /// At calibration hours, the ball's radius is this many scene units.
    /// Picked so the ball fits comfortably inside the bounds (radius 30)
    /// without overwhelming the totems (~3.5u radius each).
    static let calibrationRadius: Float = 7

    /// At calibration hours, the ball's mass is this many "totem masses".
    /// A typical totem is mass 1-6; calibrationMass = 857 means the ball
    /// dominates pairwise gravity by 100×-800×.
    static let calibrationMass: Float = 857

    private let sphere: SCNSphere

    init() {
        sphere = SCNSphere(radius: 0.5)
        sphere.segmentCount = 48  // smooth-enough silhouette

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        // A soft warm "ember" — implies the energy of accumulated work
        // hours. The metalness/roughness balance leans slightly less
        // mirror-like than the totems so the ball reads as a different
        // material class, not just a giant cube.
        mat.diffuse.contents = NSColor(calibratedHue: 0.05,
                                       saturation: 0.65,
                                       brightness: 1.0,
                                       alpha: 1.0)
        mat.metalness.contents = NSNumber(value: 0.55)
        mat.roughness.contents = NSNumber(value: 0.35)
        // Subtle self-emission so even when the env map is dim, the ball
        // still glows from within.
        mat.emission.contents = NSColor(calibratedHue: 0.05,
                                        saturation: 0.5,
                                        brightness: 0.15,
                                        alpha: 1.0)
        sphere.materials = [mat]

        let node = SCNNode(geometry: sphere)
        rootNode.addChildNode(node)
        // Slow spin so highlights drift across the surface — gives the
        // ball some life even when nothing's colliding with it.
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = 60
        spin.repeatCount = .infinity
        node.addAnimation(spin, forKey: "spin")

        // Start at origin, stationary, with placeholder mass/radius
        // (overwritten by setHours before first render).
        motion = MotionState(
            position: SCNVector3(0, 0, 0),
            velocity: SCNVector3(0, 0, 0),
            mass: 0.1,
            radius: 0.5
        )
    }

    /// Update size + mass from the latest "hours worked this week" figure.
    /// Pass nil (or 0) to hide the ball — it shrinks to invisible and
    /// drops to negligible mass so it has no gravitational effect.
    func setHours(_ hours: Double?) {
        let h = Float(hours ?? 0)
        guard h > 0.1 else {
            rootNode.isHidden = true
            motion.mass = 0.1
            motion.radius = 0.1
            return
        }
        rootNode.isHidden = false

        // Calibrated linear radius. radius ∝ hours, with the constant set
        // by calibrationRadius at calibrationHours.
        let radius = Self.calibrationRadius * (h / Self.calibrationHours)

        // Calibrated cubic mass. mass ∝ hours³, with the constant set by
        // calibrationMass at calibrationHours.
        let massRatio = h / Self.calibrationHours
        let mass = Self.calibrationMass * massRatio * massRatio * massRatio

        sphere.radius = CGFloat(radius)
        motion.radius = radius
        motion.mass = mass
    }
}
