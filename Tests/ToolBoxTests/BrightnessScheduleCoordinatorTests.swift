import Combine
import CoreGraphics
import XCTest
@testable import ToolBoxCore

@MainActor
final class BrightnessScheduleCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var storeKey: String!

    override func setUp() {
        super.setUp()
        storeKey = "test.schedule.coordinator.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: storeKey)
        defaults.removePersistentDomain(forName: storeKey)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: storeKey)
        defaults = nil
        storeKey = nil
        super.tearDown()
    }

    func testDisabledStartWritesNothing() async {
        let harness = makeHarness(displayIDs: [1], enabled: false, hour: 12)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        await Task.yield()
        let writes = await harness.provider.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(harness.coordinator.runtimeState, .disabled)
    }

    func testEnabledStartAppliesCurrentSegmentToEligibleDisplays() async throws {
        // 08:00 is 80% in the default schedule (07:00-09:00).
        let harness = try makeEnabledHarness(displayIDs: [11, 12], hour: 8)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        try await waitForWrite(provider: harness.provider, value: 0.8)

        let writes = await harness.provider.recordedWrites().filter { $0.0 == .brightness }
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.allSatisfy { abs($0.1 - 0.8) < 0.0001 })
        XCTAssertTrue(writes.allSatisfy { $0.2.contains(.force) })

        if case let .active(percent, count, _, overrides) = harness.coordinator.runtimeState {
            XCTAssertEqual(percent, 80)
            XCTAssertEqual(count, 2)
            XCTAssertEqual(overrides, 0)
        } else {
            XCTFail("Expected active runtime state")
        }
    }

    func testIgnoresBuiltInAndNonWritableDisplays() async throws {
        let displays = [
            makeDisplay(id: 1, isBuiltIn: true, writable: true),
            makeDisplay(id: 2, isBuiltIn: false, writable: false),
            makeDisplay(id: 3, isBuiltIn: false, writable: true)
        ]
        let snapshot = DisplayControlSnapshot(timestamp: Date(), displays: displays)
        let harness = try makeEnabledHarness(
            displayIDs: [],
            hour: 8,
            snapshot: snapshot
        )
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        try await waitForWrite(provider: harness.provider, value: 0.8)

        let writes = await harness.provider.recordedWrites().filter { $0.0 == .brightness }
        XCTAssertEqual(writes.count, 1)
    }

    func testBoundaryTimerAppliesNextSegment() async throws {
        let harness = try makeEnabledHarness(displayIDs: [5], hour: 8, minute: 59)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        try await waitForWrite(provider: harness.provider, value: 0.8)

        let boundary = harness.calendar.date(
            from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0)
        )!
        harness.clock.advance(to: boundary)
        harness.clock.fireIfDue()

        try await waitForWrite(provider: harness.provider, value: 0.6)

        let values = await harness.provider.recordedWrites()
            .filter { $0.0 == .brightness }
            .map(\.1)
        XCTAssertEqual(values.last ?? -1, 0.6, accuracy: 0.0001)
    }

    func testManualOverrideIsPerDisplayUntilBoundary() async throws {
        let harness = try makeEnabledHarness(displayIDs: [21, 22], hour: 8)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        try await waitForWrite(provider: harness.provider, value: 0.8)

        harness.service.writeBrightness(
            displayID: 21,
            normalizedValue: 0.2,
            smooth: false,
            policy: .manual
        )
        try await waitForWrite(provider: harness.provider, value: 0.2)

        if case let .active(_, _, _, overrideCount) = harness.coordinator.runtimeState {
            XCTAssertEqual(overrideCount, 1)
        } else {
            XCTFail("Expected active state with override")
        }

        // Same-signature snapshot should not rewrite scheduled displays.
        harness.service.setSnapshotForTesting(
            makeSnapshot(displayIDs: [21, 22], timestamp: Date().addingTimeInterval(1))
        )

        let boundary = harness.calendar.date(
            from: DateComponents(year: 2024, month: 6, day: 1, hour: 9)
        )!
        harness.clock.advance(to: boundary)
        harness.clock.fireIfDue()
        try await waitForWrite(provider: harness.provider, value: 0.6)

        let brightnessValues = await harness.provider.recordedWrites()
            .filter { $0.0 == .brightness }
            .map(\.1)
        let trailing = brightnessValues.suffix(2)
        XCTAssertEqual(trailing.count, 2)
        XCTAssertTrue(trailing.allSatisfy { abs($0 - 0.6) < 0.0001 })

        if case let .active(percent, _, _, overrideCount) = harness.coordinator.runtimeState {
            XCTAssertEqual(percent, 60)
            XCTAssertEqual(overrideCount, 0)
        } else {
            XCTFail("Expected active state after boundary")
        }
    }

    func testManualOverrideSurvivesSleepWakeTopologyReset() async throws {
        let harness = try makeEnabledHarness(displayIDs: [31], hour: 8)
        let coordinator = BrightnessScheduleCoordinator(
            service: harness.service,
            store: BrightnessScheduleStore(defaults: defaults, key: storeKey),
            clock: harness.clock,
            observesSystemEvents: true
        )
        coordinator.start()
        defer { coordinator.stop() }

        try await waitForWrite(provider: harness.provider, value: 0.8)
        harness.service.writeBrightness(
            displayID: 31,
            normalizedValue: 0.2,
            smooth: false,
            policy: .manual
        )
        try await waitForWrite(provider: harness.provider, value: 0.2)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        harness.service.setSnapshotForTesting(
            DisplayControlSnapshot(timestamp: Date(), displays: [])
        )

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        harness.service.setSnapshotForTesting(
            makeSnapshot(displayIDs: [31], timestamp: Date().addingTimeInterval(1))
        )
        try await waitForWrite(provider: harness.provider, value: 0.2)

        let brightnessValues = await harness.provider.recordedWrites()
            .filter { $0.0 == .brightness }
            .map(\.1)
        XCTAssertEqual(brightnessValues.last ?? -1, 0.2, accuracy: 0.0001)
    }

    func testCommitDisableCancelsWritesAndTimer() async throws {
        let harness = try makeEnabledHarness(displayIDs: [9], hour: 8)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        try await waitForWrite(provider: harness.provider, value: 0.8)
        XCTAssertNotNil(harness.clock.scheduledDate)

        try harness.coordinator.commit(
            BrightnessScheduleConfiguration(isEnabled: false, schedule: .default)
        )
        XCTAssertNil(harness.clock.scheduledDate)
        XCTAssertEqual(harness.coordinator.runtimeState, .disabled)
    }

    // MARK: - Helpers

    private struct Harness {
        var provider: RecordingDisplayControlProvider
        var service: DisplayControlService
        var clock: TestBrightnessScheduleClock
        var retryClock: TestBrightnessScheduleClock
        var coordinator: BrightnessScheduleCoordinator
        var calendar: Calendar
    }

    private func makeEnabledHarness(
        displayIDs: [CGDirectDisplayID],
        hour: Int,
        minute: Int = 0,
        snapshot: DisplayControlSnapshot? = nil,
        observesSystemEvents: Bool = false
    ) throws -> Harness {
        var harness = makeHarness(
            displayIDs: displayIDs,
            enabled: true,
            hour: hour,
            minute: minute,
            snapshot: snapshot,
            observesSystemEvents: observesSystemEvents
        )
        try harness.coordinator.commit(
            BrightnessScheduleConfiguration(isEnabled: true, schedule: .default)
        )
        // commit before start would no-op reconcile; rebuild after save for clean start state.
        let store = BrightnessScheduleStore(defaults: defaults, key: storeKey)
        harness.coordinator = BrightnessScheduleCoordinator(
            service: harness.service,
            store: store,
            clock: harness.clock,
            retryClock: harness.retryClock,
            observesSystemEvents: observesSystemEvents
        )
        return harness
    }

    private func makeHarness(
        displayIDs: [CGDirectDisplayID],
        enabled: Bool,
        hour: Int,
        minute: Int = 0,
        snapshot: DisplayControlSnapshot? = nil,
        observesSystemEvents: Bool = false
    ) -> Harness {
        let resolvedSnapshot = snapshot ?? makeSnapshot(displayIDs: displayIDs)
        let provider = RecordingDisplayControlProvider(snapshot: resolvedSnapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(resolvedSnapshot)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2024, month: 6, day: 1, hour: hour, minute: minute)
        )!
        let clock = TestBrightnessScheduleClock(now: now, calendar: calendar)
        let retryClock = TestBrightnessScheduleClock(now: now, calendar: calendar)

        if enabled {
            // Store may already hold config from makeEnabledHarness; default is fine.
        }

        let store = BrightnessScheduleStore(defaults: defaults, key: storeKey)
        let coordinator = BrightnessScheduleCoordinator(
            service: service,
            store: store,
            clock: clock,
            retryClock: retryClock,
            observesSystemEvents: observesSystemEvents
        )

        return Harness(
            provider: provider,
            service: service,
            clock: clock,
            retryClock: retryClock,
            coordinator: coordinator,
            calendar: calendar
        )
    }

    private func waitForWrite(
        provider: RecordingDisplayControlProvider,
        value: Double,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let writes = await provider.recordedWrites()
            if writes.contains(where: { $0.0 == .brightness && abs($0.1 - value) < 0.0001 }) {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let writes = await provider.recordedWrites()
        XCTFail("Timed out waiting for brightness \(value). Writes: \(writes)")
    }

    private func makeSnapshot(
        displayIDs: [CGDirectDisplayID],
        timestamp: Date = Date()
    ) -> DisplayControlSnapshot {
        DisplayControlSnapshot(
            timestamp: timestamp,
            displays: displayIDs.map { makeDisplay(id: $0, isBuiltIn: false, writable: true) }
        )
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        isBuiltIn: Bool,
        writable: Bool
    ) -> DisplayControlDisplay {
        DisplayControlDisplay(
            id: id,
            name: "Display \(id)",
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: id,
            isBuiltIn: isBuiltIn,
            isVirtual: false,
            supportsHardwareDDC: !isBuiltIn,
            backendName: "test",
            unavailableReason: nil,
            controls: [
                DisplayControlCapability(
                    kind: .brightness,
                    status: writable ? .writeOnly : .unsupported,
                    value: DisplayControlValue(
                        kind: .brightness,
                        timestamp: Date(),
                        rawCurrent: 50,
                        rawMinimum: 0,
                        rawMaximum: 100,
                        normalized: 0.5
                    ),
                    unavailableReason: writable ? nil : "unsupported"
                )
            ]
        )
    }
}

extension BrightnessScheduleCoordinatorTests {
    /// A scheduled write failure must be retried within the same segment:
    /// the failure clears the recorded signature and schedules a backoff
    /// retry; firing it rewrites the display.
    func testScheduledWriteFailureIsRetriedWithinSegment() async throws {
        let harness = try makeEnabledHarness(displayIDs: [21], hour: 12, minute: 30)
        await harness.provider.failWrites(kind: .brightness)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        // The initial scheduled write attempt fails.
        try await waitForWriteCount(harness.provider, kind: .brightness, count: 1)

        // Failure handling runs async; wait for the retry timer to appear.
        try await waitForRetryScheduled(harness.retryClock)

        // Advance past the 2s backoff and fire the retry.
        let fireDate = try XCTUnwrap(harness.retryClock.scheduledDate)
        harness.clock.advance(to: fireDate)
        harness.retryClock.advance(to: fireDate)
        harness.retryClock.fireIfDue()

        try await waitForWriteCount(harness.provider, kind: .brightness, count: 2)
    }

    func testScheduledWriteFailureGivesUpAfterBudget() async throws {
        let harness = try makeEnabledHarness(displayIDs: [21], hour: 12, minute: 30)
        await harness.provider.failWrites(kind: .brightness)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }

        try await waitForWriteCount(harness.provider, kind: .brightness, count: 1)

        // Fire every scheduled retry until the budget is exhausted and no
        // new timer appears.
        var fired = 0
        while fired < BrightnessScheduleCoordinator.retryDelays.count * 3 {
            guard await waitForRetryScheduled(harness.retryClock, timeout: 0.3) else {
                break
            }
            let fireDate = try XCTUnwrap(harness.retryClock.scheduledDate)
            harness.clock.advance(to: fireDate)
            harness.retryClock.advance(to: fireDate)
            harness.retryClock.fireIfDue()
            fired += 1
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertLessThanOrEqual(fired, BrightnessScheduleCoordinator.retryDelays.count)

        // Far-future firing triggers nothing new.
        let countBefore = await harness.provider.recordedWrites().filter { $0.0 == .brightness }.count
        let far = harness.clock.now.addingTimeInterval(600)
        harness.clock.advance(to: far)
        harness.retryClock.advance(to: far)
        harness.retryClock.fireIfDue()
        try await Task.sleep(nanoseconds: 100_000_000)
        let countAfter = await harness.provider.recordedWrites().filter { $0.0 == .brightness }.count
        XCTAssertEqual(countBefore, countAfter)
    }

    /// PLAN: on clock/zone changes, expiry of still-valid same-segment
    /// overrides is recalculated with the new calendar.
    func testClockChangeRecalculatesOverrideExpiry() async throws {
        let harness = try makeEnabledHarness(displayIDs: [21], hour: 12, minute: 30, observesSystemEvents: true)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }
        try await waitForWrite(provider: harness.provider, value: 0.6)

        // Manual override inside the 09:00-18:00 segment (60%).
        harness.service.writeBrightness(displayID: 21, normalizedValue: 0.4, smooth: false)
        try await waitForWrite(provider: harness.provider, value: 0.4)
        try await waitForOverrideCount(harness.coordinator, atLeast: 1)

        // Switch to UTC+2: 12:30 GMT = 14:30 local, same segment; the next
        // boundary moves from 18:00 GMT to 16:00 GMT.
        var shifted = harness.calendar
        shifted.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        harness.clock.calendar = shifted

        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await Task.yield()

        // Advance past the NEW expiry (16:00 GMT) but before the old (18:00).
        let afterNewExpiry = harness.calendar.date(
            from: DateComponents(year: 2024, month: 6, day: 1, hour: 16, minute: 30)
        )!
        harness.clock.advance(to: afterNewExpiry)

        // A snapshot reconcile must now treat the override as expired.
        var topology = makeSnapshot(displayIDs: [21])
        topology.displays[0].vendorNumber = 99
        harness.service.setSnapshotForTesting(topology)

        try await waitForOverrideCount(harness.coordinator, exactly: 0)
    }

    /// A transient refresh failure keeps the last valid snapshot; overrides
    /// and the active runtime state must survive instead of being wiped as
    /// if all displays had been removed.
    func testRefreshFailureKeepsOverridesAndActiveState() async throws {
        let harness = try makeEnabledHarness(displayIDs: [21], hour: 12, minute: 30)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }
        try await waitForWrite(provider: harness.provider, value: 0.6)

        harness.service.writeBrightness(displayID: 21, normalizedValue: 0.4, smooth: false)
        try await waitForWrite(provider: harness.provider, value: 0.4)
        try await waitForOverrideCount(harness.coordinator, atLeast: 1)

        await harness.provider.blockNextSnapshot()
        harness.service.refresh()
        await harness.provider.waitUntilSnapshotIsBlocked()
        await harness.provider.releaseBlockedSnapshotWithFailure()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNotNil(harness.service.lastRefreshError)
        try await waitForOverrideCount(harness.coordinator, exactly: 1)
        guard case .active = harness.coordinator.runtimeState else {
            XCTFail("Expected active runtime state after transient refresh failure")
            return
        }
    }

    /// Post-wake settling keys off the first non-empty snapshot, not a
    /// wall-clock comparison, so a rolled-back or skewed clock cannot leave
    /// the coordinator suspended forever.
    func testWakeSettlesOnFirstNonEmptySnapshotEvenWithSkewedClock() async throws {
        let harness = try makeEnabledHarness(displayIDs: [21], hour: 12, minute: 30, observesSystemEvents: true)
        harness.coordinator.start()
        defer { harness.coordinator.stop() }
        try await waitForWrite(provider: harness.provider, value: 0.6)
        let writesBeforeWake = await harness.provider.recordedWrites().filter { $0.0 == .brightness }.count

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        // Skew the clock far past real wall-clock time so any
        // timestamp-based comparison would fail.
        let skewed = harness.calendar.date(
            from: DateComponents(year: 2030, month: 1, day: 1)
        )!
        harness.clock.advance(to: skewed)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }

        // Intermediate empty topology during sleep/wake must not settle.
        harness.service.setSnapshotForTesting(DisplayControlSnapshot(timestamp: Date(), displays: []))
        for _ in 0..<20 { await Task.yield() }
        guard case .active = harness.coordinator.runtimeState else {
            XCTFail("Expected active runtime state after empty intermediate snapshot")
            return
        }

        // First non-empty snapshot settles the wake and re-applies values.
        harness.service.setSnapshotForTesting(makeSnapshot(displayIDs: [21]))
        try await waitForWriteCount(harness.provider, kind: .brightness, count: writesBeforeWake + 1)
        guard case .active = harness.coordinator.runtimeState else {
            XCTFail("Expected active runtime state after wake settle")
            return
        }
    }

    // MARK: - Helpers

    private func waitForWriteCount(
        _ provider: RecordingDisplayControlProvider,
        kind: DisplayControlKind,
        count: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let writes = await provider.recordedWrites()
            if writes.filter({ $0.0 == kind }).count >= count {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let writes = await provider.recordedWrites()
        XCTFail("Timed out waiting for \(count) \(kind) writes. Writes: \(writes)")
    }

    private func waitForRetryScheduled(
        _ clock: TestBrightnessScheduleClock,
        timeout: TimeInterval = 1.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clock.scheduledDate != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func waitForOverrideCount(
        _ coordinator: BrightnessScheduleCoordinator,
        atLeast expected: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case let .active(_, _, _, overrideCount) = coordinator.runtimeState,
               overrideCount >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for override count >= \(expected); state: \(coordinator.runtimeState)")
    }

    private func waitForOverrideCount(
        _ coordinator: BrightnessScheduleCoordinator,
        exactly expected: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case let .active(_, _, _, overrideCount) = coordinator.runtimeState,
               overrideCount == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for override count == \(expected); state: \(coordinator.runtimeState)")
    }
}
