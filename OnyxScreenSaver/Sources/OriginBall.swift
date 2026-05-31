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
    /// Anchored, so this only affects the gravity field. 600 was strong
    /// enough that totems couldn't get far between collisions — they
    /// kept restaging into the well. 420 keeps the ball clearly
    /// dominant against cubic-scaled totems (≈10× the heaviest at peak)
    /// while leaving room for a struck totem to actually travel before
    /// gravity catches it.
    static let calibrationMass: Float = 420

    private let sphere: SCNSphere
    private let material: SCNMaterial
    /// The default warm "ember" used when no project breakdown is available
    /// (Timing not configured, week with zero hours, etc.).
    private static let defaultTint = NSColor(calibratedHue: 0.05,
                                             saturation: 0.65,
                                             brightness: 1.0,
                                             alpha: 1.0)

    init() {
        sphere = SCNSphere(radius: 0.5)
        sphere.segmentCount = 48  // smooth-enough silhouette

        material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // Default tint until setProjects fills in the real value. The
        // metalness/roughness balance leans slightly less mirror-like
        // than the totems so the ball reads as a different material
        // class, not just a giant cube.
        material.diffuse.contents = Self.defaultTint
        material.metalness.contents = NSNumber(value: 0.55)
        material.roughness.contents = NSNumber(value: 0.35)
        // Subtle self-emission so even when the env map is dim, the ball
        // still glows from within. Recomputed from the diffuse tint
        // whenever the project palette changes.
        material.emission.contents = Self.emissionFor(Self.defaultTint)
        sphere.materials = [material]

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

        // Start at origin, stationary, anchored. The isAnchor flag tells
        // the motion engine "never move this body" — gravity and collisions
        // still compute correctly because they read the ball's mass for
        // the *other* body's response, but no force ever writes back to
        // the ball's own velocity/position.
        motion = MotionState(
            position: SCNVector3(0, 0, 0),
            velocity: SCNVector3(0, 0, 0),
            mass: 0.1,
            radius: 0.5,
            isAnchor: true
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

    /// Set the ball's tint from the per-project hours breakdown. We blend
    /// the projects' hex colors weighted by their hours, then re-saturate
    /// the result so a mix of distinct colors doesn't muddy into gray.
    /// Nil or empty input falls back to the default warm tint.
    func setProjects(_ projects: [ProjectShare]?) {
        let tint: NSColor
        if let projects = projects, !projects.isEmpty {
            tint = Self.blend(projects)
        } else {
            tint = Self.defaultTint
        }
        material.diffuse.contents = tint
        material.emission.contents = Self.emissionFor(tint)
    }

    /// Weighted RGB blend of the projects' colors, then a saturation/
    /// brightness boost so a diverse week doesn't end up dishwater gray.
    /// Falls back to the default tint if the inputs sum to zero hours.
    private static func blend(_ projects: [ProjectShare]) -> NSColor {
        let total = projects.reduce(0.0) { $0 + max(0, $1.hours) }
        guard total > 0 else { return defaultTint }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        for p in projects {
            guard let c = NSColor.fromOnyxHex(p.color)?
                            .usingColorSpace(.sRGB) else { continue }
            let w = CGFloat(max(0, p.hours) / total)
            r += c.redComponent * w
            g += c.greenComponent * w
            b += c.blueComponent * w
        }

        // Re-saturate. Naïve RGB averages of distinct hues tend toward
        // gray; pushing the result up in HSB space brings the dominant
        // hue back. The minimum brightness floor keeps a low-hours
        // gray-ish blend from looking dead.
        let mixed = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            .usingColorSpace(.deviceRGB) ?? defaultTint
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 1
        mixed.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let satBoosted = min(1.0, max(0.55, s * 1.6))
        let valBoosted = min(1.0, max(0.75, v * 1.15))
        return NSColor(calibratedHue: h, saturation: satBoosted,
                       brightness: valBoosted, alpha: 1)
    }

    /// Derive a dim version of the tint for the emission channel — gives
    /// the ball a subtle internal glow even when the environment is dim.
    private static func emissionFor(_ tint: NSColor) -> NSColor {
        guard let rgb = tint.usingColorSpace(.deviceRGB) else { return tint }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 1
        rgb.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(calibratedHue: h,
                       saturation: max(0.4, s * 0.8),
                       brightness: 0.15,
                       alpha: 1)
    }
}
