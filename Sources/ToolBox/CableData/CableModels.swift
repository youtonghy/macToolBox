import Foundation

protocol CableSnapshotProviding: AnyObject {
    func snapshot() async throws -> CableSnapshot
    func watch(interval: TimeInterval) -> AsyncThrowingStream<CableSnapshot, Error>
}

extension CableSnapshotProviding {
    func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        watch(interval: 1.0)
    }
}

enum CableSnapshotError: Error, LocalizedError {
    case iokitUnavailable

    var errorDescription: String? {
        switch self {
        case .iokitUnavailable:
            return "IOKit cable registry data is unavailable on this Mac."
        }
    }
}

struct CableSnapshot: Codable, Equatable, Sendable {
    var timestamp: Date
    var ports: [CablePortSnapshot]
    var adapter: PowerAdapterSnapshot?
    var isDesktopMac: Bool
    var batteryFullyCharged: Bool?
    var batteryIsCharging: Bool?
}

struct CablePortSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UInt64
    var name: String
    var className: String
    var type: String?
    var portNumber: Int?
    var connectionActive: Bool?
    var pdCapable: Bool
    var transportsSupported: [String]
    var transportsActive: [String]
    var transportsProvisioned: [String]
    var plugOrientation: Int?
    var cableIdentities: [CableIdentitySnapshot]
    var cableCapability: CableCapabilitySnapshot?
    var powerNegotiation: PowerNegotiationSnapshot?
    var dataTransport: DataTransportSnapshot?
    var displayTransport: DisplayTransportSnapshot?
    var rawProperties: [String: CablePropertyValue]
}

enum CablePropertyValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case stringArray([String])
    case data(Data)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case bool
        case int
        case double
        case string
        case stringArray
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int64.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .value))
        case .data:
            self = .data(try container.decode(Data.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bool(value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .int(value):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .double(value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .string(value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .stringArray(value):
            try container.encode(ValueType.stringArray, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .data(value):
            try container.encode(ValueType.data, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct PowerAdapterSnapshot: Codable, Equatable, Sendable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var description: String?
    var watts: Int?
    var voltageMV: Int?
    var currentMA: Int?
    var adapterID: Int?
    var familyCode: Int?
    var rawDetails: [String: CablePropertyValue]
}

struct PowerNegotiationSnapshot: Codable, Equatable, Sendable {
    var sourceName: String?
    var options: [PowerOptionSnapshot]
    var winningOption: PowerOptionSnapshot?
    var negotiatedWatts: Double?
    var chargerWatts: Double?
    var cableMaxWatts: Double?
    var likelyBottleneck: PowerBottleneck?
}

struct PowerOptionSnapshot: Codable, Equatable, Sendable {
    var voltageMV: Int
    var maxCurrentMA: Int
    var maxPowerMW: Int

    var watts: Double {
        Double(maxPowerMW) / 1_000.0
    }
}

enum PowerBottleneck: String, Codable, Equatable, Sendable {
    case cable
    case charger
    case mac
    case none
    case unknown
}

struct CableIdentitySnapshot: Codable, Equatable, Sendable {
    var endpoint: CableIdentityEndpoint
    var vendorID: Int?
    var productID: Int?
    var vendorName: String?
    var productName: String?
    var bcdDevice: Int?
    var specRevision: String?
    var vdos: [UInt32]
    var rawVDOData: Data?
}

enum CableIdentityEndpoint: String, Codable, Equatable, Sendable {
    case sop
    case sopPrime
    case sopDoublePrime
}

struct CableCapabilitySnapshot: Codable, Equatable, Sendable {
    var sourceEndpoint: CableIdentityEndpoint
    var vdoVersion: Int?
    var cableType: CableTypeSnapshot?
    var maxCurrentA: Double?
    var maxVoltageV: Double?
    var maxWatts: Double?
    var speedGbps: Double?
    var speedDescription: String?
    var cableLatency: Int?
    var cableTermination: Int?
    var eprCapable: Bool?
    var vbusThroughCable: Bool?
    var activeCable: Bool?
    var hasSOPDoublePrimeController: Bool?
    var warnings: [String]
}

enum CableTypeSnapshot: String, Codable, Equatable, Sendable {
    case passive
    case active
    case opticallyIsolated
    case unknown
}

struct DataTransportSnapshot: Codable, Equatable, Sendable {
    var active: Bool
    var usb3Signaling: Int?
    var usb3Description: String?
    var controllerCableSpeedGbps: Double?
    var cableAdvertisedSpeedGbps: Double?
    var effectiveSpeedGbps: Double?
    var dataRole: Int?
    var transportRestricted: Bool?
}

struct DisplayTransportSnapshot: Codable, Equatable, Sendable {
    var active: Bool
    var tunneled: Bool?
    var laneCount: Int?
    var maxLaneCount: Int?
    var linkRate: Int?
    var linkRateDescription: String?
    var estimatedPayloadGbps: Double?
    var hpdState: Int?
    var role: String?
    var sinkCount: Int?
    var monitors: [DisplayMonitorSnapshot]
}

struct DisplayMonitorSnapshot: Codable, Equatable, Sendable {
    var name: String?
    var productName: String?
    var vendorName: String?
    var productID: Int?
    var vendorID: Int?
    var serialNumber: String?
    var isVirtual: Bool?
}
