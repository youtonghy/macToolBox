import XCTest
@testable import ToolBox

final class BrightnessScheduleTests: XCTestCase {
    func testRejectsEmptySchedule() {
        XCTAssertThrowsError(try BrightnessSchedule(validating: [])) { error in
            XCTAssertEqual(error as? BrightnessScheduleValidationError, .empty)
        }
    }

    func testRejectsInvalidBrightness() {
        let segment = BrightnessScheduleSegment(
            startMinute: MinuteOfDay(hour: 8, minute: 0)!,
            brightnessPercent: 140
        )
        XCTAssertThrowsError(try BrightnessSchedule(validating: [segment])) { error in
            XCTAssertEqual(error as? BrightnessScheduleValidationError, .invalidBrightness(140))
        }
    }

    func testRejectsDuplicateStartMinutes() {
        let a = BrightnessScheduleSegment(
            startMinute: MinuteOfDay(hour: 8, minute: 0)!,
            brightnessPercent: 50
        )
        let b = BrightnessScheduleSegment(
            startMinute: MinuteOfDay(hour: 8, minute: 0)!,
            brightnessPercent: 60
        )
        XCTAssertThrowsError(try BrightnessSchedule(validating: [a, b])) { error in
            XCTAssertEqual(
                error as? BrightnessScheduleValidationError,
                .duplicateStartMinute(8 * 60)
            )
        }
    }

    func testCanonicalizesUnsortedInput() throws {
        let late = BrightnessScheduleSegment(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startMinute: MinuteOfDay(hour: 18, minute: 0)!,
            brightnessPercent: 40
        )
        let early = BrightnessScheduleSegment(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            startMinute: MinuteOfDay(hour: 6, minute: 0)!,
            brightnessPercent: 80
        )
        let schedule = try BrightnessSchedule(validating: [late, early])
        XCTAssertEqual(schedule.segments.map(\.startMinute.rawValue), [6 * 60, 18 * 60])
        XCTAssertEqual(schedule.segments.map(\.id), [early.id, late.id])
    }

    func testOneSegmentCoversFullDay() throws {
        let segment = BrightnessScheduleSegment(
            startMinute: MinuteOfDay(hour: 12, minute: 0)!,
            brightnessPercent: 55
        )
        let schedule = try BrightnessSchedule(validating: [segment])
        let intervals = schedule.intervals
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].durationMinutes, 1_440)
        XCTAssertTrue(intervals[0].wrapsToNextDay)
        XCTAssertEqual(schedule.activeSegment(at: MinuteOfDay(hour: 0, minute: 0)!)?.brightnessPercent, 55)
        XCTAssertEqual(schedule.activeSegment(at: MinuteOfDay(hour: 23, minute: 59)!)?.brightnessPercent, 55)
    }

    func testDefaultScheduleCoversFullDayWithWrap() {
        let schedule = BrightnessSchedule.default
        let intervals = schedule.intervals
        XCTAssertEqual(intervals.count, 4)
        XCTAssertEqual(intervals.map(\.durationMinutes).reduce(0, +), 1_440)

        let wrap = intervals.first(where: \.wrapsToNextDay)
        XCTAssertEqual(wrap?.startMinute.rawValue, 22 * 60)
        XCTAssertEqual(wrap?.endMinute.rawValue, 7 * 60)
        XCTAssertEqual(wrap?.brightnessPercent, 35)
    }

    func testEveryMinuteMatchesExactlyOneIntervalInDefaultSchedule() {
        let schedule = BrightnessSchedule.default
        for minute in 0..<1_440 {
            let active = schedule.activeSegment(at: MinuteOfDay(rawValue: minute)!)
            XCTAssertNotNil(active)

            let matchingIntervals = schedule.intervals.filter { interval in
                contains(minute: minute, interval: interval)
            }
            XCTAssertEqual(matchingIntervals.count, 1, "minute \(minute)")
            XCTAssertEqual(matchingIntervals.first?.brightnessPercent, active?.brightnessPercent)
        }
    }

    func testExactBoundarySelectsNewSegment() {
        let schedule = BrightnessSchedule.default
        XCTAssertEqual(
            schedule.activeSegment(at: MinuteOfDay(hour: 8, minute: 59)!)?.brightnessPercent,
            80
        )
        XCTAssertEqual(
            schedule.activeSegment(at: MinuteOfDay(hour: 9, minute: 0)!)?.brightnessPercent,
            60
        )
        XCTAssertEqual(
            schedule.activeSegment(at: MinuteOfDay(hour: 6, minute: 59)!)?.brightnessPercent,
            35
        )
        XCTAssertEqual(
            schedule.activeSegment(at: MinuteOfDay(hour: 7, minute: 0)!)?.brightnessPercent,
            80
        )
    }

    func testInsertUpdateDeleteMutations() throws {
        var schedule = BrightnessSchedule.default
        let inserted = try schedule.insertingSegment(
            startMinute: MinuteOfDay(hour: 12, minute: 0)!,
            brightnessPercent: 50
        )
        XCTAssertEqual(inserted.segments.count, 5)
        XCTAssertEqual(
            inserted.activeSegment(at: MinuteOfDay(hour: 12, minute: 30)!)?.brightnessPercent,
            50
        )

        let target = inserted.segments.first(where: { $0.startMinute.rawValue == 12 * 60 })!
        let updated = try inserted.updatingSegment(
            id: target.id,
            startMinute: MinuteOfDay(hour: 13, minute: 0)!,
            brightnessPercent: 45
        )
        XCTAssertEqual(
            updated.activeSegment(at: MinuteOfDay(hour: 13, minute: 0)!)?.brightnessPercent,
            45
        )

        let removed = try updated.removingSegment(id: target.id)
        XCTAssertEqual(removed.segments.count, 4)
        XCTAssertEqual(
            removed.activeSegment(at: MinuteOfDay(hour: 12, minute: 30)!)?.brightnessPercent,
            60
        )
    }

    func testCannotRemoveLastSegment() throws {
        let only = BrightnessScheduleSegment(
            startMinute: MinuteOfDay(hour: 10, minute: 0)!,
            brightnessPercent: 70
        )
        let schedule = try BrightnessSchedule(validating: [only])
        XCTAssertThrowsError(try schedule.removingSegment(id: only.id)) { error in
            XCTAssertEqual(
                error as? BrightnessScheduleValidationError,
                .cannotRemoveLastSegment
            )
        }
    }

    func testDuplicateInsertLeavesOriginalUnchanged() throws {
        let schedule = BrightnessSchedule.default
        XCTAssertThrowsError(
            try schedule.insertingSegment(
                startMinute: MinuteOfDay(hour: 7, minute: 0)!,
                brightnessPercent: 10
            )
        )
        XCTAssertEqual(schedule.segments.count, 4)
    }

    func testSuggestedInsertionUsesMidpoint() {
        let schedule = BrightnessSchedule.default
        let seven = schedule.segments.first(where: { $0.startMinute.rawValue == 7 * 60 })!
        let suggestion = schedule.suggestedInsertion(after: seven.id)
        XCTAssertEqual(suggestion?.rawValue, 8 * 60)
    }

    func testNextTransitionUsesCalendarNotFixedDayLength() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let schedule = try BrightnessSchedule(validating: [
            BrightnessScheduleSegment(
                startMinute: MinuteOfDay(hour: 10, minute: 0)!,
                brightnessPercent: 50
            ),
            BrightnessScheduleSegment(
                startMinute: MinuteOfDay(hour: 18, minute: 0)!,
                brightnessPercent: 30
            )
        ])

        let noon = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))!
        let next = try XCTUnwrap(schedule.nextTransition(after: noon, calendar: calendar))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(components.hour, 18)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.day, 1)

        let evening = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 19))!
        let nextMorning = try XCTUnwrap(schedule.nextTransition(after: evening, calendar: calendar))
        let morning = calendar.dateComponents([.day, .hour, .minute], from: nextMorning)
        XCTAssertEqual(morning.day, 2)
        XCTAssertEqual(morning.hour, 10)
        XCTAssertEqual(morning.minute, 0)
    }

    func testMatchUsesLocalMinuteAndNextBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let schedule = BrightnessSchedule.default
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 8, minute: 30))!
        let match = try XCTUnwrap(schedule.match(at: date, calendar: calendar))
        XCTAssertEqual(match.activeSegment.brightnessPercent, 80)
        let next = calendar.dateComponents([.hour, .minute], from: match.nextTransition)
        XCTAssertEqual(next.hour, 9)
        XCTAssertEqual(next.minute, 0)
    }

    // MARK: - Helpers

    private func contains(minute: Int, interval: BrightnessScheduleInterval) -> Bool {
        let start = interval.startMinute.rawValue
        let end = interval.endMinute.rawValue
        if interval.durationMinutes == 1_440 {
            return true
        }
        if interval.wrapsToNextDay {
            return minute >= start || minute < end
        }
        return minute >= start && minute < end
    }
}
