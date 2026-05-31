import SceneKit

/// Per-totem motion state. Position + velocity + mass. Mutated by
/// `Motion.advance` once per render frame.
struct MotionState {
    var position: SCNVector3
    var velocity: SCNVector3
    /// Mass derived from CPU activity — busier hosts are heavier.
    /// Updated by SculptureScene whenever new samples arrive.
    var mass: Float = 1.0
}

/// Pure-math motion engine: mass-weighted Newtonian gravity + short-range
/// repulsion + soft sphere containment. Doesn't know about SceneKit nodes,
/// only positions / velocities / masses — SculptureScene calls into it once
/// per frame and pushes the resulting positions back onto totem nodes.
///
/// Behavior the math is meant to produce:
/// - Heavy totems (high CPU) feel less of each impulse → they tend to sit
///   still and form a center-of-mass anchor.
/// - Light totems (idle CPU) accelerate easily and end up orbiting or
///   getting flung around by the heavier ones.
/// - Pairwise gravitational attraction pulls everything together over
///   distance; short-range repulsion stops them from passing through each
///   other. The static equilibrium would be everyone touching, but the
///   ongoing tangential velocity and CPU-driven mass changes keep the
///   system stirring.
enum Motion {

    /// Outer bound — softly pushed back toward origin if a totem strays
    /// beyond this radius. Keeps the action centered in frame.
    static let boundsRadius: Float = 30

    /// Pairwise gravitational constant. Real Newtonian gravity is G·m₁·m₂/r²
    /// — this G is tuned so a pair of average-mass totems at typical
    /// separation produces visible (but not violent) acceleration.
    static let gravityG: Float = 35

    /// Distance floor for the gravity 1/r² term. Without it the force
    /// blows up as totems approach; clamping at ~3 units means short-range
    /// repulsion dominates close-in.
    static let gravityMinDist: Float = 3

    /// If two totems get closer than this, they push each other apart.
    /// Sized larger than the widest totem so they never visually touch.
    static let repulsionRadius: Float = 9

    /// Repulsion strength. Tuned to overpower gravity at contact range so
    /// totems can't crash into each other no matter what masses they have.
    static let repulsionStrength: Float = 60

    /// Per-frame velocity damping. With mass-weighted gravity providing
    /// continuous force, we can damp lightly and still avoid runaway.
    static let damping: Float = 0.997

    /// Top speed (units/sec). Caps any one totem's velocity so a sequence
    /// of gravity impulses can't snowball into something that looks frantic.
    static let maxSpeed: Float = 7.0

    /// Initial velocity: mostly tangent to the spawn position, so totems
    /// start in orbit-friendly motion rather than radially-inward
    /// (which would cause an immediate central collision).
    static func initialVelocity(position: SCNVector3, seed: Int) -> SCNVector3 {
        let theta = atan2(Float(position.z), Float(position.x))
        // Tangent direction in the XZ plane: rotate position 90° around Y.
        let tangentSpeed: Float = 2.0
        // Small Y-jitter via golden-angle so totems don't all move in one
        // plane. Deterministic per seed.
        let yJitter = sin(Float(seed) * 1.6180339) * 0.5
        return SCNVector3(-tangentSpeed * sin(theta),
                          yJitter,
                          tangentSpeed * cos(theta))
    }

    /// Advance the system by `dt` seconds. Mutates each MotionState in place.
    static func advance(_ states: inout [MotionState], dt: Float) {
        let dt = min(dt, 1.0 / 15.0)  // clamp huge dt (e.g. tab-out resume)
        guard !states.isEmpty else { return }

        // 1) Pairwise forces: gravity (attractive, long range) + repulsion
        //    (strong, short range). Both are converted to per-totem velocity
        //    deltas using a = F / m so heavier totems accelerate less.
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                let delta = sub(states[j].position, states[i].position)
                let dist = length(delta)
                guard dist > 0.0001 else { continue }
                let unit = scale(delta, by: 1.0 / dist)
                let mi = states[i].mass
                let mj = states[j].mass

                // Newtonian gravity (attractive). Floor the distance term
                // so the close-range behavior is dominated by repulsion.
                let effDist = max(dist, gravityMinDist)
                let fGrav = gravityG * mi * mj / (effDist * effDist)
                // a = F/m → impulse_i is along +unit toward j, impulse_j is opposite.
                states[i].velocity = add(states[i].velocity,
                                         scale(unit, by:  fGrav * dt / mi))
                states[j].velocity = add(states[j].velocity,
                                         scale(unit, by: -fGrav * dt / mj))

                // Short-range repulsion: ramps up quadratically as totems
                // approach contact. Mass-divided like gravity, so light
                // totems bounce off heavy ones more dramatically than the
                // reverse.
                if dist < repulsionRadius {
                    let overlap = repulsionRadius - dist
                    let fRep = repulsionStrength * (overlap / repulsionRadius) * (overlap / repulsionRadius)
                    states[i].velocity = sub(states[i].velocity,
                                             scale(unit, by: fRep * dt / mi))
                    states[j].velocity = add(states[j].velocity,
                                             scale(unit, by: fRep * dt / mj))
                }
            }
        }

        // 2) Soft sphere containment. Outside the bounds, accelerate
        //    toward origin proportionally to how far out we've drifted.
        //    Mass-divided so heavy totems still respond.
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

        // 3) Damp, cap, integrate. No minimum-speed floor — gravity from
        //    the other totems is always pulling on every totem (light ones
        //    move; heavy ones happily sit still, as desired).
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
}
