import SceneKit

/// Per-object motion state. Mass + radius + position + velocity, plus an
/// `isAnchor` flag for objects that should never move regardless of what
/// force is applied to them (the central Timing ball).
struct MotionState {
    var position: SCNVector3
    var velocity: SCNVector3
    /// Mass derived from activity. Heavier objects feel less of each
    /// impulse and pull harder on others gravitationally.
    var mass: Float = 1.0
    /// Collision radius. Two objects are in contact when their center
    /// distance is less than `r_i + r_j`.
    var radius: Float = 3.5
    /// When true, the integrator skips writing velocity/position changes
    /// to this body — gravity, collisions, and the bounds spring all
    /// silently no-op on it. The body still affects others (its mass
    /// shows up in gravity and collision math for the other body). Used
    /// to pin the Timing ball at origin regardless of forces.
    var isAnchor: Bool = false
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

    /// Coefficient of restitution. 1.0 = perfect elastic; we go well above
    /// that because the system is intentionally non-physical — real
    /// metallic cubes wouldn't bounce off each other; we want them to.
    /// Combined with damping + maxSpeed cap, long-run energy stays bounded.
    static let restitution: Float = 2.5

    /// **Bonus kick** added on contact *with an anchor* (i.e. the Timing
    /// ball) — does NOT fire on totem-vs-totem contacts. Without this,
    /// a totem dragged into the ball's gravity well by attraction has
    /// approximately zero normal velocity on impact, so even a super-
    /// elastic restitution produces a near-zero bounce — and the next
    /// frame's gravity yanks it right back into the well. The kick
    /// guarantees a meaningful separation velocity on every ball contact.
    /// 26 (was 18) sends the struck totem far enough that gravity has
    /// time to slow it before it falls back, breaking the "bounce-fall-
    /// bounce" cycle where everything restaged collisions immediately.
    static let bounceKickSpeed: Float = 26

    /// Per-frame velocity damping. With elastic impulses adding energy
    /// per collision AND a bonus kick on every contact, we damp very
    /// lightly. 0.999^60 ≈ 0.94 over one second — almost no bleed.
    static let damping: Float = 0.999

    /// Top speed (units/sec). Raised to allow a bounce off the central
    /// ball to actually outrun the ball's gravity. With the old cap of 9,
    /// the ball's gravity at the contact surface pulled at >10 u/s per
    /// frame, so no bounce could ever escape — totems just jittered.
    static let maxSpeed: Float = 26

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
                // Clamp effective distance at the contact distance, NOT a
                // small constant. The previous floor (3) let the 1/r² term
                // blow up between the contact surface and that floor —
                // meaning a totem touching the ball felt ~10× the gravity
                // it would have felt at the surface. Clamping at contact
                // makes the bounce-vs-gravity fight winnable at close range.
                let effDist = max(dist, contactDist)
                let fGrav = gravityG * mi * mj / (effDist * effDist)
                if !states[i].isAnchor {
                    states[i].velocity = add(states[i].velocity,
                                             scale(unit, by:  fGrav * dt / mi))
                }
                if !states[j].isAnchor {
                    states[j].velocity = add(states[j].velocity,
                                             scale(unit, by: -fGrav * dt / mj))
                }

                // --- Contact response: elastic impulse + optional kick ---
                if dist < contactDist {
                    let relVel = sub(states[j].velocity, states[i].velocity)
                    let vRelN = dot(relVel, unit)  // negative when approaching
                    let totalMass = mi + mj

                    // Standard elastic impulse — only fires on approach so
                    // we don't reverse a velocity that's already separating.
                    if vRelN < 0 {
                        let mu = (mi * mj) / totalMass
                        let jMag = -(1 + restitution) * vRelN * mu
                        if !states[j].isAnchor {
                            states[j].velocity = add(states[j].velocity,
                                                     scale(unit, by:  jMag / mj))
                        }
                        if !states[i].isAnchor {
                            states[i].velocity = sub(states[i].velocity,
                                                     scale(unit, by:  jMag / mi))
                        }
                    }

                    // Bonus kick — only applied when ONE of the bodies is
                    // an anchor (i.e. the central ball). The point of the
                    // kick is to break gravity-well captures; totem-vs-
                    // totem collisions already have plenty of energy from
                    // restitution alone. Applying the kick there would
                    // make totems fly around absurdly.
                    if states[i].isAnchor || states[j].isAnchor {
                        if !states[j].isAnchor {
                            states[j].velocity = add(states[j].velocity,
                                                     scale(unit, by: bounceKickSpeed * mi / totalMass))
                        }
                        if !states[i].isAnchor {
                            states[i].velocity = sub(states[i].velocity,
                                                     scale(unit, by: bounceKickSpeed * mj / totalMass))
                        }
                    }

                    // --- Penetration resolution with overshoot ---
                    // Push apart by penetration + slop so the next frame
                    // starts with a real gap (not just touching). Anchors
                    // don't move — the full correction goes to the other body.
                    let penetration = (contactDist - dist) + 0.4
                    if states[i].isAnchor && !states[j].isAnchor {
                        states[j].position = add(states[j].position,
                                                 scale(unit, by: penetration))
                    } else if states[j].isAnchor && !states[i].isAnchor {
                        states[i].position = sub(states[i].position,
                                                 scale(unit, by: penetration))
                    } else if !states[i].isAnchor && !states[j].isAnchor {
                        let shiftI = penetration * (mj / totalMass)
                        let shiftJ = penetration * (mi / totalMass)
                        states[i].position = sub(states[i].position,
                                                 scale(unit, by: shiftI))
                        states[j].position = add(states[j].position,
                                                 scale(unit, by: shiftJ))
                    }
                }
            }
        }

        // 2) Soft sphere containment. Outside the bounds, accelerate
        //    toward origin proportionally to how far out we've drifted.
        //    Anchors are exempt — they don't drift.
        for i in 0..<states.count where !states[i].isAnchor {
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

        // 3) Damp, cap, integrate. Anchors skip integration entirely —
        //    their position and velocity stay at whatever they were
        //    initialized to (origin, zero).
        for i in 0..<states.count where !states[i].isAnchor {
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
