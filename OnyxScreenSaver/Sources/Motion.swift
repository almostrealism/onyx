import SceneKit

/// Per-totem motion state. Lives next to each `HostTotem` and is mutated by
/// `Motion.advance` once per render frame.
struct MotionState {
    var position: SCNVector3
    var velocity: SCNVector3
}

/// Pure-math motion engine: drift + soft mutual repulsion + soft sphere
/// containment. The Motion namespace doesn't know about SceneKit nodes,
/// only positions and velocities — SculptureScene calls into it once per
/// frame and pushes the resulting positions onto totem nodes.
enum Motion {

    /// Outer bound — totems are softly pushed back toward origin if they
    /// stray beyond this radius. Keeps the action centered in frame.
    static let boundsRadius: Float = 28

    /// If two totems get closer than this, they push each other apart.
    /// Chosen larger than the widest totem (radius ≈ 2.3 at max CPU) plus a
    /// generous visual buffer so they never look like they're touching.
    static let repulsionRadius: Float = 11

    /// Repulsion force strength. Tuned so two totems aimed straight at each
    /// other turn aside well before contact — but the deflection is gentle
    /// enough that it doesn't look like a hard bounce.
    static let repulsionStrength: Float = 14

    /// Per-frame velocity damping. Without this, repulsion impulses
    /// accumulate and totems eventually fling themselves out of frame.
    /// 0.985^60 ≈ 0.4 in one second of drift — slow bleed, not freeze.
    static let damping: Float = 0.985

    /// Top speed (units/sec). Capped so a chain of repulsion events can't
    /// snowball into something that looks frantic.
    static let maxSpeed: Float = 3.5

    /// Pseudo-random initial velocity. Tiny magnitude — the visual reads as
    /// "drifting", not "moving".
    static func randomInitialVelocity(seed: Int) -> SCNVector3 {
        // Deterministic-ish: spread hosts evenly around the unit circle
        // using their seed (== host index), then jitter by a fixed pattern.
        let angle = Float(seed) * 1.6180339 * .pi  // golden-angle spacing
        let speed: Float = 0.4
        return SCNVector3(speed * cos(angle),
                          speed * 0.6 * sin(angle * 0.7),
                          speed * sin(angle))
    }

    /// Advance the system by `dt` seconds. Mutates each MotionState in place.
    static func advance(_ states: inout [MotionState], dt: Float) {
        let dt = min(dt, 1.0 / 15.0)  // clamp huge dt (e.g. tab-out resume)
        guard !states.isEmpty else { return }

        // 1) Pairwise mutual repulsion.
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                let delta = sub(states[j].position, states[i].position)
                let dist = length(delta)
                guard dist < repulsionRadius && dist > 0.0001 else { continue }
                let overlap = repulsionRadius - dist
                // Magnitude grows quadratically as totems approach contact —
                // gentle from afar, firm up close.
                let mag = repulsionStrength * (overlap / repulsionRadius) * (overlap / repulsionRadius)
                let unit = scale(delta, by: 1.0 / dist)
                let impulse = scale(unit, by: mag * dt)
                states[i].velocity = sub(states[i].velocity, impulse)
                states[j].velocity = add(states[j].velocity, impulse)
            }
        }

        // 2) Soft sphere containment. Outside the bounds, accelerate
        //    toward origin proportionally to how far out we've drifted.
        for i in 0..<states.count {
            let p = states[i].position
            let r = length(p)
            if r > boundsRadius {
                let excess = r - boundsRadius
                let unit = scale(p, by: 1.0 / max(r, 0.0001))
                let pullStrength: Float = 6.0
                let impulse = scale(unit, by: -pullStrength * excess * dt)
                states[i].velocity = add(states[i].velocity, impulse)
            }
        }

        // 3) Integrate, damp, cap.
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
    // SCNVector3 is a C struct so it has no operators — small helpers keep
    // the motion math readable above.

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
}
