import Foundation

enum WiFiConnectionState: Equatable {
    case noInterface
    case poweredOff
    case disconnected
    case connected
}

enum WiFiSignalQuality: Equatable {
    case veryPoor
    case poor
    case fair
    case good
    case excellent

    init(snr: Int) {
        switch snr {
        case ..<11:
            self = .veryPoor
        case 11..<16:
            self = .poor
        case 16..<26:
            self = .fair
        case 26..<41:
            self = .good
        default:
            self = .excellent
        }
    }

    var displayText: String {
        switch self {
        case .veryPoor: return "很弱"
        case .poor: return "较弱"
        case .fair: return "一般"
        case .good: return "良好"
        case .excellent: return "极佳"
        }
    }

    var symbolName: String {
        switch self {
        case .veryPoor: return "wifi.exclamationmark"
        case .poor: return "wifi"
        case .fair: return "wifi"
        case .good: return "wifi"
        case .excellent: return "wifi"
        }
    }
}

enum WiFiBand: Equatable {
    case ghz2_4
    case ghz5
    case ghz6
    case unknown

    var displayText: String {
        switch self {
        case .ghz2_4: return "2.4 GHz"
        case .ghz5: return "5 GHz"
        case .ghz6: return "6 GHz"
        case .unknown: return "系统未提供"
        }
    }
}

enum WiFiChannelWidth: Equatable {
    case mhz20
    case mhz40
    case mhz80
    case mhz160
    case unknown

    var displayText: String {
        switch self {
        case .mhz20: return "20 MHz"
        case .mhz40: return "40 MHz"
        case .mhz80: return "80 MHz"
        case .mhz160: return "160 MHz"
        case .unknown: return "系统未提供"
        }
    }
}

struct WiFiSnapshot: Equatable {
    var timestamp: Date
    var state: WiFiConnectionState
    var interfaceName: String?
    var ssid: String?
    var bssid: String?
    var rssi: Int?
    var noise: Int?
    var transmitRate: Double?
    var channelNumber: Int?
    var band: WiFiBand
    var channelWidth: WiFiChannelWidth
    var phyMode: String?
    var security: String?

    var snr: Int? {
        guard let rssi, let noise else { return nil }
        return rssi - noise
    }

    var quality: WiFiSignalQuality? {
        snr.map(WiFiSignalQuality.init)
    }

    var identityText: String {
        ssid ?? "当前 Wi-Fi"
    }

    static func noInterface(at timestamp: Date = Date()) -> WiFiSnapshot {
        unavailable(timestamp: timestamp, state: .noInterface)
    }

    static func poweredOff(
        at timestamp: Date = Date(),
        interfaceName: String?
    ) -> WiFiSnapshot {
        unavailable(timestamp: timestamp, state: .poweredOff, interfaceName: interfaceName)
    }

    static func disconnected(
        at timestamp: Date = Date(),
        interfaceName: String?
    ) -> WiFiSnapshot {
        unavailable(timestamp: timestamp, state: .disconnected, interfaceName: interfaceName)
    }

    static func connected(
        timestamp: Date = Date(),
        interfaceName: String?,
        ssid: String?,
        bssid: String?,
        rssi: Int,
        noise: Int,
        transmitRate: Double,
        channelNumber: Int?,
        band: WiFiBand,
        channelWidth: WiFiChannelWidth,
        phyMode: String?,
        security: String?
    ) -> WiFiSnapshot {
        WiFiSnapshot(
            timestamp: timestamp,
            state: .connected,
            interfaceName: interfaceName,
            ssid: normalizedIdentity(ssid),
            bssid: normalizedIdentity(bssid),
            rssi: rssi == 0 ? nil : rssi,
            noise: noise == 0 ? nil : noise,
            transmitRate: transmitRate > 0 ? transmitRate : nil,
            channelNumber: channelNumber.flatMap { $0 > 0 ? $0 : nil },
            band: band,
            channelWidth: channelWidth,
            phyMode: normalizedIdentity(phyMode),
            security: normalizedIdentity(security)
        )
    }

    private static func unavailable(
        timestamp: Date,
        state: WiFiConnectionState,
        interfaceName: String? = nil
    ) -> WiFiSnapshot {
        WiFiSnapshot(
            timestamp: timestamp,
            state: state,
            interfaceName: interfaceName,
            ssid: nil,
            bssid: nil,
            rssi: nil,
            noise: nil,
            transmitRate: nil,
            channelNumber: nil,
            band: .unknown,
            channelWidth: .unknown,
            phyMode: nil,
            security: nil
        )
    }

    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "00:00:00:00:00:00" else { return nil }
        return trimmed
    }
}

struct WiFiHistoryPoint: Equatable {
    var timestamp: Date
    var rssi: Int
    var noise: Int

    var snr: Int { rssi - noise }
}

protocol WiFiSnapshotProviding: AnyObject {
    var onUpdate: (@MainActor (WiFiSnapshot) -> Void)? { get set }
    func start(interval: TimeInterval)
    func stop()
}
