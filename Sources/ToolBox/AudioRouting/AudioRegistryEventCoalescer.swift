import Foundation

/// Debounces registry churn, but never defers past `maximumDelay` after the first event
/// of a burst. Core Audio can publish process/device changes indefinitely (helpers,
/// notification sounds, daemons), and a pure debounce would keep the snapshot stale for
/// as long as that lasts — which leaves saved audio rules unapplied.
@MainActor
final class AudioRegistryEventCoalescer {
    private let delay: Duration
    private let maximumDelay: Duration?
    private var pendingTask: Task<Void, Never>?
    private var burstDeadline: ContinuousClock.Instant?

    init(delay: Duration = .milliseconds(100), maximumDelay: Duration? = nil) {
        self.delay = delay
        self.maximumDelay = maximumDelay
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        let now = ContinuousClock.now
        let deadline = burstDeadline ?? maximumDelay.map { now.advanced(by: $0) }
        burstDeadline = deadline
        pendingTask?.cancel()
        let sleepDuration = deadline.map {
            min(delay, max(.zero, now.duration(to: $0)))
        } ?? delay
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: sleepDuration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            pendingTask = nil
            burstDeadline = nil
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        burstDeadline = nil
    }
}
