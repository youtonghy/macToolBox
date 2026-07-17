import CoreGraphics
import XCTest
@testable import ToolBox

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

    func snapshot() async throws -> DisplayControlSnapshot {
        snapshotCount += 1
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
}
