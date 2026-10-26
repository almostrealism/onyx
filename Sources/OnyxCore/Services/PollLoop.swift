import Foundation

/// A reusable periodic-poll loop for the background monitors (GitHub PRs &
/// pipelines, GitLab MRs & pipelines, …). Each of those used to copy the same
/// Timer + idempotent-start + XCTest-skip + manual-refresh boilerplate
/// verbatim; this centralizes the lifecycle so it lives in exactly one place.
///
/// Behavior (matching the hand-rolled versions it replaces):
/// - The timer runs on the main run loop in `.common` mode, so it keeps
///   firing during tracking run loops (e.g. while a menu is open).
/// - `start()` fires a tick immediately, then on `interval`. It's idempotent
///   (a second call while running is a no-op) and is skipped entirely under
///   XCTest so unit tests never kick off real network polling.
/// - `refresh()` fires an out-of-schedule tick (e.g. after the user changes
///   config). Both the initial tick and refreshes are dispatched to main.
public final class PollLoop {
    private let interval: TimeInterval
    private let tick: () -> Void
    private var timer: Timer?

    public init(interval: TimeInterval, tick: @escaping () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    public func start() {
        if NSClassFromString("XCTest") != nil { return }
        guard timer == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.tick() }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    deinit { timer?.invalidate() }
}
