import CoreGraphics
import XCTest
@testable import ToolBox

final class DisplayControlValueStoreTests: XCTestCase {
    private let displayID: CGDirectDisplayID = 42

    func testFallbacksMatchWriteOnlyDefaults() {
        let store = DisplayControlValueStore()

        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .brightness)).rawCurrent, 100)
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .contrast)).rawCurrent, 75)
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .volume)).rawCurrent, 12)
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .mute)).rawCurrent, 2)
    }

    func testObservedRangeControlsRawConversion() throws {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        store.recordObserved(
            DisplayControlValue(
                kind: .brightness,
                timestamp: Date(),
                rawCurrent: 20,
                rawMinimum: 0,
                rawMaximum: 80,
                normalized: 0.25
            ),
            for: key
        )

        XCTAssertEqual(try store.rawValue(for: key, normalized: 0.5), 40)
    }

    func testMissingObservationProducesWritableFallbackCapability() {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)

        let capability = store.capability(for: key, observedValue: nil)

        XCTAssertEqual(capability.status, .writeOnly)
        XCTAssertEqual(capability.value?.rawCurrent, 100)
    }

    func testSuccessfulWriteUpdatesDeduplicationState() throws {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        let raw = try store.rawValue(for: key, normalized: 0.4)

        XCTAssertTrue(store.shouldWrite(raw, for: key))
        store.recordSuccessfulWrite(raw, normalized: 0.4, for: key)

        XCTAssertFalse(store.shouldWrite(raw, for: key))
        XCTAssertEqual(store.value(for: key).normalized, 0.4, accuracy: 0.001)
    }

    func testObservedValueInvalidatesStaleSuccessfulWriteState() throws {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        let priorRaw = try store.rawValue(for: key, normalized: 0.4)
        store.recordSuccessfulWrite(priorRaw, normalized: 0.4, for: key)

        store.recordObserved(
            DisplayControlValue(
                kind: .brightness,
                timestamp: Date(),
                rawCurrent: 60,
                rawMinimum: 0,
                rawMaximum: 100,
                normalized: 0.6
            ),
            for: key
        )

        XCTAssertTrue(store.shouldWrite(priorRaw, for: key))
        XCTAssertTrue(store.shouldWrite(60, for: key))
    }

    func testInvalidObservedRangeIsRejectedDuringConversion() {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        store.recordObserved(
            DisplayControlValue(
                kind: .brightness,
                timestamp: Date(),
                rawCurrent: 10,
                rawMinimum: 10,
                rawMaximum: 10,
                normalized: 0
            ),
            for: key
        )

        XCTAssertThrowsError(try store.rawValue(for: key, normalized: 0.5))
    }
}
