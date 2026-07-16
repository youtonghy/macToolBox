import Combine
import CoreGraphics
import Foundation
import OSLog

enum PowerMetricKind {
    case cpu
    case gpu
}

enum PowerDisplayMode {
    case live
    case average5m
}

struct PowerHistoryPoint: Equatable {
    var timestamp: Date
    var watts: Double?
}

enum CableDisplayKind: Equatable {
    case magSafe
    case power
    case usbC
    case thunderbolt
    case display
    case unknown

    static func classify(port: CablePortSnapshot) -> CableDisplayKind {
        let descriptors = ([port.name, port.type].compactMap { $0 } + port.transportsActive)
            .map { $0.lowercased() }
            .joined(separator: " ")

        if port.displayTransport?.active == true
            || descriptors.contains("displayport")
            || descriptors.contains("dp tunnel") {
            return .display
        }
        if descriptors.contains("magsafe") {
            return .magSafe
        }
        if descriptors.contains("thunderbolt") || descriptors.contains("usb4") {
            return .thunderbolt
        }

        let hasData = port.dataTransport?.active == true
            || port.transportsActive.contains { transport in
                transport.localizedCaseInsensitiveContains("usb")
            }
        if port.powerNegotiation?.winningOption != nil && !hasData {
            return .power
        }
        if hasData
            || port.pdCapable
            || descriptors.contains("usb-c")
            || descriptors.contains("usb c")
            || descriptors.contains("type-c") {
            return .usbC
        }
        return .unknown
    }
}

struct CableDisplayItem: Identifiable, Equatable {
    var id: UInt64
    var title: String
    var lines: [String]
    var kind: CableDisplayKind
    var cableType: CableTypeSnapshot?
}

enum HardwareMenuLayout {
    static let maxCableItemCount = 3
    static let maxCableListHeight = cableListHeight(itemCount: maxCableItemCount)

    static func cableColumnCount(itemCount: Int) -> Int {
        itemCount <= 1 ? 1 : 2
    }

    static func cableRowCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let columnCount = cableColumnCount(itemCount: itemCount)
        return (itemCount + columnCount - 1) / columnCount
    }

    static func cableListHeight(itemCount: Int) -> CGFloat {
        let rowCount = cableRowCount(itemCount: itemCount)
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * MenuPanelLayout.cableRowHeight
            + CGFloat(rowCount - 1) * MenuPanelLayout.cableGridSpacing
    }
}

final class HardwareMenuModel: ObservableObject {
    @Published private(set) var cpuSamples: [PowerHistoryPoint] = []
    @Published private(set) var gpuSamples: [PowerHistoryPoint] = []
    @Published private(set) var cableItems: [CableDisplayItem] = []
    @Published private(set) var latestPowerSnapshot: ChipPowerSnapshot?
    @Published var cpuDisplayMode: PowerDisplayMode = .live
    @Published var gpuDisplayMode: PowerDisplayMode = .live

    private let service: HardwareDataService
    private let logger = Logger(subsystem: "ToolBox", category: "HardwareMenu")
    private let historyWindow: TimeInterval = 5 * 60
    private var cableTask: Task<Void, Never>?
    private var started = false

    init(service: HardwareDataService = .shared) {
        self.service = service
    }

    var visibleCableItems: [CableDisplayItem] {
        Array(cableItems.prefix(HardwareMenuLayout.maxCableItemCount))
    }

    var hiddenCableCount: Int {
        max(0, cableItems.count - HardwareMenuLayout.maxCableItemCount)
    }

    var cableListHeight: CGFloat {
        HardwareMenuLayout.cableListHeight(itemCount: visibleCableItems.count)
    }

    var cableSectionSubtitle: String {
        if hiddenCableCount > 0 {
            return "显示 \(visibleCableItems.count)/\(cableItems.count) 条连接中的链路"
        }
        return "当前连接中的 PD / 数据 / 显示链路"
    }

    func start() {
        guard !started else { return }
        started = true

        service.startChipPower(interval: 1.0) { [weak self] snapshot in
            Task { @MainActor in
                self?.ingestPower(snapshot)
            }
        }

        cableTask = Task { [weak self] in
            guard let self else { return }
            do {
                let initial = try await service.cableSnapshot()
                await MainActor.run { self.ingestCable(initial) }

                for try await snapshot in service.cableSnapshots(interval: 1.0) {
                    await MainActor.run { self.ingestCable(snapshot) }
                }
            } catch {
                logger.error("Cable sampling failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.cableItems = [] }
            }
        }
    }

    func setCableItemsForTesting(_ items: [CableDisplayItem]) {
        cableItems = items
    }

    func stop() {
        cableTask?.cancel()
        cableTask = nil
        service.stopChipPower()
        started = false
    }

    func toggleDisplayMode(for metric: PowerMetricKind) {
        switch metric {
        case .cpu:
            cpuDisplayMode = cpuDisplayMode == .live ? .average5m : .live
        case .gpu:
            gpuDisplayMode = gpuDisplayMode == .live ? .average5m : .live
        }
    }

    func samples(for metric: PowerMetricKind) -> [PowerHistoryPoint] {
        switch metric {
        case .cpu:
            return cpuSamples
        case .gpu:
            return gpuSamples
        }
    }

    func displayText(for metric: PowerMetricKind) -> String {
        let mode: PowerDisplayMode
        switch metric {
        case .cpu:
            mode = cpuDisplayMode
        case .gpu:
            mode = gpuDisplayMode
        }

        guard let value = displayValue(for: metric, mode: mode) else {
            return "N/A"
        }
        return wattsText(value)
    }

    func isAverageMode(_ metric: PowerMetricKind) -> Bool {
        switch metric {
        case .cpu:
            return cpuDisplayMode == .average5m
        case .gpu:
            return gpuDisplayMode == .average5m
        }
    }

    private func ingestPower(_ snapshot: ChipPowerSnapshot) {
        latestPowerSnapshot = snapshot
        cpuSamples.append(PowerHistoryPoint(timestamp: snapshot.timestamp, watts: snapshot.cpuWatts))
        gpuSamples.append(PowerHistoryPoint(timestamp: snapshot.timestamp, watts: snapshot.gpuWatts))
        trimPowerSamples(now: snapshot.timestamp)
    }

    private func ingestCable(_ snapshot: CableSnapshot) {
        cableItems = snapshot.ports
            .filter(isVisibleCable)
            .sorted { lhs, rhs in
                switch (lhs.portNumber, rhs.portNumber) {
                case let (l?, r?):
                    return l < r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.name < rhs.name
                }
            }
            .map(makeCableItem)
    }

    private func trimPowerSamples(now: Date) {
        let cutoff = now.addingTimeInterval(-historyWindow)
        cpuSamples.removeAll { $0.timestamp < cutoff }
        gpuSamples.removeAll { $0.timestamp < cutoff }
    }

    private func displayValue(for metric: PowerMetricKind, mode: PowerDisplayMode) -> Double? {
        let values = samples(for: metric)
        switch mode {
        case .live:
            return values.last?.watts
        case .average5m:
            let valid = values.compactMap(\.watts)
            guard !valid.isEmpty else { return nil }
            return valid.reduce(0, +) / Double(valid.count)
        }
    }

    private func isVisibleCable(_ port: CablePortSnapshot) -> Bool {
        port.connectionActive == true
            || !port.transportsActive.isEmpty
            || port.powerNegotiation?.winningOption != nil
            || port.dataTransport?.active == true
            || port.displayTransport?.active == true
    }

    private func makeCableItem(from port: CablePortSnapshot) -> CableDisplayItem {
        var lines: [String] = []
        if let specification = specificationLine(for: port) {
            lines.append(specification)
        }
        if let actual = actualLine(for: port) {
            lines.append(actual)
        }

        if let display = displayLine(for: port) {
            lines.append(display)
        }

        return CableDisplayItem(
            id: port.id,
            title: port.name,
            lines: lines.filter { !$0.isEmpty },
            kind: CableDisplayKind.classify(port: port),
            cableType: port.cableCapability?.cableType
        )
    }

    private func specificationLine(for port: CablePortSnapshot) -> String? {
        var parts: [String] = []
        if let protocolText = protocolText(for: port) {
            parts.append(protocolText)
        }
        if let capability = port.cableCapability {
            if let power = cableCapabilityPowerText(capability) {
                parts.append("支持 \(power)")
            }
            if let speed = cableCapabilitySpeedText(capability) {
                parts.append(speed)
            }
            if let cableType = cableTypeText(capability.cableType) {
                parts.append(cableType)
            }
        }

        guard !parts.isEmpty else { return nil }
        return "规格：" + parts.joined(separator: " · ")
    }

    private func protocolText(for port: CablePortSnapshot) -> String? {
        let endpoints = port.cableIdentities.map { identity in
            switch identity.endpoint {
            case .sop: return "SOP"
            case .sopPrime: return "SOP'"
            case .sopDoublePrime: return "SOP''"
            }
        }

        let revision = port.cableIdentities.compactMap(\.specRevision).first
        var protocolParts: [String] = []
        if let revision {
            protocolParts.append(revision)
        } else if port.pdCapable || !port.cableIdentities.isEmpty || port.cableCapability != nil {
            protocolParts.append("USB-PD")
        }
        if port.cableCapability?.eprCapable == true {
            protocolParts.append("EPR")
        }
        if !endpoints.isEmpty {
            protocolParts.append(endpoints.joined(separator: " / "))
        }

        guard !protocolParts.isEmpty else { return nil }
        return protocolParts.joined(separator: " · ")
    }

    private func actualLine(for port: CablePortSnapshot) -> String? {
        var parts: [String] = []
        if let power = actualPowerText(for: port.powerNegotiation) {
            parts.append(power)
        }
        if let data = actualDataText(for: port.dataTransport) {
            parts.append(data)
        }

        guard !parts.isEmpty else { return nil }
        return "实际：" + parts.joined(separator: " · ")
    }

    private func cableCapabilityPowerText(_ capability: CableCapabilitySnapshot) -> String? {
        guard let watts = capability.maxWatts else { return nil }

        var text = cableWattsText(watts)
        if let voltage = capability.maxVoltageV, let current = capability.maxCurrentA {
            text += "（\(quantityText(voltage, unit: "V")) \(quantityText(current, unit: "A"))）"
        }
        return text
    }

    private func cableCapabilitySpeedText(_ capability: CableCapabilitySnapshot) -> String? {
        if let description = capability.speedDescription, let speed = capability.speedGbps {
            return "\(description) \(speedText(speed))"
        }
        if let description = capability.speedDescription {
            return description
        }
        if let speed = capability.speedGbps {
            return speedText(speed)
        }
        return nil
    }

    private func cableTypeText(_ type: CableTypeSnapshot?) -> String? {
        switch type {
        case .active:
            return "主动线"
        case .passive:
            return "被动线"
        case .opticallyIsolated:
            return "光隔离"
        case .unknown, .none:
            return nil
        }
    }

    private func actualPowerText(for power: PowerNegotiationSnapshot?) -> String? {
        guard let power else { return nil }

        if let option = power.winningOption {
            return "PD \(powerOptionText(option))"
        }
        if let charger = power.chargerWatts {
            return "适配器 \(cableWattsText(charger))"
        }
        return nil
    }

    private func powerOptionText(_ option: PowerOptionSnapshot) -> String {
        "\(cableWattsText(option.watts))（\(voltsText(option.voltageMV)) \(ampsText(option.maxCurrentMA))）"
    }

    private func actualDataText(for transport: DataTransportSnapshot?) -> String? {
        guard let transport, transport.active else { return nil }

        var parts: [String] = []
        if let effective = transport.effectiveSpeedGbps {
            parts.append("数据 \(speedText(effective))")
        } else if let usbDescription = transport.usb3Description, !usbDescription.isEmpty {
            parts.append("数据 \(usbDescription)")
        }
        if let usbDescription = transport.usb3Description,
           !usbDescription.isEmpty,
           parts.first?.contains(usbDescription) != true {
            parts.append(usbDescription)
        }
        if transport.transportRestricted == true {
            parts.append("受限")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func displayLine(for port: CablePortSnapshot) -> String? {
        guard let display = port.displayTransport, display.active else {
            return nil
        }

        var parts = ["DisplayPort"]
        if let lanes = display.laneCount {
            parts.append("\(lanes) lanes")
        }
        if let rate = display.linkRateDescription, !rate.isEmpty {
            parts.append(rate)
        }
        if let monitor = display.monitors.first?.productName ?? display.monitors.first?.name {
            parts.append(monitor)
        } else if let sinks = display.sinkCount, sinks > 0 {
            parts.append("\(sinks) sinks")
        }
        return "显示：" + parts.joined(separator: " · ")
    }

    private func cableWattsText(_ watts: Double) -> String {
        quantityText(watts, unit: "W")
    }

    private func voltsText(_ millivolts: Int) -> String {
        quantityText(Double(millivolts) / 1_000.0, unit: "V")
    }

    private func ampsText(_ milliamps: Int) -> String {
        quantityText(Double(milliamps) / 1_000.0, unit: "A")
    }

    private func quantityText(_ value: Double, unit: String) -> String {
        if value.rounded() == value {
            return String(format: "%.0f %@", value, unit)
        }
        return String(format: "%.1f %@", value, unit)
    }

    private func wattsText(_ watts: Double) -> String {
        if watts >= 100 {
            return String(format: "%.0f W", watts)
        }
        if watts >= 10 {
            return String(format: "%.1f W", watts)
        }
        return String(format: "%.2f W", watts)
    }

    private func speedText(_ gbps: Double) -> String {
        if gbps.rounded() == gbps {
            return String(format: "%.0f Gbps", gbps)
        }
        return String(format: "%.1f Gbps", gbps)
    }
}
