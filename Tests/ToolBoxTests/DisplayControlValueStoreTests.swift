import CoreGraphics
import XCTest
@testable import ToolBox

final class DisplayControlValueStoreTests: XCTestCase {
    private let displayID: CGDirectDisplayID = 42

    func testRememberedBrightnessRestoresAcrossTransientDisplayIDs() throws {
        let memory = InMemoryDisplayBrightnessMemory()
        let identity = DisplayBrightnessMemoryIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0xA419,
            serialNumber: 123_456
        )
        var store = DisplayControlValueStore(brightnessMemory: memory)
        let oldKey = DisplayControlValueKey(displayID: 42, kind: .brightness)
        store.recordSuccessfulWrite(38, normalized: 0.38, for: oldKey, identity: identity)
        store.retainDisplays([])

        let reconnectedKey = DisplayControlValueKey(displayID: 84, kind: .brightness)
        let capability = store.capability(
            for: reconnectedKey,
            identity: identity,
            observedValue: nil
        )

        XCTAssertEqual(capability.status, .writeOnly)
        XCTAssertEqual(try XCTUnwrap(capability.value).normalized, 0.38, accuracy: 0.0001)
        XCTAssertEqual(capability.value?.rawCurrent, 38)
    }

    func testObservedBrightnessOverridesRememberedBrightness() throws {
        let memory = InMemoryDisplayBrightnessMemory()
        let identity = DisplayBrightnessMemoryIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0xA419,
            serialNumber: 123_456
        )
        memory.save(0.38, for: identity)
        var store = DisplayControlValueStore(brightnessMemory: memory)
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        let observed = DisplayControlValue(
            kind: .brightness,
            timestamp: Date(),
            rawCurrent: 62,
            rawMinimum: 0,
            rawMaximum: 100,
            normalized: 0.62
        )

        let capability = store.capability(
            for: key,
            identity: identity,
            observedValue: observed
        )

        XCTAssertEqual(capability.status, .available)
        XCTAssertEqual(try XCTUnwrap(capability.value).normalized, 0.62, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(memory.load(for: identity)), 0.62, accuracy: 0.0001)
    }

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
        XCTAssertTrue(store.shouldWrite(raw, for: key, force: true))
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

    func testInvalidationClearsSelectedRuntimeValuesButPreservesBrightnessMemory() throws {
        let memory = InMemoryDisplayBrightnessMemory()
        let identity = DisplayBrightnessMemoryIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0xA419,
            serialNumber: 123_456
        )
        var store = DisplayControlValueStore(brightnessMemory: memory)
        let brightnessKey = DisplayControlValueKey(
            displayID: displayID,
            kind: .brightness
        )
        let volumeKey = DisplayControlValueKey(
            displayID: displayID,
            kind: .volume
        )
        store.recordSuccessfulWrite(
            38,
            normalized: 0.38,
            for: brightnessKey,
            identity: identity
        )
        store.recordSuccessfulWrite(24, normalized: 0.24, for: volumeKey)

        store.invalidate(displayID: displayID, kinds: [.brightness, .contrast])

        XCTAssertTrue(store.shouldWrite(38, for: brightnessKey))
        XCTAssertFalse(store.shouldWrite(24, for: volumeKey))
        XCTAssertEqual(store.value(for: brightnessKey).rawCurrent, 100)
        XCTAssertEqual(store.value(for: volumeKey).rawCurrent, 24)
        XCTAssertEqual(try XCTUnwrap(memory.load(for: identity)), 0.38, accuracy: 0.0001)
    }
}

final class DarwinDisplayControlValueDecodingTests: XCTestCase {
    func testCancelledQueuedWorkCompletesBeforeBlockedQueueResumes() async {
        let queue = DispatchQueue(label: "test.display-control.cancelled-work")
        let releaseBlocker = DispatchSemaphore(value: 0)
        let blockerStarted = expectation(description: "queue blocker started")
        queue.async {
            blockerStarted.fulfill()
            releaseBlocker.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 1)

        let enqueued = expectation(description: "cancellable work enqueued")
        let didRun = LockedFlag()
        let task = Task {
            try await queue.asyncCancellable(onEnqueued: {
                enqueued.fulfill()
            }) {
                didRun.set()
                return 42
            }
        }
        await fulfillment(of: [enqueued], timeout: 1)

        let cancellationObserved = expectation(description: "cancellation observed before queue resumes")
        task.cancel()
        let resultTask = Task { () -> Bool in
            defer { cancellationObserved.fulfill() }
            do {
                _ = try await task.value
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await fulfillment(of: [cancellationObserved], timeout: 0.2)
        XCTAssertFalse(didRun.value)
        releaseBlocker.signal()
        let wasCancelled = await resultTask.value
        XCTAssertTrue(wasCancelled)
        queue.sync {}
        XCTAssertFalse(didRun.value)
    }

    func testCancelledQueuedWorkReleasesCapturesBeforeQueueResumes() async {
        let queue = DispatchQueue(label: "test.display-control.cancelled-captures")
        let releaseBlocker = DispatchSemaphore(value: 0)
        let blockerStarted = expectation(description: "capture queue blocker started")
        queue.async {
            blockerStarted.fulfill()
            releaseBlocker.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 1)

        var token: CancellationLifetimeToken? = CancellationLifetimeToken()
        weak let weakToken = token
        let enqueued = expectation(description: "capturing work enqueued")
        do {
            let task = Task { [capturedToken = token] in
                try await queue.asyncCancellable(onEnqueued: {
                    enqueued.fulfill()
                }) {
                    withExtendedLifetime(capturedToken) {}
                    return 42
                }
            }
            await fulfillment(of: [enqueued], timeout: 1)
            token = nil
            task.cancel()
            _ = try? await task.value
        }

        XCTAssertNil(weakToken)
        releaseBlocker.signal()
        queue.sync {}
    }

    func testContinuousControlPreservesReportedSixteenBitRange() throws {
        let value = try DarwinDisplayControlProvider.decodeValue(
            kind: .brightness,
            read: DDCReadResult(current: 128, maximum: 255)
        )

        XCTAssertEqual(value.rawCurrent, 128)
        XCTAssertEqual(value.rawMinimum, 0)
        XCTAssertEqual(value.rawMaximum, 255)
        XCTAssertEqual(value.normalized, 128.0 / 255.0, accuracy: 0.0001)

        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: 42, kind: .brightness)
        store.recordObserved(value, for: key)
        XCTAssertEqual(try store.rawValue(for: key, normalized: 0.5), 128)
    }

    func testContinuousControlRejectsZeroMaximum() {
        XCTAssertThrowsError(
            try DarwinDisplayControlProvider.decodeValue(
                kind: .brightness,
                read: DDCReadResult(current: 0, maximum: 0)
            )
        ) { error in
            guard case DisplayControlError.invalidRange(minimum: 0, maximum: 0) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testContinuousControlRejectsSentinelMaximum() {
        XCTAssertThrowsError(
            try DarwinDisplayControlProvider.decodeValue(
                kind: .brightness,
                read: DDCReadResult(current: 128, maximum: .max)
            )
        ) { error in
            guard case DisplayControlError.invalidRange(minimum: 0, maximum: .max) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMuteDecodingKeepsDDCSemantics() throws {
        let muted = try DarwinDisplayControlProvider.decodeValue(
            kind: .mute,
            read: DDCReadResult(current: 1, maximum: 255)
        )
        let unmuted = try DarwinDisplayControlProvider.decodeValue(
            kind: .mute,
            read: DDCReadResult(current: 2, maximum: 255)
        )

        XCTAssertEqual(muted.rawCurrent, 1)
        XCTAssertEqual(muted.rawMaximum, 2)
        XCTAssertEqual(muted.normalized, 1)
        XCTAssertEqual(unmuted.rawCurrent, 2)
        XCTAssertEqual(unmuted.rawMaximum, 2)
        XCTAssertEqual(unmuted.normalized, 0)
    }
}

private final class CancellationLifetimeToken {}

private final class LockedFlag {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class InMemoryDisplayBrightnessMemory: DisplayBrightnessRemembering {
    private var values: [DisplayBrightnessMemoryIdentity: Double] = [:]

    func load(for identity: DisplayBrightnessMemoryIdentity) -> Double? {
        values[identity]
    }

    func save(_ normalizedValue: Double, for identity: DisplayBrightnessMemoryIdentity) {
        values[identity] = normalizedValue
    }
}
