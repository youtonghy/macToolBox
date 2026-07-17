import Foundation

final class DarwinChipPowerProvider: ChipPowerProviding {
    private let samplerFactory: () throws -> IOReportPowerSampler
    private let smcReader: SMCSystemPowerReader
    private var sampler: IOReportPowerSampler?
    private var task: Task<Void, Never>?

    var latestSnapshot: ChipPowerSnapshot?
    var onUpdate: ((ChipPowerSnapshot) -> Void)?

    init(
        samplerFactory: @escaping () throws -> IOReportPowerSampler = { try IOReportPowerSampler() },
        smcReader: SMCSystemPowerReader = SMCSystemPowerReader()
    ) {
        self.samplerFactory = samplerFactory
        self.smcReader = smcReader
    }

    func start(interval: TimeInterval = 1.0) {
        guard task == nil else {
            return
        }

        task = Task {
            do {
                let sampler = try samplerFactory()
                self.sampler = sampler
                let chipName = ChipIdentityProvider.chipName()
                let macModel = ChipIdentityProvider.macModel()

                while !Task.isCancelled {
                    let systemWatts = smcReader.readSystemWatts()
                    do {
                        if let reading = try sampler.sample() {
                            let snapshot = makeSnapshot(
                                status: .ok,
                                reading: reading,
                                source: .ioReportEnergyModel,
                                systemWatts: systemWatts,
                                chipName: chipName,
                                macModel: macModel,
                                message: nil
                            )
                            latestSnapshot = snapshot
                            onUpdate?(snapshot)
                        } else {
                            let snapshot = makeSnapshot(
                                status: .warmingUp,
                                reading: nil,
                                source: .ioReportEnergyModel,
                                systemWatts: systemWatts,
                                chipName: chipName,
                                macModel: macModel,
                                message: "Waiting for a second IOReport sample."
                            )
                            latestSnapshot = snapshot
                            onUpdate?(snapshot)
                        }
                    } catch {
                        let snapshot = makeSnapshot(
                            status: .unavailable,
                            reading: nil,
                            source: .ioReportEnergyModel,
                            systemWatts: systemWatts,
                            chipName: chipName,
                            macModel: macModel,
                            message: error.localizedDescription
                        )
                        latestSnapshot = snapshot
                        onUpdate?(snapshot)
                    }

                    let seconds = max(interval, 0.25)
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            } catch {
                let chipName = ChipIdentityProvider.chipName()
                let macModel = ChipIdentityProvider.macModel()
                let ioReportMessage = error.localizedDescription

                while !Task.isCancelled {
                    let systemWatts = smcReader.readSystemWatts()
                    let hasSMC = systemWatts != nil
                    let snapshot = ChipPowerSnapshot(
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
                            ? "IOReport unavailable: \(ioReportMessage). Using SMC system power only."
                            : ioReportMessage
                    )
                    latestSnapshot = snapshot
                    onUpdate?(snapshot)

                    let seconds = max(interval, 0.25)
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sampler?.reset()
        sampler = nil
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
