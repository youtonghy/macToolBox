import Foundation

final class HardwareDataService {
    static let shared = HardwareDataService()

    let cableProvider: CableSnapshotProviding
    let chipPowerProvider: ChipPowerProviding

    init(
        cableProvider: CableSnapshotProviding = DarwinCableSnapshotProvider(),
        chipPowerProvider: ChipPowerProviding = DarwinChipPowerProvider()
    ) {
        self.cableProvider = cableProvider
        self.chipPowerProvider = chipPowerProvider
    }

    func cableSnapshot() async throws -> CableSnapshot {
        try await cableProvider.snapshot()
    }

    func cableSnapshots(interval: TimeInterval = 1.0) -> AsyncThrowingStream<CableSnapshot, Error> {
        cableProvider.watch(interval: interval)
    }

    func startChipPower(interval: TimeInterval = 1.0, onUpdate: ((ChipPowerSnapshot) -> Void)? = nil) {
        chipPowerProvider.onUpdate = onUpdate
        chipPowerProvider.start(interval: interval)
    }

    func stopChipPower() {
        chipPowerProvider.stop()
    }

    func chipPowerSnapshot() -> ChipPowerSnapshot {
        chipPowerProvider.snapshot()
    }
}
