import CoreGraphics
import XCTest
@testable import ToolBoxCore

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
    private var failReleasedFirstWrite = false
    private var failingKinds = Set<DisplayControlKind>()
    private var blockedKind: DisplayControlKind?
    private var kindBlockedRelease: CheckedContinuation<Void, Never>?
    private var kindBlockedStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var failKindBlockedWrite = false
    private var firstWriteRelease: CheckedContinuation<Void, Never>?
    private var firstWriteStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiters: [WriteWaiter] = []
    private var snapshotCount = 0
    private var shouldBlockNextSnapshot = false
    private var blockedSnapshotRelease: CheckedContinuation<Void, Never>?
    private var blockedSnapshotStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var failReleasedSnapshot = false
    private var configuredSnapshot: DisplayControlSnapshot
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

    func updateSnapshot(_ snapshot: DisplayControlSnapshot) {
        configuredSnapshot = snapshot
    }

    func failWrites(kind: DisplayControlKind) {
        failingKinds.insert(kind)
    }

    func releaseFirstWriteWithFailure() {
        failReleasedFirstWrite = true
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }

    func blockNextWrite(of kind: DisplayControlKind) {
        blockedKind = kind
    }

    func waitUntilKindWriteIsBlocked() async {
        if kindBlockedRelease != nil {
            return
        }
        await withCheckedContinuation { continuation in
            kindBlockedStartedWaiters.append(continuation)
        }
    }

    func releaseKindBlockedWrite(fail: Bool) {
        failKindBlockedWrite = fail
        kindBlockedRelease?.resume()
        kindBlockedRelease = nil
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

        if failReleasedFirstWrite {
            failReleasedFirstWrite = false
            throw SnapshotTestError.forced
        }
        if failingKinds.contains(kind) {
            throw DisplayControlError.writeFailed(displayID, kind)
        }
        if kind == blockedKind {
            blockedKind = nil
            await withCheckedContinuation { continuation in
                kindBlockedRelease = continuation
                let waiters = kindBlockedStartedWaiters
                kindBlockedStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            if failKindBlockedWrite {
                failKindBlockedWrite = false
                throw SnapshotTestError.forced
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

    func testVolumeWriteSucceedsWhenMuteControlUnsupported() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .unsupported, volumeStatus: .available))

        service.setVolume(displayID: 42, normalizedValue: 0.5)
        await provider.waitUntilWrite(kind: .volume, value: 0.5)

        let writes = await provider.recordedWrites()
        XCTAssertEqual(writes.map(\.0), [.volume])
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .volume), 0.5)
    }

    func testSetMutedAfterSetVolumeAppliesFinalMuteIntent() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.setVolume(displayID: 42, normalizedValue: 0.6)
        await provider.waitUntilFirstWriteIsBlocked()
        service.setMuted(displayID: 42, muted: true)
        await provider.releaseFirstWrite()
        await provider.waitUntilWrite(kind: .mute, value: 1)

        let writes = await provider.recordedWrites().map(\.0)
        XCTAssertEqual(writes, [.mute, .volume, .mute])
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .mute), 1)
    }

    func testMuteFailureDoesNotRollBackSuccessfulVolumeWrite() async {
        let provider = RecordingDisplayControlProvider()
        await provider.failWrites(kind: .mute)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available))

        service.setVolume(displayID: 42, normalizedValue: 0)
        await provider.waitUntilWrite(kind: .mute, value: 1)

        let writes = await provider.recordedWrites().map(\.0)
        XCTAssertEqual(writes, [.volume, .mute])
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .volume), 0)
    }

    func testStaleBrightnessWorkerFailureAfterStopDoesNotClobberNewState() async {
        let snapshot = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available)
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)

        service.writeBrightness(displayID: 42, normalizedValue: 0.5, smooth: false)
        await provider.waitUntilFirstWriteIsBlocked()
        service.stop()
        await provider.releaseFirstWriteWithFailure()
        for _ in 0..<20 { await Task.yield() }

        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available))
        service.writeBrightness(displayID: 42, normalizedValue: 0.8, smooth: false)
        await provider.waitUntilWrite(kind: .brightness, value: 0.8)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .brightness) ?? 0, 0.8, accuracy: 0.0001)
    }

    func testStaleAudioWorkerFailureAfterStopDoesNotClobberNewState() async {
        let snapshot = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 1)
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)

        service.setVolume(displayID: 42, normalizedValue: 0.4)
        await provider.waitUntilFirstWriteIsBlocked()
        service.stop()
        await provider.releaseFirstWriteWithFailure()
        for _ in 0..<20 { await Task.yield() }

        // New session on a replugged display; keep the provider's snapshot
        // aligned so post-write refreshes do not see another token change.
        let replugSnapshot = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 2)
        await provider.updateSnapshot(replugSnapshot)
        service.setSnapshotForTesting(replugSnapshot)
        service.setVolume(displayID: 42, normalizedValue: 0.9)
        await provider.waitUntilWrite(kind: .volume, value: 0.9)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .volume), 0.9)
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
        let removedSnapshot = DisplayControlSnapshot(timestamp: Date(), displays: [])
        await provider.updateSnapshot(removedSnapshot)
        service.setSnapshotForTesting(removedSnapshot)
        await provider.releaseFirstPresetWrite()
        await yieldForPendingTasks()

        let writes = await provider.recordedPresetWrites()
        XCTAssertEqual(writes, [0x41])
        XCTAssertNil(service.presentedColorPreset(displayID: 42))
        XCTAssertNil(service.colorPresetError(displayID: 42))
    }

    func testRefreshProbeFailureKeepsLastVerifiedPresetSelection() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)

        service.setColorPreset(displayID: 42, rawValue: 0x0B)
        await provider.waitUntilPresetWriteCount(1)
        await yieldForPendingTasks()
        XCTAssertEqual(service.presentedColorPreset(displayID: 42), 0x0B)

        // A refresh whose current-value probe fails must not blank the last
        // value verified by the successful write/readback.
        service.setSnapshotForTesting(
            Self.makePresetSnapshot(currentRawValue: nil)
        )
        await yieldForPendingTasks()

        XCTAssertEqual(service.presentedColorPreset(displayID: 42), 0x0B)
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

    private static func makeControlsSnapshot(
        muteStatus: DisplayControlStatus,
        volumeStatus: DisplayControlStatus,
        connectionToken: UInt64? = nil,
        brightnessRawMaximum: UInt16 = 100,
        muteRawCurrent: UInt16 = 2,
        brightnessHasValue: Bool = true
    ) -> DisplayControlSnapshot {
        func capability(
            kind: DisplayControlKind,
            status: DisplayControlStatus,
            rawCurrent: UInt16,
            rawMaximum: UInt16
        ) -> DisplayControlCapability {
            DisplayControlCapability(
                kind: kind,
                status: status,
                value: DisplayControlValue(
                    kind: kind,
                    timestamp: Date(),
                    rawCurrent: rawCurrent,
                    rawMinimum: 0,
                    rawMaximum: rawMaximum,
                    normalized: rawMaximum > 0 ? Double(rawCurrent) / Double(rawMaximum) : 0
                ),
                unavailableReason: status == .available ? nil : "test"
            )
        }

        return DisplayControlSnapshot(
            timestamp: Date(),
            displays: [
                DisplayControlDisplay(
                    id: 42,
                    name: "Controls Display",
                    vendorNumber: 1,
                    modelNumber: 2,
                    serialNumber: 3,
                    isBuiltIn: false,
                    isVirtual: false,
                    supportsHardwareDDC: true,
                    backendName: "Test DDC",
                    unavailableReason: nil,
                    controls: [
                        brightnessHasValue
                            ? capability(kind: .brightness, status: .available, rawCurrent: brightnessRawMaximum / 2, rawMaximum: brightnessRawMaximum)
                            : DisplayControlCapability(kind: .brightness, status: .writeOnly, value: nil, unavailableReason: "value unavailable"),
                        capability(kind: .contrast, status: .available, rawCurrent: 50, rawMaximum: 100),
                        capability(kind: .volume, status: volumeStatus, rawCurrent: 10, rawMaximum: 100),
                        capability(kind: .mute, status: muteStatus, rawCurrent: muteRawCurrent, rawMaximum: 2),
                    ],
                    colorPreset: nil,
                    connectionToken: connectionToken
                ),
            ]
        )
    }

    private static func makePresetSnapshot(currentRawValue: UInt8?) -> DisplayControlSnapshot {
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

extension DisplayControlServiceTests {
    /// A stale audio worker whose write fails after stop() must not roll
    /// back the newer session's desired values.
    func testStaleAudioWorkerFailureDoesNotOverrideNewSessionIntent() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 1))

        service.setVolume(displayID: 42, normalizedValue: 0.4)
        await provider.waitUntilFirstWriteIsBlocked()
        service.stop()

        // New session on a replugged display (same ID, new token). The new
        // worker blocks inside its unmute write, then the user flips mute —
        // the desired mute state must differ from the seeded last-successful
        // value so a stale rollback is observable.
        let replugSnapshot = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 2)
        await provider.updateSnapshot(replugSnapshot)
        service.setSnapshotForTesting(replugSnapshot)
        await provider.blockNextWrite(of: .mute)
        service.setVolume(displayID: 42, normalizedValue: 0.9)
        await provider.waitUntilKindWriteIsBlocked()
        service.setMuted(displayID: 42, muted: true)

        // The old worker's write now fails; its failure handling must be
        // dropped because it no longer owns the display.
        await provider.releaseFirstWriteWithFailure()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .volume), 0.9)
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .mute), 1)

        await provider.releaseKindBlockedWrite(fail: false)
        await provider.waitUntilWrite(kind: .mute, value: 1)
    }

    /// A replug under the same CGDirectDisplayID clears stale manual targets;
    /// the snapshot value re-seeds the desired value.
    func testSeedValuesClearsUserTargetsOnSameIDReplug() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 1))

        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.9)
        await provider.waitUntilWrite(kind: .contrast, value: 0.9)
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .contrast), 0.9)

        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 2))
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .contrast), 0.5)
    }

    /// After a failed refresh, a successful refresh to an empty topology
    /// must publish the empty snapshot AND clear the error, so consumers
    /// can act on the genuinely-empty state.
    func testRefreshRecoversToEmptyTopologyAfterFailure() async {
        let provider = RecordingDisplayControlProvider(
            snapshot: Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available)
        )
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available))

        await provider.blockNextSnapshot()
        service.refresh()
        await provider.waitUntilSnapshotIsBlocked()
        await provider.releaseBlockedSnapshotWithFailure()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(service.lastRefreshError)
        XCTAssertEqual(service.snapshot.displays.count, 1)

        await provider.updateSnapshot(DisplayControlSnapshot(timestamp: Date(), displays: []))
        service.refresh()
        for _ in 0..<100 where !(service.snapshot.displays.isEmpty && service.lastRefreshError == nil) {
            await Task.yield()
        }
        XCTAssertTrue(service.snapshot.displays.isEmpty)
        XCTAssertNil(service.lastRefreshError)
    }
}

extension DisplayControlServiceTests {
    // MARK: - Request-level generation (same worker, newer intent mid-flight)

    func testBrightnessFailureDuringNewerIntentKeepsNewerTarget() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.writeBrightness(displayID: 42, normalizedValue: 0.3, smooth: false)
        await provider.waitUntilFirstWriteIsBlocked()
        // Newer intent submitted while the old write is in flight.
        service.writeBrightness(displayID: 42, normalizedValue: 0.7, smooth: false)

        await provider.releaseFirstWriteWithFailure()
        await provider.waitUntilWrite(kind: .brightness, value: 0.7)

        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .brightness) ?? 0, 0.7, accuracy: 0.0001)
    }

    func testContrastFailureDuringNewerIntentKeepsNewerTarget() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)

        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.2)
        await provider.waitUntilFirstWriteIsBlocked()
        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.8)

        await provider.releaseFirstWriteWithFailure()
        await provider.waitUntilWrite(kind: .contrast, value: 0.8)

        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .contrast), 0.8)
    }

    func testAudioFailureDuringNewerIntentKeepsDesiredMute() async {
        let snapshot = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, muteRawCurrent: 0)
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        await provider.blockNextWrite(of: .mute)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)

        service.setVolume(displayID: 42, normalizedValue: 0.5)
        await provider.waitUntilKindWriteIsBlocked()
        // Newer mute intent submitted mid-flight (seeded state: unmuted).
        service.setMuted(displayID: 42, muted: true)

        await provider.releaseKindBlockedWrite(fail: true)
        await provider.waitUntilWrite(kind: .mute, value: 1)
        for _ in 0..<20 { await Task.yield() }

        // A stale rollback would restore the seeded 0; the newer intent owns
        // the desired state.
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .mute), 1)
    }

    func testPresetFailureDuringNewerIntentAppliesNewerPreset() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstPresetWrite()
        await provider.failPresetWrite(rawValue: 0x0B)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)

        service.setColorPreset(displayID: 42, rawValue: 0x0B)
        await provider.waitUntilFirstPresetWriteIsBlocked()
        service.setColorPreset(displayID: 42, rawValue: 0x0C)

        await provider.releaseFirstPresetWrite()
        await provider.waitUntilPresetWriteCount(2)

        XCTAssertEqual(service.presentedColorPreset(displayID: 42), 0x0C)
        XCTAssertNil(service.colorPresetError(displayID: 42))
    }

    // MARK: - Replug / removal state isolation

    func testRemovalDropsControlState() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available))

        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.7)
        await provider.waitUntilWrite(kind: .contrast, value: 0.7)
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .contrast) ?? 0, 0.7, accuracy: 0.0001)

        service.setSnapshotForTesting(DisplayControlSnapshot(timestamp: Date(), displays: []))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(service.presentedValue(displayID: 42, kind: .contrast))
    }

    func testTokenChangeCancelsInFlightWorkerAndClearsState() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 1))

        service.writeBrightness(displayID: 42, normalizedValue: 0.5, smooth: false)
        await provider.waitUntilFirstWriteIsBlocked()

        // Replug under the same ID fences the in-flight worker.
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 2))
        await provider.releaseFirstWrite()
        for _ in 0..<20 { await Task.yield() }

        let brightnessWrites = await provider.recordedWrites().filter { $0.0 == .brightness }
        XCTAssertEqual(brightnessWrites.count, 1)

        service.writeBrightness(displayID: 42, normalizedValue: 0.8, smooth: false)
        await provider.waitUntilWrite(kind: .brightness, value: 0.8)
        XCTAssertEqual(service.presentedValue(displayID: 42, kind: .brightness), 0.8)
    }
}

extension DisplayControlServiceTests {
    /// A newer same-target force request must not be completed away by the
    /// older non-force write: the force write still reaches the transport.
    func testSameTargetForceRequestIsNotSwallowedByOlderWrite() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available))

        service.writeBrightness(displayID: 42, normalizedValue: 0.5, smooth: false)
        await provider.waitUntilFirstWriteIsBlocked()
        // Same target, newer sequence, force (scheduled) policy.
        service.writeBrightness(displayID: 42, normalizedValue: 0.5, smooth: false, policy: .scheduled)

        await provider.releaseFirstWrite()
        for _ in 0..<100 {
            let writes = await provider.recordedWrites().filter { $0.0 == .brightness }
            if writes.count >= 2 { break }
            await Task.yield()
        }

        let writes = await provider.recordedWrites().filter { $0.0 == .brightness }
        XCTAssertEqual(writes.count, 2)
        XCTAssertFalse(writes[0].2.contains(.force))
        XCTAssertTrue(writes[1].2.contains(.force))
    }

    /// During a snapshot publish (@Published willSet), quantization must use
    /// the already-seeded NEW raw range, not the previous screen's range.
    func testQuantizationUsesSeededRangeDuringPublish() async {
        let oldRange = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, brightnessRawMaximum: 10)
        let newRange = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, brightnessRawMaximum: 100)
        let provider = RecordingDisplayControlProvider(snapshot: newRange)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(oldRange)

        let cancellable = service.$snapshot.sink { snapshot in
            guard snapshot.displays.first?.controls.first(where: { $0.kind == .brightness })?.value?.rawMaximum == 100 else {
                return
            }
            // Runs during willSet: service.snapshot still reports the old
            // 0...10 range, but the seeded view already carries 0...100.
            service.writeBrightness(displayID: 42, normalizedValue: 0.53, smooth: false)
        }
        defer { cancellable.cancel() }

        service.refresh()
        await provider.waitUntilWrite(kind: .brightness, value: 0.53)
    }
}

extension DisplayControlServiceTests {
    /// A replug whose new snapshot reports the brightness capability without
    /// a value (write-only) must drop the previous connection's seeded raw
    /// range: quantization falls back to the default step instead of the old
    /// screen's step.
    func testReplugWithoutValueDropsSeededRange() async {
        let oldRange = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 1, brightnessRawMaximum: 10)
        let replug = Self.makeControlsSnapshot(muteStatus: .available, volumeStatus: .available, connectionToken: 2, brightnessRawMaximum: 100, brightnessHasValue: false)
        let provider = RecordingDisplayControlProvider(snapshot: replug)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(oldRange)

        service.setSnapshotForTesting(replug)

        // With the stale seeded range (0...10, step 0.1) this quantizes to
        // 0.5; the default step 0.01 keeps 0.53.
        service.writeBrightness(displayID: 42, normalizedValue: 0.53, smooth: false)
        await provider.waitUntilWrite(kind: .brightness, value: 0.53)
    }
}
