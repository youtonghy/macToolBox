import CoreWLAN
import Foundation

final class CoreWLANWiFiProvider: WiFiSnapshotProviding {
    var onUpdate: (@MainActor (WiFiSnapshot) -> Void)?

    private let client: CWWiFiClient
    private let queue = DispatchQueue(label: "com.youtonghy.toolbox.wifi-sampler", qos: .utility)
    private let generationLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0

    init(client: CWWiFiClient = .shared()) {
        self.client = client
    }

    func start(interval: TimeInterval) {
        guard timer == nil else { return }
        let currentGeneration = nextGeneration()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: max(0.5, interval), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrentGeneration(currentGeneration) else { return }
            let snapshot = self.readSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentGeneration(currentGeneration) else { return }
                self.onUpdate?(snapshot)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        _ = nextGeneration()
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func nextGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == candidate
    }

    private func readSnapshot() -> WiFiSnapshot {
        let timestamp = Date()
        guard let interface = client.interface() else {
            return .noInterface(at: timestamp)
        }

        let interfaceName = interface.interfaceName
        guard interface.powerOn() else {
            return .poweredOff(at: timestamp, interfaceName: interfaceName)
        }

        guard interface.interfaceMode() == .station else {
            return .disconnected(at: timestamp, interfaceName: interfaceName)
        }

        let channel = interface.wlanChannel()
        let rssi = interface.rssiValue()
        let transmitRate = interface.transmitRate()

        return .connected(
            timestamp: timestamp,
            interfaceName: interfaceName,
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: rssi,
            noise: interface.noiseMeasurement(),
            transmitRate: transmitRate,
            channelNumber: channel?.channelNumber,
            band: channel.map { band(for: $0.channelBand) } ?? .unknown,
            channelWidth: channel.map { width(for: $0.channelWidth) } ?? .unknown,
            phyMode: phyModeText(interface.activePHYMode()),
            security: securityText(interface.security())
        )
    }

    private func band(for value: CWChannelBand) -> WiFiBand {
        switch value {
        case .band2GHz: return .ghz2_4
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default: return .unknown
        }
    }

    private func width(for value: CWChannelWidth) -> WiFiChannelWidth {
        switch value {
        case .width20MHz: return .mhz20
        case .width40MHz: return .mhz40
        case .width80MHz: return .mhz80
        case .width160MHz: return .mhz160
        default: return .unknown
        }
    }

    private func phyModeText(_ value: CWPHYMode) -> String? {
        switch value {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        case .mode11be: return "802.11be"
        default: return nil
        }
    }

    private func securityText(_ value: CWSecurity) -> String? {
        switch value {
        case .none: return "开放网络"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .OWE: return "OWE"
        case .oweTransition: return "OWE Transition"
        default: return nil
        }
    }
}
