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
    private(set) var presetWrites: [UInt8] = []
    private var shouldBlockFirstPresetWrite = false
    private var firstPresetWriteRelease: CheckedContinuation<Void, Never>?
    private var firstPresetWriteStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var presetWriteCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var failingPresetValues = Set<UInt8>()

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

    func blockFirstPresetWrite() {
        shouldBlockFirstPresetWrite = true
    }

    func failPresetWrite(rawValue: UInt8) {
        failingPresetValues.insert(rawValue)
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

    func waitUntilFirstPresetWriteIsBlocked() async {
        if firstPresetWriteRelease != nil {
            return
        }
        await withCheckedContinuation { continuation in
            firstPresetWriteStartedWaiters.append(continuation)
        }
    }

    func releaseFirstPresetWrite() {
        firstPresetWriteRelease?.resume()
        firstPresetWriteRelease = nil
    }

    func waitUntilPresetWriteCount(_ expectedCount: Int) async {
        if presetWrites.count >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            presetWriteCountWaiters.append((expectedCount, continuation))
        }
    }

    func recordedPresetWrites() -> [UInt8] {
        presetWrites
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

    func writeColorPreset(
        displayID: CGDirectDisplayID,
        rawValue: UInt8
    ) async throws -> DisplayColorPresetWriteResult {
        presetWrites.append(rawValue)
        resumePresetWriteCountWaiters()

        if shouldBlockFirstPresetWrite && presetWrites.count == 1 {
            await withCheckedContinuation { continuation in
                firstPresetWriteRelease = continuation
                let waiters = firstPresetWriteStartedWaiters
                firstPresetWriteStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        if failingPresetValues.remove(rawValue) != nil {
            throw DisplayColorPresetError.readbackFailed
        }
        return DisplayColorPresetWriteResult(
            displayID: displayID,
            requestedRawValue: rawValue,
            verifiedRawValue: rawValue,
            verifiedAt: Date()
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

    private func resumePresetWriteCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in presetWriteCountWaiters {
            if presetWrites.count >= expectedCount {
                continuation.resume()
            } else {
                remaining.append((expectedCount, continuation))
            }
        }
        presetWriteCountWaiters = remaining
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

    func testPresetBurstKeepsOnlyInFlightAndLatestValue() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        await provider.blockFirstPresetWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)

        service.setColorPreset(displayID: 42, rawValue: 0x0B)
        await provider.waitUntilFirstPresetWriteIsBlocked()
        service.setColorPreset(displayID: 42, rawValue: 0x41)
        service.setColorPreset(displayID: 42, rawValue: 0x0C)
        await provider.releaseFirstPresetWrite()
        await provider.waitUntilPresetWriteCount(2)

        let writes = await provider.recordedPresetWrites()
        XCTAssertEqual(writes, [0x0B, 0x0C])
        XCTAssertEqual(service.presentedColorPreset(displayID: 42), 0x0C)
    }

    func testPresetFailureRestoresLastVerifiedSelection() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        await provider.failPresetWrite(rawValue: 0x41)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)

        service.setColorPreset(displayID: 42, rawValue: 0x41)
        await provider.waitUntilPresetWriteCount(1)
        await yieldForPendingTasks()

        XCTAssertEqual(service.presentedColorPreset(displayID: 42), 0x0B)
        XCTAssertNotNil(service.colorPresetError(displayID: 42))
    }

    func testSleepCancelsPendingPresetWork() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        await provider.blockFirstPresetWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.start()
        defer { service.stop() }
        await waitForSnapshotCount(provider, atLeast: 1)

        service.setColorPreset(displayID: 42, rawValue: 0x41)
        await provider.waitUntilFirstPresetWriteIsBlocked()
        service.setColorPreset(displayID: 42, rawValue: 0x0C)
        service.suspendForSleep()
        await provider.releaseFirstPresetWrite()
        await yieldForPendingTasks()

        let writes = await provider.recordedPresetWrites()
        XCTAssertEqual(writes, [0x41])
        XCTAssertNil(service.presentedColorPreset(displayID: 42))
    }

    func testDisplayReconfigurationDropsPresetWorkForRemovedDisplay() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        await provider.blockFirstPresetWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)

        service.setColorPreset(displayID: 42, rawValue: 0x41)
        await provider.waitUntilFirstPresetWriteIsBlocked()
        service.setColorPreset(displayID: 42, rawValue: 0x0C)
        service.setSnapshotForTesting(DisplayControlSnapshot(timestamp: Date(), displays: []))
        await provider.releaseFirstPresetWrite()
        await yieldForPendingTasks()

        let writes = await provider.recordedPresetWrites()
        XCTAssertEqual(writes, [0x41])
        XCTAssertNil(service.presentedColorPreset(displayID: 42))
        XCTAssertNil(service.colorPresetError(displayID: 42))
    }

    func testPresetSuccessSchedulesOneSnapshotRefresh() async {
        let verifiedSnapshot = Self.makePresetSnapshot(currentRawValue: 0x41)
        let provider = RecordingDisplayControlProvider(snapshot: verifiedSnapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)

        service.setColorPreset(displayID: 42, rawValue: 0x41)
        await provider.waitUntilPresetWriteCount(1)
        await waitForSnapshotCount(provider, atLeast: 1)
        await yieldForPendingTasks()

        let snapshotCount = await provider.recordedSnapshotCount()
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(service.presentedColorPreset(displayID: 42), 0x41)
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

    private static let presetSnapshot = makePresetSnapshot(currentRawValue: 0x0B)

    private static func makePresetSnapshot(currentRawValue: UInt8) -> DisplayControlSnapshot {
        DisplayControlSnapshot(
            timestamp: Date(),
            displays: [
                DisplayControlDisplay(
                    id: 42,
                    name: "Preset Display",
                    vendorNumber: 1,
                    modelNumber: 2,
                    serialNumber: 3,
                    isBuiltIn: false,
                    isVirtual: false,
                    supportsHardwareDDC: true,
                    backendName: "Test DDC",
                    unavailableReason: nil,
                    controls: [],
                    colorPreset: DisplayColorPresetCapability(
                        status: .available,
                        currentRawValue: currentRawValue,
                        options: [
                            DisplayColorPresetOption(rawValue: 0x0B, name: "sRGB"),
                            DisplayColorPresetOption(rawValue: 0x0C, name: "Display P3"),
                            DisplayColorPresetOption(rawValue: 0x41, name: "HDR Preview"),
                        ],
                        advertisedRawValues: [0x0B, 0x0C, 0x41],
                        unavailableReason: nil
                    )
                ),
            ]
        )
    }
}
