import Foundation

protocol BrightnessScheduleClock: AnyObject {
    var now: Date { get }
    var calendar: Calendar { get }
    func schedule(at date: Date, generation: UInt64, fire: @escaping (UInt64) -> Void)
    func cancel()
}

/// Main-run-loop one-shot timer clock used in production.
final class FoundationBrightnessScheduleClock: BrightnessScheduleClock {
    private var timer: Timer?

    var now: Date { Date() }

    var calendar: Calendar {
        Calendar.autoupdatingCurrent
    }

    func schedule(at date: Date, generation: UInt64, fire: @escaping (UInt64) -> Void) {
        cancel()
        let interval = max(date.timeIntervalSince(now), 0.05)
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            fire(generation)
        }
        timer.tolerance = min(1.0, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// Deterministic clock for unit tests.
final class TestBrightnessScheduleClock: BrightnessScheduleClock {
    private(set) var now: Date
    private(set) var scheduledDate: Date?
    private(set) var scheduledGeneration: UInt64?
    private var fireHandler: ((UInt64) -> Void)?
    var calendar: Calendar

    init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    func schedule(at date: Date, generation: UInt64, fire: @escaping (UInt64) -> Void) {
        scheduledDate = date
        scheduledGeneration = generation
        fireHandler = fire
    }

    func cancel() {
        scheduledDate = nil
        scheduledGeneration = nil
        fireHandler = nil
    }

    func advance(to date: Date) {
        now = date
    }

    func fireIfDue() {
        guard let scheduledDate, let generation = scheduledGeneration, now >= scheduledDate else {
            return
        }
        let handler = fireHandler
        cancel()
        handler?(generation)
    }
}
