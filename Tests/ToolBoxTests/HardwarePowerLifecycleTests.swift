import Combine
import XCTest
@testable import ToolBox

final class HardwarePowerLifecycleTests: XCTestCase {
    func testProviderRestartSuppressesLateUpdateFromCancelledRun() async {
        let oldSampleStarted = expectation(description: "old sampler started")
        let newSamplePublished = expectation(description: "new sampler published")
        let oldSampler = BlockingPowerSampler(
            reading: powerReading(cpuWatts: 1),
            sampleStarted: oldSampleStarted
        )
        let newSampler = ImmediatePowerSampler(reading: powerReading(cpuWatts: 2))
        let factory = SequencedPowerSamplerFactory(samplers: [oldSampler, newSampler])
        let updates = RecordedPowerUpdates()
        let provider = DarwinChipPowerProvider(samplerFactory: factory.makeSampler)
        provider.onUpdate = { snapshot in
            updates.append(snapshot)
            if snapshot.cpuWatts == 2 {
                newSamplePublished.fulfill()
            }
        }
        defer {
            oldSampler.release()
            provider.stop()
        }

        provider.start(interval: 60)
        await fulfillment(of: [oldSampleStarted], timeout: 1)
        provider.stop()
        provider.start(interval: 60)
        oldSampler.release()
        await fulfillment(of: [newSamplePublished], timeout: 1)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(updates.values.contains { $0.cpuWatts == 1 })
        XCTAssertEqual(provider.latestSnapshot?.cpuWatts, 2)
    }

    func testHardwareMenuIgnoresPowerCallbackQueuedAfterStop() async {
        let powerProvider = ManualChipPowerProvider()
        let model = HardwareMenuModel(
            service: HardwareDataService(
                cableProvider: EmptyCableSnapshotProvider(),
                chipPowerProvider: powerProvider
            )
        )
        model.start()
        let stoppedSessionCallback = powerProvider.onUpdate
        model.stop()
        XCTAssertNil(powerProvider.onUpdate)

        let unexpectedUpdate = expectation(description: "stopped session power update")
        unexpectedUpdate.isInverted = true
        let observation = model.$latestPowerSnapshot
            .dropFirst()
            .sink { _ in unexpectedUpdate.fulfill() }

        stoppedSessionCallback?(powerSnapshot(cpuWatts: 9))
        await fulfillment(of: [unexpectedUpdate], timeout: 0.1)
        withExtendedLifetime(observation) {}

        XCTAssertNil(model.latestPowerSnapshot)
        XCTAssertTrue(model.cpuSamples.isEmpty)
    }

    func testHardwareMenuRejectsOldPowerCallbackAfterRestart() async {
        let powerProvider = ManualChipPowerProvider()
        let model = HardwareMenuModel(
            service: HardwareDataService(
                cableProvider: EmptyCableSnapshotProvider(),
                chipPowerProvider: powerProvider
            )
        )
        defer { model.stop() }

        model.start()
        let oldSessionCallback = powerProvider.onUpdate
        model.stop()
        model.start()
        let currentSessionCallback = powerProvider.onUpdate

        let currentUpdate = expectation(description: "current session power update")
        let observation = model.$latestPowerSnapshot
            .compactMap { $0 }
            .sink { snapshot in
                if snapshot.cpuWatts == 2 {
                    currentUpdate.fulfill()
                }
            }

        oldSessionCallback?(powerSnapshot(cpuWatts: 1))
        currentSessionCallback?(powerSnapshot(cpuWatts: 2))
        await fulfillment(of: [currentUpdate], timeout: 1)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(model.cpuSamples.compactMap(\.watts), [2])
    }

    func testHardwareMenuRejectsOldCableSnapshotAfterRestart() async {
        let oldRequestStarted = expectation(description: "old cable request started")
        let newRequestStarted = expectation(description: "new cable request started")
        let cableProvider = ControlledCableSnapshotProvider { requestCount in
            switch requestCount {
            case 1:
                oldRequestStarted.fulfill()
            case 2:
                newRequestStarted.fulfill()
            default:
                break
            }
        }
        let model = HardwareMenuModel(
            service: HardwareDataService(
                cableProvider: cableProvider,
                chipPowerProvider: ManualChipPowerProvider()
            )
        )
        defer {
            model.stop()
            cableProvider.cancelPendingRequests()
        }
        let observedIDs = RecordedCableItemIDs()
        let currentSnapshotPublished = expectation(description: "current cable snapshot published")
        let observation = model.$cableItems
            .dropFirst()
            .sink { items in
                let ids = items.map(\.id)
                observedIDs.append(ids)
                if ids == [2] {
                    currentSnapshotPublished.fulfill()
                }
            }

        model.start()
        await fulfillment(of: [oldRequestStarted], timeout: 1)
        model.stop()
        model.start()
        await fulfillment(of: [newRequestStarted], timeout: 1)
        cableProvider.resumeRequest(at: 0, with: cableSnapshot(portID: 1))
        cableProvider.resumeRequest(at: 1, with: cableSnapshot(portID: 2))
        await fulfillment(of: [currentSnapshotPublished], timeout: 1)
        withExtendedLifetime(observation) {}

        XCTAssertFalse(observedIDs.values.contains([1]))
        XCTAssertEqual(model.cableItems.map(\.id), [2])
    }

    private func powerReading(cpuWatts: Double) -> IOReportPowerReading {
        IOReportPowerReading(
            cpuWatts: cpuWatts,
            gpuWatts: 0,
            aneWatts: 0,
            combinedWatts: cpuWatts,
            dramWatts: 0,
            gpuSRAMWatts: 0,
            sampleInterval: 1
        )
    }

    private func powerSnapshot(cpuWatts: Double) -> ChipPowerSnapshot {
        ChipPowerSnapshot(
            timestamp: Date(),
            status: .ok,
            source: .ioReportEnergyModel,
            chipName: nil,
            macModel: nil,
            cpuWatts: cpuWatts,
            gpuWatts: 0,
            aneWatts: 0,
            combinedWatts: cpuWatts,
            systemWatts: nil,
            dramWatts: 0,
            gpuSRAMWatts: 0,
            sampleInterval: 1,
            message: nil
        )
    }

    private func cableSnapshot(portID: UInt64) -> CableSnapshot {
        CableSnapshot(
            timestamp: Date(),
            ports: [
                CablePortSnapshot(
                    id: portID,
                    name: "USB-C Port \(portID)",
                    className: "IOPort",
                    type: "USB-C",
                    portNumber: Int(portID),
                    connectionActive: true,
                    pdCapable: true,
                    transportsSupported: ["CC"],
                    transportsActive: ["CC"],
                    transportsProvisioned: [],
                    plugOrientation: nil,
                    cableIdentities: [],
                    cableCapability: nil,
                    powerNegotiation: nil,
                    dataTransport: nil,
                    displayTransport: nil,
                    rawProperties: [:]
                )
            ],
            adapter: nil,
            isDesktopMac: false,
            batteryFullyCharged: nil,
            batteryIsCharging: nil
        )
    }
}

private final class EmptyCableSnapshotProvider: CableSnapshotProviding {
    func snapshot() async throws -> CableSnapshot {
        CableSnapshot(
            timestamp: Date(),
            ports: [],
            adapter: nil,
            isDesktopMac: false,
            batteryFullyCharged: nil,
            batteryIsCharging: nil
        )
    }

    func watch(interval: TimeInterval) -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class ManualChipPowerProvider: ChipPowerProviding {
    var latestSnapshot: ChipPowerSnapshot?
    var onUpdate: ((ChipPowerSnapshot) -> Void)?

    func start(interval: TimeInterval) {}
    func stop() {}

    func snapshot() -> ChipPowerSnapshot {
        latestSnapshot ?? ChipPowerSnapshot(
            timestamp: Date(),
            status: .unavailable,
            source: .unavailable,
            chipName: nil,
            macModel: nil,
            cpuWatts: nil,
            gpuWatts: nil,
            aneWatts: nil,
            combinedWatts: nil,
            systemWatts: nil,
            dramWatts: nil,
            gpuSRAMWatts: nil,
            sampleInterval: nil,
            message: nil
        )
    }
}

private final class ControlledCableSnapshotProvider: CableSnapshotProviding {
    private let lock = NSLock()
    private let onRequest: (Int) -> Void
    private var continuations: [CheckedContinuation<CableSnapshot, Error>?] = []

    init(onRequest: @escaping (Int) -> Void) {
        self.onRequest = onRequest
    }

    func snapshot() async throws -> CableSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            let requestCount = continuations.count
            lock.unlock()
            onRequest(requestCount)
        }
    }

    func watch(interval: TimeInterval) -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func resumeRequest(at index: Int, with snapshot: CableSnapshot) {
        lock.lock()
        let continuation = continuations[index]
        continuations[index] = nil
        lock.unlock()
        continuation?.resume(returning: snapshot)
    }

    func cancelPendingRequests() {
        lock.lock()
        let pending = continuations.compactMap { $0 }
        continuations = continuations.map { _ in nil }
        lock.unlock()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private final class RecordedCableItemIDs {
    private let lock = NSLock()
    private var storage: [[UInt64]] = []

    var values: [[UInt64]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ ids: [UInt64]) {
        lock.lock()
        storage.append(ids)
        lock.unlock()
    }
}

private final class BlockingPowerSampler: IOReportPowerSampling {
    private let reading: IOReportPowerReading
    private let sampleStarted: XCTestExpectation
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    init(reading: IOReportPowerReading, sampleStarted: XCTestExpectation) {
        self.reading = reading
        self.sampleStarted = sampleStarted
    }

    func sample() throws -> IOReportPowerReading? {
        sampleStarted.fulfill()
        releaseSemaphore.wait()
        return reading
    }

    func reset() {}

    func release() {
        releaseSemaphore.signal()
    }
}

private final class ImmediatePowerSampler: IOReportPowerSampling {
    private let reading: IOReportPowerReading

    init(reading: IOReportPowerReading) {
        self.reading = reading
    }

    func sample() throws -> IOReportPowerReading? {
        reading
    }

    func reset() {}
}

private final class SequencedPowerSamplerFactory {
    private let lock = NSLock()
    private var samplers: [any IOReportPowerSampling]

    init(samplers: [any IOReportPowerSampling]) {
        self.samplers = samplers
    }

    func makeSampler() throws -> any IOReportPowerSampling {
        lock.lock()
        defer { lock.unlock() }
        return samplers.removeFirst()
    }
}

private final class RecordedPowerUpdates {
    private let lock = NSLock()
    private var storage: [ChipPowerSnapshot] = []

    var values: [ChipPowerSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ snapshot: ChipPowerSnapshot) {
        lock.lock()
        storage.append(snapshot)
        lock.unlock()
    }
}
