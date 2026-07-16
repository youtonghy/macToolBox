import Foundation

protocol ChipPowerProviding: AnyObject {
    var latestSnapshot: ChipPowerSnapshot? { get }
    var onUpdate: ((ChipPowerSnapshot) -> Void)? { get set }

    func start(interval: TimeInterval)
    func stop()
    func snapshot() -> ChipPowerSnapshot
}

extension ChipPowerProviding {
    func start() {
        start(interval: 1.0)
    }
}

struct ChipPowerSnapshot: Codable, Equatable, Sendable {
    var timestamp: Date
    var status: ChipPowerStatus
    var source: ChipPowerSource
    var chipName: String?
    var macModel: String?
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var combinedWatts: Double?
    var systemWatts: Double?
    var dramWatts: Double?
    var gpuSRAMWatts: Double?
    var sampleInterval: TimeInterval?
    var message: String?
}

enum ChipPowerStatus: String, Codable, Equatable, Sendable {
    case ok
    case partial
    case warmingUp
    case unsupported
    case unavailable
}

enum ChipPowerSource: String, Codable, Equatable, Sendable {
    case ioReportEnergyModel
    case smcSystemPower
    case unavailable
}
