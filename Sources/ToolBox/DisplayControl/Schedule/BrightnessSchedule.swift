import Foundation

/// Minute of a local calendar day in `0..<1440`.
struct MinuteOfDay: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: Int

    init?(rawValue: Int) {
        guard (0..<1_440).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(rawValue: hour * 60 + minute)
    }

    var hour: Int { rawValue / 60 }
    var minute: Int { rawValue % 60 }

    static func < (lhs: MinuteOfDay, rhs: MinuteOfDay) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func minutes(from date: Date, calendar: Calendar) -> MinuteOfDay? {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return MinuteOfDay(hour: hour, minute: minute)
    }
}

/// One brightness change point. The interval ends at the next segment's start (cyclic).
struct BrightnessScheduleSegment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var startMinute: MinuteOfDay
    var brightnessPercent: Int

    init(id: UUID = UUID(), startMinute: MinuteOfDay, brightnessPercent: Int) {
        self.id = id
        self.startMinute = startMinute
        self.brightnessPercent = brightnessPercent
    }

    var normalizedBrightness: Double {
        Double(brightnessPercent) / 100.0
    }
}

/// Derived half-open interval `[start, end)` covering part of the local day.
struct BrightnessScheduleInterval: Identifiable, Equatable, Sendable {
    var id: UUID
    var startMinute: MinuteOfDay
    var endMinute: MinuteOfDay
    var durationMinutes: Int
    var brightnessPercent: Int
    var wrapsToNextDay: Bool
}

/// Active segment plus the next absolute wall-clock transition.
struct BrightnessScheduleMatch: Equatable, Sendable {
    var activeSegment: BrightnessScheduleSegment
    var nextTransition: Date
}

enum BrightnessScheduleValidationError: Error, Equatable, LocalizedError {
    case empty
    case invalidBrightness(Int)
    case duplicateSegmentID(UUID)
    case duplicateStartMinute(Int)
    case cannotRemoveLastSegment
    case noRoomForInsertion

    var errorDescription: String? {
        switch self {
        case .empty:
            return "日程至少需要一个时段。"
        case let .invalidBrightness(value):
            return "亮度 \(value)% 无效，须在 0…100。"
        case .duplicateSegmentID:
            return "时段 ID 重复。"
        case let .duplicateStartMinute(minute):
            return "时间 \(Self.formatMinute(minute)) 已存在。"
        case .cannotRemoveLastSegment:
            return "至少保留一个时段。"
        case .noRoomForInsertion:
            return "已无法添加更多分钟级时段。"
        }
    }

    private static func formatMinute(_ raw: Int) -> String {
        String(format: "%02d:%02d", raw / 60, raw % 60)
    }
}

/// Validated cyclic brightness schedule covering exactly 24 local hours.
struct BrightnessSchedule: Equatable, Sendable {
    private(set) var segments: [BrightnessScheduleSegment]

    static let defaultSegments: [BrightnessScheduleSegment] = [
        BrightnessScheduleSegment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111101")!,
            startMinute: MinuteOfDay(hour: 7, minute: 0)!,
            brightnessPercent: 80
        ),
        BrightnessScheduleSegment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111102")!,
            startMinute: MinuteOfDay(hour: 9, minute: 0)!,
            brightnessPercent: 60
        ),
        BrightnessScheduleSegment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111103")!,
            startMinute: MinuteOfDay(hour: 18, minute: 0)!,
            brightnessPercent: 70
        ),
        BrightnessScheduleSegment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111104")!,
            startMinute: MinuteOfDay(hour: 22, minute: 0)!,
            brightnessPercent: 35
        )
    ]

    static var `default`: BrightnessSchedule {
        // Defaults are known-valid; force unwrap is intentional for the built-in preset.
        try! BrightnessSchedule(validating: defaultSegments)
    }

    init(validating segments: [BrightnessScheduleSegment]) throws {
        self.segments = try Self.canonicalize(segments)
    }

    var intervals: [BrightnessScheduleInterval] {
        guard !segments.isEmpty else { return [] }
        if segments.count == 1, let only = segments.first {
            return [
                BrightnessScheduleInterval(
                    id: only.id,
                    startMinute: only.startMinute,
                    endMinute: only.startMinute,
                    durationMinutes: 1_440,
                    brightnessPercent: only.brightnessPercent,
                    wrapsToNextDay: true
                )
            ]
        }

        return segments.enumerated().map { index, segment in
            let next = segments[(index + 1) % segments.count]
            let duration = Self.modularDuration(
                from: segment.startMinute.rawValue,
                to: next.startMinute.rawValue
            )
            let wraps = next.startMinute.rawValue <= segment.startMinute.rawValue
            return BrightnessScheduleInterval(
                id: segment.id,
                startMinute: segment.startMinute,
                endMinute: next.startMinute,
                durationMinutes: duration,
                brightnessPercent: segment.brightnessPercent,
                wrapsToNextDay: wraps
            )
        }
    }

    func match(at date: Date, calendar: Calendar = .current) -> BrightnessScheduleMatch? {
        guard let minute = MinuteOfDay.minutes(from: date, calendar: calendar),
              let active = activeSegment(at: minute),
              let next = nextTransition(after: date, calendar: calendar)
        else {
            return nil
        }
        return BrightnessScheduleMatch(activeSegment: active, nextTransition: next)
    }

    func activeSegment(at minute: MinuteOfDay) -> BrightnessScheduleSegment? {
        guard !segments.isEmpty else { return nil }
        // Greatest start <= minute; if none, last segment (wrap from previous day).
        var candidate: BrightnessScheduleSegment?
        for segment in segments {
            if segment.startMinute.rawValue <= minute.rawValue {
                candidate = segment
            } else {
                break
            }
        }
        return candidate ?? segments.last
    }

    func nextTransition(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !segments.isEmpty else { return nil }

        var candidates: [Date] = []
        for segment in segments {
            if let first = nextOccurrence(
                of: segment.startMinute,
                after: date,
                calendar: calendar,
                repeatedTimePolicy: .first
            ) {
                candidates.append(first)
            }
            if let last = nextOccurrence(
                of: segment.startMinute,
                after: date,
                calendar: calendar,
                repeatedTimePolicy: .last
            ) {
                candidates.append(last)
            }
        }
        return candidates.filter { $0 > date }.min()
    }

    func insertingSegment(
        startMinute: MinuteOfDay,
        brightnessPercent: Int,
        id: UUID = UUID()
    ) throws -> BrightnessSchedule {
        var next = segments
        next.append(
            BrightnessScheduleSegment(
                id: id,
                startMinute: startMinute,
                brightnessPercent: brightnessPercent
            )
        )
        return try BrightnessSchedule(validating: next)
    }

    func updatingSegment(
        id: UUID,
        startMinute: MinuteOfDay,
        brightnessPercent: Int
    ) throws -> BrightnessSchedule {
        guard let index = segments.firstIndex(where: { $0.id == id }) else {
            throw BrightnessScheduleValidationError.empty
        }
        var next = segments
        next[index] = BrightnessScheduleSegment(
            id: id,
            startMinute: startMinute,
            brightnessPercent: brightnessPercent
        )
        return try BrightnessSchedule(validating: next)
    }

    func removingSegment(id: UUID) throws -> BrightnessSchedule {
        guard segments.count > 1 else {
            throw BrightnessScheduleValidationError.cannotRemoveLastSegment
        }
        let next = segments.filter { $0.id != id }
        guard next.count == segments.count - 1 else {
            throw BrightnessScheduleValidationError.empty
        }
        return try BrightnessSchedule(validating: next)
    }

    /// Suggests an unused start minute after the given segment (or after the last if nil).
    func suggestedInsertion(after segmentID: UUID?) -> MinuteOfDay? {
        guard !segments.isEmpty else {
            return MinuteOfDay(rawValue: 0)
        }
        let used = Set(segments.map(\.startMinute.rawValue))
        guard used.count < 1_440 else { return nil }

        let ordered = segments
        let baseIndex: Int = {
            if let segmentID, let index = ordered.firstIndex(where: { $0.id == segmentID }) {
                return index
            }
            return ordered.count - 1
        }()

        let start = ordered[baseIndex].startMinute.rawValue
        let end = ordered[(baseIndex + 1) % ordered.count].startMinute.rawValue
        let duration = Self.modularDuration(from: start, to: end)
        if duration > 1 {
            let candidate = (start + duration / 2) % 1_440
            if !used.contains(candidate), let minute = MinuteOfDay(rawValue: candidate) {
                return minute
            }
        }

        for offset in 1..<1_440 {
            let candidate = (start + offset) % 1_440
            if !used.contains(candidate), let minute = MinuteOfDay(rawValue: candidate) {
                return minute
            }
        }
        return nil
    }

    // MARK: - Private

    private static func canonicalize(
        _ segments: [BrightnessScheduleSegment]
    ) throws -> [BrightnessScheduleSegment] {
        guard !segments.isEmpty else {
            throw BrightnessScheduleValidationError.empty
        }
        guard segments.count <= 1_440 else {
            throw BrightnessScheduleValidationError.noRoomForInsertion
        }

        var seenIDs = Set<UUID>()
        var seenStarts = Set<Int>()
        for segment in segments {
            guard (0...100).contains(segment.brightnessPercent) else {
                throw BrightnessScheduleValidationError.invalidBrightness(segment.brightnessPercent)
            }
            if !seenIDs.insert(segment.id).inserted {
                throw BrightnessScheduleValidationError.duplicateSegmentID(segment.id)
            }
            if !seenStarts.insert(segment.startMinute.rawValue).inserted {
                throw BrightnessScheduleValidationError.duplicateStartMinute(segment.startMinute.rawValue)
            }
        }

        return segments.sorted { $0.startMinute < $1.startMinute }
    }

    private static func modularDuration(from start: Int, to end: Int) -> Int {
        let delta = end - start
        return delta > 0 ? delta : delta + 1_440
    }

    private func nextOccurrence(
        of minute: MinuteOfDay,
        after date: Date,
        calendar: Calendar,
        repeatedTimePolicy: Calendar.RepeatedTimePolicy
    ) -> Date? {
        var components = DateComponents()
        components.hour = minute.hour
        components.minute = minute.minute
        components.second = 0
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: repeatedTimePolicy,
            direction: .forward
        )
    }
}

struct BrightnessScheduleConfiguration: Equatable, Sendable {
    var isEnabled: Bool
    var schedule: BrightnessSchedule

    static var disabledDefault: BrightnessScheduleConfiguration {
        BrightnessScheduleConfiguration(isEnabled: false, schedule: .default)
    }
}
