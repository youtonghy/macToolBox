import Combine
import CoreGraphics
import XCTest
@testable import ToolBox

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
        var coordinator: BrightnessScheduleCoordinator
        var calendar: Calendar
    }

    private func makeEnabledHarness(
        displayIDs: [CGDirectDisplayID],
        hour: Int,
        minute: Int = 0,
        snapshot: DisplayControlSnapshot? = nil
    ) throws -> Harness {
        var harness = makeHarness(
            displayIDs: displayIDs,
            enabled: true,
            hour: hour,
            minute: minute,
            snapshot: snapshot
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
            observesSystemEvents: false
        )
        return harness
    }

    private func makeHarness(
        displayIDs: [CGDirectDisplayID],
        enabled: Bool,
        hour: Int,
        minute: Int = 0,
        snapshot: DisplayControlSnapshot? = nil
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

        if enabled {
            // Store may already hold config from makeEnabledHarness; default is fine.
        }

        let store = BrightnessScheduleStore(defaults: defaults, key: storeKey)
        let coordinator = BrightnessScheduleCoordinator(
            service: service,
            store: store,
            clock: clock,
            observesSystemEvents: false
        )

        return Harness(
            provider: provider,
            service: service,
            clock: clock,
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
