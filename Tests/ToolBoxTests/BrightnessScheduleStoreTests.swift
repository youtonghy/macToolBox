import XCTest
@testable import ToolBox

final class BrightnessScheduleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var key: String!
    private var store: BrightnessScheduleStore!

    override func setUp() {
        super.setUp()
        key = "test.brightnessSchedule.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: key)
        defaults.removePersistentDomain(forName: key)
        store = BrightnessScheduleStore(defaults: defaults, key: key)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: key)
        defaults = nil
        store = nil
        key = nil
        super.tearDown()
    }

    func testMissingKeyReturnsDisabledDefault() {
        let result = store.load()
        XCTAssertFalse(result.configuration.isEnabled)
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.configuration.schedule.segments.count, 4)
        XCTAssertEqual(
            result.configuration.schedule.segments.map(\.brightnessPercent),
            [80, 60, 70, 35]
        )
    }

    func testRoundTripPreservesEnabledUUIDsAndOrder() throws {
        var schedule = BrightnessSchedule.default
        schedule = try schedule.insertingSegment(
            startMinute: MinuteOfDay(hour: 12, minute: 30)!,
            brightnessPercent: 42
        )
        let configuration = BrightnessScheduleConfiguration(isEnabled: true, schedule: schedule)
        try store.save(configuration)

        let loaded = store.load()
        XCTAssertNil(loaded.issue)
        XCTAssertTrue(loaded.configuration.isEnabled)
        XCTAssertEqual(loaded.configuration.schedule.segments, schedule.segments)
    }

    func testUnknownSchemaFailsClosedWithoutOverwriting() throws {
        let payload: [String: Any] = [
            "schemaVersion": 99,
            "isEnabled": true,
            "segments": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: key)

        let loaded = store.load()
        XCTAssertFalse(loaded.configuration.isEnabled)
        XCTAssertEqual(loaded.issue, .unknownSchema(99))
        XCTAssertEqual(defaults.data(forKey: key), data)
    }

    func testMalformedJSONFailsClosed() {
        defaults.set(Data("not-json".utf8), forKey: key)
        let loaded = store.load()
        XCTAssertFalse(loaded.configuration.isEnabled)
        XCTAssertEqual(loaded.issue, .corruptData)
        XCTAssertEqual(defaults.data(forKey: key), Data("not-json".utf8))
    }

    func testInvalidSegmentsFailClosed() throws {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "isEnabled": true,
            "segments": [
                [
                    "id": UUID().uuidString,
                    "startMinute": 100,
                    "brightnessPercent": 50
                ],
                [
                    "id": UUID().uuidString,
                    "startMinute": 100,
                    "brightnessPercent": 60
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: key)

        let loaded = store.load()
        XCTAssertFalse(loaded.configuration.isEnabled)
        XCTAssertEqual(loaded.issue, .invalidSchedule)
        XCTAssertEqual(defaults.data(forKey: key), data)
    }

    func testValidCommitReplacesCorruptPayload() throws {
        defaults.set(Data("broken".utf8), forKey: key)
        XCTAssertEqual(store.load().issue, .corruptData)

        let configuration = BrightnessScheduleConfiguration(
            isEnabled: true,
            schedule: .default
        )
        try store.save(configuration)
        let loaded = store.load()
        XCTAssertNil(loaded.issue)
        XCTAssertTrue(loaded.configuration.isEnabled)
    }
}
