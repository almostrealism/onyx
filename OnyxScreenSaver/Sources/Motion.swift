import SceneKit

/// Per-object motion state. Mass + radius + position + velocity.
/// `radius` is used for collision detection. `mass` controls how much
/// each force changes the velocity (a = F / m).
struct MotionState {
    var position: SCNVector3
    var velocity: SCNVector3
    /// Mass derived from activity. Heavier objects feel less of each
    /// impulse and pull harder on others gravitationally.
    var mass: Float = 1.0
    /// Collision radius. Two objects are in contact when their center
    /// distance is less than `r_i + r_j`.
    var radius: Float = 3.5
}

/// Pure-math motion engine. Each frame:
///
/// 1. **Long-range gravity** — every pair attracts via `G·m₁·m₂/r²`, divided
///    by mass so heavy objects are sluggish. Heavy hosts (or the Timing
///    ball) become anchor points; light hosts orbit them.
/// 2. **Short-range elastic collision** — when two objects' surfaces meet
///    (center distance < sum of radii) AND they're approaching, apply a
///    one-shot impulse derived from the standard elastic-collision
///    formula. A super-elastic coefficient of restitution (>1) makes the
///    bounce energetic — light objects ricochet dramatically off heavy
///    ones because the impulse divides by mass.
/// 3. **Penetration resolution** — even with the impulse, fast bodies can
///    overlap in a single dt. We push them back apart along the contact
///    normal, weighted by mass (lighter object moves more).
/// 4. **Bounds containment** — soft spring back to origin past the bounds
///    radius, so totems can't escape the camera frustum.
/// 5. **Damp, cap, integrate** — small velocity bleed, a hard top-speed
///    cap, then position += velocity * dt.
enum Motion {

    /// Outer bound — softly pushed back toward origin if a totem strays
    /// beyond this radius. Keeps the action centered in frame.
    static let boundsRadius: Float = 30

    /// Pairwise gravitational constant. Tuned so a pair of average-mass
    /// totems at typical separation accelerates visibly but not violently.
    static let gravityG: Float = 35

    /// Distance floor for the gravity 1/r² term. Without it the force
    /// blows up as objects approach; clamping means short-range collision
    /// dominates close-in.
    static let gravityMinDist: Float = 3

    /// Coefficient of restitution for collisions. 1.0 = perfectly elastic
    /// (no energy lost). >1 = super-elastic (the pair gains energy from
    /// each bounce). We want the system to look LIVELY, so we go above 1
    /// — combined with damping, the long-run energy stays bounded.
    static let restitution: Float = 1.4

    /// Per-frame velocity damping. With elastic impulses adding energy
    /// per collision, we damp slightly more than before to keep the
    /// long-run velocity from blowing up. 0.995^60 ≈ 0.74 — still gentle.
    static let damping: Float = 0.995

    /// Top speed (units/sec). Caps any one object's velocity so a sequence
    /// of bounces can't snowball into something that reads as frantic.
    static let maxSpeed: Float = 9.0

    /// Initial velocity: mostly tangent to the spawn position, so totems
    /// start on orbital-ish arcs rather than barreling straight in.
    static func initialVelocity(position: SCNVector3, seed: Int) -> SCNVector3 {
        let theta = atan2(Float(position.z), Float(position.x))
        let tangentSpeed: Float = 2.0
        let yJitter = sin(Float(seed) * 1.6180339) * 0.5
        return SCNVector3(-tangentSpeed * sin(theta),
                          yJitter,
                          tangentSpeed * cos(theta))
    }

    /// Advance the system by `dt` seconds. Mutates each MotionState in place.
    static func advance(_ states: inout [MotionState], dt: Float) {
        let dt = min(dt, 1.0 / 15.0)  // clamp huge dt (e.g. tab-out resume)
        guard !states.isEmpty else { return }

        // 1) Pairwise gravity (long-range, continuous) and elastic
        //    collision (short-range, impulsive). Doing them in the same
        //    pass means we can reuse the per-pair distance/normal compute.
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                let delta = sub(states[j].position, states[i].position)
                let dist = length(delta)
                guard dist > 0.0001 else { continue }
                let unit = scale(delta, by: 1.0 / dist)
                let mi = states[i].mass
                let mj = states[j].mass
                let ri = states[i].radius
                let rj = states[j].radius
                let contactDist = ri + rj

                // --- Gravity (attractive, divided by mass = F/m) ---
                let effDist = max(dist, gravityMinDist)
                let fGrav = gravityG * mi * mj / (effDist * effDist)
                states[i].velocity = add(states[i].velocity,
                                         scale(unit, by:  fGrav * dt / mi))
                states[j].velocity = add(states[j].velocity,
                                         scale(unit, by: -fGrav * dt / mj))

                // --- Elastic collision (only on approach) ---
                if dist < contactDist {
                    let relVel = sub(states[j].velocity, states[i].velocity)
                    let vRelN = dot(relVel, unit)  // negative when approaching
                    if vRelN < 0 {
                        // J = -(1 + e) * v_rel·n / (1/m_i + 1/m_j)
                        // Equivalent compact form: μ = m_i·m_j / (m_i + m_j)
                        let mu = (mi * mj) / (mi + mj)
                        let jMag = -(1 + restitution) * vRelN * mu
                        // Δv_j = +J*n / m_j, Δv_i = -J*n / m_i. Lighter
                        // mass → larger velocity change → dramatic bounce.
                        states[j].velocity = add(states[j].velocity,
                                                 scale(unit, by:  jMag / mj))
                        states[i].velocity = sub(states[i].velocity,
                                                 scale(unit, by:  jMag / mi))
                    }

                    // --- Penetration resolution (positional) ---
                    // Even with the right impulse, in one dt a fast pair
                    // can pass through the contact distance. Push them
                    // apart along the normal so the next frame starts
                    // from a separating configuration. Mass-weighted so
                    // the lighter object moves more.
                    let penetration = contactDist - dist
                    let totalMass = mi + mj
                    let shiftI = penetration * (mj / totalMass)
                    let shiftJ = penetration * (mi / totalMass)
                    states[i].position = sub(states[i].position,
                                             scale(unit, by: shiftI))
                    states[j].position = add(states[j].position,
                                             scale(unit, by: shiftJ))
                }
            }
        }

        // 2) Soft sphere containment. Outside the bounds, accelerate
        //    toward origin proportionally to how far out we've drifted.
        //    Divided by mass so light totems get pulled back faster than
        //    a massive central ball that wandered slightly off-center.
        for i in 0..<states.count {
            let p = states[i].position
            let r = length(p)
            if r > boundsRadius {
                let excess = r - boundsRadius
                let unit = scale(p, by: 1.0 / max(r, 0.0001))
                let pullForce: Float = 14.0 * excess
                states[i].velocity = sub(states[i].velocity,
                                         scale(unit, by: pullForce * dt / states[i].mass))
            }
        }

        // 3) Damp, cap, integrate.
        for i in 0..<states.count {
            states[i].velocity = scale(states[i].velocity, by: damping)
            let speed = length(states[i].velocity)
            if speed > maxSpeed {
                states[i].velocity = scale(states[i].velocity, by: maxSpeed / speed)
            }
            states[i].position = add(states[i].position,
                                     scale(states[i].velocity, by: dt))
        }
    }

    // MARK: - SCNVector3 helpers
    // SCNVector3 components are CGFloat on macOS; we work in Float everywhere
    // and convert at the boundary so the math stays clean.

    static func add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        let ax = Float(a.x), ay = Float(a.y), az = Float(a.z)
        let bx = Float(b.x), by = Float(b.y), bz = Float(b.z)
        return SCNVector3(ax + bx, ay + by, az + bz)
    }

    static func sub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        let ax = Float(a.x), ay = Float(a.y), az = Float(a.z)
        let bx = Float(b.x), by = Float(b.y), bz = Float(b.z)
        return SCNVector3(ax - bx, ay - by, az - bz)
    }

    static func scale(_ a: SCNVector3, by s: Float) -> SCNVector3 {
        let ax = Float(a.x), ay = Float(a.y), az = Float(a.z)
        return SCNVector3(ax * s, ay * s, az * s)
    }

    static func length(_ v: SCNVector3) -> Float {
        let x = Float(v.x), y = Float(v.y), z = Float(v.z)
        return sqrt(x * x + y * y + z * z)
    }

    static func dot(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let ax = Float(a.x), ay = Float(a.y), az = Float(a.z)
        let bx = Float(b.x), by = Float(b.y), bz = Float(b.z)
        return ax * bx + ay * by + az * bz
    }
}
