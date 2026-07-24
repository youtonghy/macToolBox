import Foundation

@MainActor
final class AudioRegistryEventCoalescer {
    private let delay: Duration
    private var pendingTask: Task<Void, Never>?

    init(delay: Duration = .milliseconds(100)) {
        self.delay = delay
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        pendingTask?.cancel()
        let delay = delay
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            pendingTask = nil
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
