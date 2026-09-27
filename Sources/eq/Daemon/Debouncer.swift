import Foundation

/// Trailing-edge debounce: every trigger restarts the wait, so a burst runs the action once after it settles.
/// Not thread-safe; trigger it and let `schedule` run work on one serial queue.
final class Debouncer {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let delay: TimeInterval
    private let schedule: Schedule
    private let action: () -> Void
    // A generation instead of cancellable work items keeps `schedule` a plain function a test clock can fake.
    private var generation = 0

    init(delay: TimeInterval, schedule: @escaping Schedule, action: @escaping () -> Void) {
        self.delay = delay
        self.schedule = schedule
        self.action = action
    }

    convenience init(delay: TimeInterval, queue: DispatchQueue, action: @escaping () -> Void) {
        self.init(delay: delay, schedule: { delay, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }, action: action)
    }

    func trigger() {
        generation += 1
        let armed = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == armed else { return }
            self.action()
        }
    }

    func cancel() {
        generation += 1
    }
}
