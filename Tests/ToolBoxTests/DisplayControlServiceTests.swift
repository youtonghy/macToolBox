import CoreGraphics
import XCTest
@testable import ToolBox

private enum SnapshotTestError: Error {
    case forced
}

actor ControlledDisplayControlLifecycleSleeper: DisplayControlLifecycleSleeper {
    private var pendingSleep: CheckedContinuation<Void, Error>?
    private var sleepStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepCancelledWaiters: [CheckedContinuation<Void, Never>] = []
    private var didCancelSleep = false
    private var cancellationRequested = false

    func sleep(nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellationRequested {
                    cancellationRequested = false
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingSleep = continuation
                let waiters = sleepStartedWaiters
                sleepStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelPendingSleep() }
        }
    }

    func waitUntilSleepStarts() async {
        if pendingSleep != nil {
            return
        }
        await withCheckedContinuation { continuation in
            sleepStartedWaiters.append(continuation)
        }
    }

    func waitUntilSleepIsCancelled() async {
        if didCancelSleep {
            return
        }
        await withCheckedContinuation { continuation in
            sleepCancelledWaiters.append(continuation)
        }
    }

    private func cancelPendingSleep() {
        guard let pendingSleep else {
            cancellationRequested = true
            return
        }
        self.pendingSleep = nil
        didCancelSleep = true
        pendingSleep.resume(throwing: CancellationError())
        let waiters = sleepCancelledWaiters
        sleepCancelledWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

actor RecordingDisplayControlProvider: DisplayControlProviding {
    private struct WriteWaiter {
        var kind: DisplayControlKind
        var value: Double
        var continuation: CheckedContinuation<Void, Never>
    }

    private(set) var writes: [(DisplayControlKind, Double, DisplayControlWriteOptions)] = []
    private var readCount = 0
    private var shouldBlockFirstWrite = false
    private var firstWriteRelease: CheckedContinuation<Void, Never>?
    private var firstWriteStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiters: [WriteWaiter] = []
    private var snapshotCount = 0
    private var shouldBlockNextSnapshot = false
    private var blockedSnapshotRelease: CheckedContinuation<Void, Never>?
    private var blockedSnapshotStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var failReleasedSnapshot = false
    private let configuredSnapshot: DisplayControlSnapshot

    init(
        snapshot: DisplayControlSnapshot = DisplayControlSnapshot(
            timestamp: Date(),
            displays: []
        )
    ) {
        configuredSnapshot = snapshot
    }

    func blockFirstWrite() {
        shouldBlockFirstWrite = true
    }

    func waitUntilFirstWriteIsBlocked() async {
        if firstWriteRelease != nil {
            return
        }
        await withCheckedContinuation { continuation in
            firstWriteStartedWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }

    func waitUntilWrite(kind: DisplayControlKind, value: Double) async {
        if writes.contains(where: { $0.0 == kind && abs($0.1 - value) < 0.0001 }) {
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(WriteWaiter(kind: kind, value: value, continuation: continuation))
        }
    }

    func recordedWrites() -> [(DisplayControlKind, Double, DisplayControlWriteOptions)] {
        writes
    }

    func recordedReadCount() -> Int {
        readCount
    }

    func recordedSnapshotCount() -> Int {
        snapshotCount
    }

    func blockNextSnapshot() {
        shouldBlockNextSnapshot = true
    }

    func waitUntilSnapshotIsBlocked() async {
        if blockedSnapshotRelease != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedSnapshotStartedWaiters.append(continuation)
        }
    }

    func releaseBlockedSnapshotWithFailure() {
        failReleasedSnapshot = true
        blockedSnapshotRelease?.resume()
        blockedSnapshotRelease = nil
    }

    func snapshot() async throws -> DisplayControlSnapshot {
        snapshotCount += 1
        if shouldBlockNextSnapshot {
            shouldBlockNextSnapshot = false
            await withCheckedContinuation { continuation in
                blockedSnapshotRelease = continuation
                let waiters = blockedSnapshotStartedWaiters
                blockedSnapshotStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if failReleasedSnapshot {
            failReleasedSnapshot = false
            throw SnapshotTestError.forced
        }
        return configuredSnapshot
    }

    func refresh() async throws {}

    func readValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind
    ) async throws -> DisplayControlValue {
        readCount += 1
        throw DisplayControlError.readFailed(displayID, kind)
    }

    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double,
        options: DisplayControlWriteOptions
    ) async throws -> DisplayControlValue {
        writes.append((kind, normalizedValue, options))
        resumeMatchingWriteWaiters(kind: kind, value: normalizedValue)

        if shouldBlockFirstWrite && writes.count == 1 {
            await withCheckedContinuation { continuation in
                firstWriteRelease = continuation
                let waiters = firstWriteStartedWaiters
                firstWriteStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        return DisplayControlValue(
            kind: kind,
            timestamp: Date(),
            rawCurrent: UInt16((normalizedValue * 100).rounded()),
            rawMinimum: 0,
            rawMaximum: 100,
            normalized: normalizedValue
        )
    }

    private func resumeMatchingWriteWaiters(kind: DisplayControlKind, value: Double) {
        var remaining: [WriteWaiter] = []
        for waiter in writeWaiters {
            if waiter.kind == kind && abs(waiter.value - value) < 0.0001 {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        writeWaiters = remaining
    }
}

@MainActor
final class DisplayControlServiceTests: XCTestCase {
    func testReconfigurationBurstCoalescesLifecycleRefresh() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(
            provider: provider,
            timing: .immediateForTests,
            observesSystemEvents: false
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let initialCount = await provider.recordedSnapshotCount()
        service.handleDisplayReconfiguration()
        service.handleDisplayReconfiguration()
        service.handleDisplayReconfiguration()
        await waitForSnapshotCount(provider, atLeast: initialCount + 1)

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount + 1)
    }

    func testSleepCancelsQueuedReconfigurationRefresh() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(
            provider: provider,
            timing: .immediateForTests,
            observesSystemEvents: false
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let initialCount = await provider.recordedSnapshotCount()
        service.handleDisplayReconfiguration()
        service.suspendForSleep()
        await yieldForPendingTasks()

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount)
    }

    func testWakeSettlingIgnoresReconfigurationUntilWakeRefresh() async {
        let provider = RecordingDisplayControlProvider()
        let timing = DisplayControlTiming(
            brightnessFrameDelayNanos: 0,
            refreshDebounceNanos: 0,
            reconfigurationRefreshDelayNanos: 0,
            wakeRefreshDelayNanos: 60_000_000_000
        )
        let service = DisplayControlService(
            provider: provider,
            timing: timing,
            observesSystemEvents: false
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let initialCount = await provider.recordedSnapshotCount()
        service.suspendForSleep()
        service.resumeAfterWake()
        service.handleDisplayReconfiguration()
        await yieldForPendingTasks()

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount)
    }

    func testImmediateWakeRefreshPublishesOnce() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(
            provider: provider,
            timing: .immediateForTests,
            observesSystemEvents: false
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let initialCount = await provider.recordedSnapshotCount()
        service.suspendForSleep()
        service.resumeAfterWake()
        await waitForSnapshotCount(provider, atLeast: initialCount + 1)

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount + 1)
    }

    func testSecondSleepCancelsQueuedWakeRefresh() async {
        let provider = RecordingDisplayControlProvider()
        let sleeper = ControlledDisplayControlLifecycleSleeper()
        let timing = DisplayControlTiming(
            brightnessFrameDelayNanos: 0,
            refreshDebounceNanos: 0,
            reconfigurationRefreshDelayNanos: 0,
            wakeRefreshDelayNanos: 1
        )
        let service = DisplayControlService(
            provider: provider,
            timing: timing,
            observesSystemEvents: false,
            lifecycleSleeper: sleeper
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let initialCount = await provider.recordedSnapshotCount()
        service.suspendForSleep()
        service.resumeAfterWake()
        await sleeper.waitUntilSleepStarts()
        service.suspendForSleep()
        await sleeper.waitUntilSleepIsCancelled()

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount)
    }

    func testStopThenStartRestoresRefreshAfterSleep() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(
            provider: provider,
            timing: .immediateForTests,
            observesSystemEvents: false
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let initialCount = await provider.recordedSnapshotCount()
        service.suspendForSleep()
        service.stop()
        service.start()
        await waitForSnapshotCount(provider, atLeast: initialCount + 1)

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount + 1)
    }

    func testReconfigurationFromPreviousSessionIsIgnoredAfterRestart() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(
            provider: provider,
            timing: .immediateForTests,
            observesSystemEvents: false
        )
        service.start()
        defer { service.stop() }

        await waitForSnapshotCount(provider, atLeast: 1)
        let firstSessionID: UInt64 = 1
        service.stop()
        service.start()
        await waitForSnapshotCount(provider, atLeast: 2)
        let initialCount = await provider.recordedSnapshotCount()
        service.handleDisplayReconfiguration(sessionID: firstSessionID)
        await yieldForPendingTasks()

        let finalCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(finalCount, initialCount)
    }

    func testCancelledRefreshFailureDoesNotClearExistingSnapshot() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockNextSnapshot()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        let expectedTimestamp = Date(timeIntervalSinceReferenceDate: 42)
        service.setSnapshotForTesting(
            DisplayControlSnapshot(timestamp: expectedTimestamp, displays: [])
        )

        service.refresh()
        await provider.waitUntilSnapshotIsBlocked()
        service.stop()
        await provider.releaseBlockedSnapshotWithFailure()
        await yieldForPendingTasks()

        XCTAssertEqual(service.snapshot.timestamp, expectedTimestamp)
    }

    func testContrastBurstKeepsOnlyInFlightAndLatestTarget() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.2)
        await provider.waitUntilFirstWriteIsBlocked()
        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.4)
        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.8)
        await provider.releaseFirstWrite()
        await provider.waitUntilWrite(kind: .contrast, value: 0.8)

        let values = await provider.recordedWrites().map(\.1)
        XCTAssertEqual(values, [0.2, 0.8])
    }

    func testWriteOnlyBrightnessConvergesOnLatestDirectTarget() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.writeBrightness(displayID: 42, normalizedValue: 0.3)
        service.writeBrightness(displayID: 42, normalizedValue: 0.7)
        await provider.waitUntilWrite(kind: .brightness, value: 0.7)

        let values = await provider.recordedWrites()
            .filter { $0.0 == .brightness }
            .map(\.1)
        XCTAssertEqual(values.last ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(values.count, 2)
    }

    func testPositiveVolumeWritesUnmuteThenLatestVolume() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.setVolume(displayID: 42, normalizedValue: 0.2)
        service.setVolume(displayID: 42, normalizedValue: 0.6)
        await provider.waitUntilWrite(kind: .volume, value: 0.6)

        let writes = await provider.recordedWrites()
        XCTAssertEqual(writes.suffix(2).map(\.0), [.mute, .volume])
        XCTAssertEqual(writes.last?.1, 0.6)
    }

    func testZeroVolumeWritesVolumeThenMute() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.setVolume(displayID: 42, normalizedValue: 0)
        await provider.waitUntilWrite(kind: .mute, value: 1)

        let writes = await provider.recordedWrites()
        XCTAssertEqual(writes.map(\.0), [.volume, .mute])
    }

    func testStepUsesLatestScheduledValueWithoutReadingHardware() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.2)
        await provider.waitUntilFirstWriteIsBlocked()
        service.stepValue(displayID: 42, kind: .contrast, delta: 0.1)
        await provider.releaseFirstWrite()
        await provider.waitUntilWrite(kind: .contrast, value: 0.3)

        let readCount = await provider.recordedReadCount()
        let values = await provider.recordedWrites().map(\.1)
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], 0.2, accuracy: 0.0001)
        XCTAssertEqual(values[1], 0.3, accuracy: 0.0001)
    }

    func testScheduledBrightnessWritesForceAndDoesNotPublishManualEvent() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        var manualEvents: [(CGDirectDisplayID, Double)] = []
        let cancellable = service.manualBrightnessWrites.sink { manualEvents.append(($0.displayID, $0.normalizedValue)) }
        defer { cancellable.cancel() }

        service.writeBrightness(
            displayID: 42,
            normalizedValue: 0.55,
            smooth: false,
            policy: .scheduled
        )
        await provider.waitUntilWrite(kind: .brightness, value: 0.55)

        let writes = await provider.recordedWrites().filter { $0.0 == .brightness }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].1, 0.55, accuracy: 0.0001)
        XCTAssertTrue(writes[0].2.contains(.force))
        XCTAssertTrue(manualEvents.isEmpty)
    }

    func testManualBrightnessPublishesQuantizedEventWithoutForce() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        var manualEvents: [(CGDirectDisplayID, Double)] = []
        let cancellable = service.manualBrightnessWrites.sink { manualEvents.append(($0.displayID, $0.normalizedValue)) }
        defer { cancellable.cancel() }

        service.writeBrightness(displayID: 7, normalizedValue: 0.42, smooth: false)
        await provider.waitUntilWrite(kind: .brightness, value: 0.42)

        let writes = await provider.recordedWrites().filter { $0.0 == .brightness }
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(writes[0].2.contains(.force))
        XCTAssertEqual(manualEvents.count, 1)
        XCTAssertEqual(manualEvents[0].0, 7)
        XCTAssertEqual(manualEvents[0].1, 0.42, accuracy: 0.0001)
    }

    private func waitForSnapshotCount(
        _ provider: RecordingDisplayControlProvider,
        atLeast expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await provider.recordedSnapshotCount() >= expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(expectedCount) snapshots", file: file, line: line)
    }

    private func yieldForPendingTasks() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }
}
