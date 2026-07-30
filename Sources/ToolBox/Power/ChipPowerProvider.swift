import Foundation

protocol IOReportPowerSampling: AnyObject {
    func sample() throws -> IOReportPowerReading?
    func reset()
}

extension IOReportPowerSampler: IOReportPowerSampling {}

final class DarwinChipPowerProvider: ChipPowerProviding {
    private let samplerFactory: () throws -> any IOReportPowerSampling
    private let smcReader: SMCSystemPowerReader
    private let stateLock = NSLock()
    private let smcLock = NSLock()
    private var task: Task<Void, Never>?
    private var runID: UInt64 = 0
    private var latestSnapshotValue: ChipPowerSnapshot?
    private var onUpdateValue: ((ChipPowerSnapshot) -> Void)?

    var latestSnapshot: ChipPowerSnapshot? {
        withStateLock { latestSnapshotValue }
    }

    var onUpdate: ((ChipPowerSnapshot) -> Void)? {
        get { withStateLock { onUpdateValue } }
        set { withStateLock { onUpdateValue = newValue } }
    }

    init(
        samplerFactory: @escaping () throws -> any IOReportPowerSampling = { try IOReportPowerSampler() },
        smcReader: SMCSystemPowerReader = SMCSystemPowerReader()
    ) {
        self.samplerFactory = samplerFactory
        self.smcReader = smcReader
    }

    func start(interval: TimeInterval = 1.0) {
        stateLock.lock()
        guard task == nil else {
            stateLock.unlock()
            return
        }
        runID &+= 1
        let currentRunID = runID
        task = Task { [weak self] in
            await self?.run(id: currentRunID, interval: interval)
        }
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        runID &+= 1
        let runningTask = task
        task = nil
        stateLock.unlock()
        runningTask?.cancel()
    }

    func snapshot() -> ChipPowerSnapshot {
        latestSnapshot ?? ChipPowerSnapshot(
            timestamp: Date(),
            status: .unavailable,
            source: .unavailable,
            chipName: ChipIdentityProvider.chipName(),
            macModel: ChipIdentityProvider.macModel(),
            cpuWatts: nil,
            gpuWatts: nil,
            aneWatts: nil,
            combinedWatts: nil,
            systemWatts: nil,
            dramWatts: nil,
            gpuSRAMWatts: nil,
            sampleInterval: nil,
            message: "No sample has been collected yet."
        )
    }

    private func run(id: UInt64, interval: TimeInterval) async {
        let sampler: (any IOReportPowerSampling)?
        let ioReportMessage: String?
        do {
            sampler = try samplerFactory()
            ioReportMessage = nil
        } catch {
            sampler = nil
            ioReportMessage = error.localizedDescription
        }

        let chipName = ChipIdentityProvider.chipName()
        let macModel = ChipIdentityProvider.macModel()
        defer {
            sampler?.reset()
            finishRun(id: id)
        }

        while !Task.isCancelled, isCurrentRun(id) {
            let systemWatts = readSystemWatts()
            let snapshot: ChipPowerSnapshot
            if let sampler {
                do {
                    let reading = try sampler.sample()
                    snapshot = makeSnapshot(
                        status: reading == nil ? .warmingUp : .ok,
                        reading: reading,
                        source: .ioReportEnergyModel,
                        systemWatts: systemWatts,
                        chipName: chipName,
                        macModel: macModel,
                        message: reading == nil ? "Waiting for a second IOReport sample." : nil
                    )
                } catch {
                    snapshot = makeSnapshot(
                        status: .unavailable,
                        reading: nil,
                        source: .ioReportEnergyModel,
                        systemWatts: systemWatts,
                        chipName: chipName,
                        macModel: macModel,
                        message: error.localizedDescription
                    )
                }
            } else {
                let hasSMC = systemWatts != nil
                let message = ioReportMessage ?? "IOReport is unavailable."
                snapshot = ChipPowerSnapshot(
                    timestamp: Date(),
                    status: hasSMC ? .partial : .unsupported,
                    source: hasSMC ? .smcSystemPower : .unavailable,
                    chipName: chipName,
                    macModel: macModel,
                    cpuWatts: nil,
                    gpuWatts: nil,
                    aneWatts: nil,
                    combinedWatts: nil,
                    systemWatts: systemWatts,
                    dramWatts: nil,
                    gpuSRAMWatts: nil,
                    sampleInterval: nil,
                    message: hasSMC
                        ? "IOReport unavailable: \(message). Using SMC system power only."
                        : message
                )
            }

            guard !Task.isCancelled, isCurrentRun(id) else { break }
            publish(snapshot, runID: id)
            do {
                let seconds = max(interval, 0.25)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func publish(_ snapshot: ChipPowerSnapshot, runID: UInt64) {
        let publication: (accepted: Bool, callback: ((ChipPowerSnapshot) -> Void)?) = withStateLock {
            guard self.runID == runID, task != nil else { return (false, nil) }
            latestSnapshotValue = snapshot
            return (true, onUpdateValue)
        }
        guard publication.accepted, isCurrentRun(runID) else { return }
        publication.callback?(snapshot)
    }

    private func isCurrentRun(_ id: UInt64) -> Bool {
        withStateLock { runID == id && task != nil }
    }

    private func finishRun(id: UInt64) {
        withStateLock {
            if runID == id {
                task = nil
            }
        }
    }

    private func readSystemWatts() -> Double? {
        smcLock.lock()
        defer { smcLock.unlock() }
        return smcReader.readSystemWatts()
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func makeSnapshot(
        status: ChipPowerStatus,
        reading: IOReportPowerReading?,
        source: ChipPowerSource,
        systemWatts: Double?,
        chipName: String?,
        macModel: String?,
        message: String?
    ) -> ChipPowerSnapshot {
        ChipPowerSnapshot(
            timestamp: Date(),
            status: status,
            source: source,
            chipName: chipName,
            macModel: macModel,
            cpuWatts: reading.map(\.cpuWatts),
            gpuWatts: reading.map(\.gpuWatts),
            aneWatts: reading.map(\.aneWatts),
            combinedWatts: reading.map(\.combinedWatts),
            systemWatts: systemWatts,
            dramWatts: reading.map(\.dramWatts),
            gpuSRAMWatts: reading.map(\.gpuSRAMWatts),
            sampleInterval: reading?.sampleInterval,
            message: message
        )
    }
}
