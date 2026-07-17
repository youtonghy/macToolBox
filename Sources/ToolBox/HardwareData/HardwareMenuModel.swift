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

struct CableDetailRow: Identifiable, Equatable {
    var id: String { "\(label)|\(value)" }
    var label: String
    var value: String
}

struct CableDetailGroup: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var rows: [CableDetailRow]
}

struct CableDisplayItem: Identifiable, Equatable {
    var id: UInt64
    var title: String
    var lines: [String]
    var kind: CableDisplayKind
    var cableType: CableTypeSnapshot?
    var detailGroups: [CableDetailGroup] = []
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
    @Published private(set) var powerAdapterGroup: CableDetailGroup?
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
                await MainActor.run {
                    self.cableItems = []
                    self.powerAdapterGroup = nil
                }
            }
        }
    }

    func setCableItemsForTesting(_ items: [CableDisplayItem]) {
        cableItems = items
    }

    func setPowerAdapterGroupForTesting(_ group: CableDetailGroup?) {
        powerAdapterGroup = group
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
        powerAdapterGroup = makePowerAdapterGroup(from: snapshot.adapter)
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
            cableType: port.cableCapability?.cableType,
            detailGroups: makeDetailGroups(for: port)
        )
    }

    private func makePowerAdapterGroup(from adapter: PowerAdapterSnapshot?) -> CableDetailGroup? {
        guard let adapter else { return nil }

        var rows: [CableDetailRow] = []
        if let name = adapter.name, !name.isEmpty {
            rows.append(.init(label: "名称", value: name))
        }
        if let manufacturer = adapter.manufacturer, !manufacturer.isEmpty {
            rows.append(.init(label: "厂商", value: manufacturer))
        }
        if let model = adapter.model, !model.isEmpty {
            rows.append(.init(label: "型号", value: model))
        }
        if let description = adapter.description, !description.isEmpty {
            rows.append(.init(label: "描述", value: description))
        }
        if let watts = adapter.watts {
            rows.append(.init(label: "功率", value: "\(watts) W"))
        }
        if let voltageMV = adapter.voltageMV {
            rows.append(.init(label: "电压", value: voltsText(voltageMV)))
        }
        if let currentMA = adapter.currentMA {
            rows.append(.init(label: "电流", value: ampsText(currentMA)))
        }

        guard !rows.isEmpty else { return nil }
        return CableDetailGroup(title: "电源适配器", rows: rows)
    }

    private func makeDetailGroups(for port: CablePortSnapshot) -> [CableDetailGroup] {
        var groups: [CableDetailGroup] = []

        var portRows: [CableDetailRow] = [
            .init(label: "端口", value: port.name)
        ]
        if let type = port.type, !type.isEmpty {
            portRows.append(.init(label: "类型", value: type))
        }
        if let portNumber = port.portNumber {
            portRows.append(.init(label: "编号", value: "#\(portNumber)"))
        }
        if let connectionActive = port.connectionActive {
            portRows.append(.init(label: "连接", value: connectionActive ? "已连接" : "未连接"))
        }
        portRows.append(.init(label: "USB-PD", value: port.pdCapable ? "支持" : "不支持"))
        if !port.transportsActive.isEmpty {
            portRows.append(.init(label: "活动传输", value: port.transportsActive.joined(separator: " · ")))
        }
        if !port.transportsSupported.isEmpty {
            portRows.append(.init(label: "支持传输", value: port.transportsSupported.joined(separator: " · ")))
        }
        if !port.transportsProvisioned.isEmpty {
            portRows.append(.init(label: "已配置传输", value: port.transportsProvisioned.joined(separator: " · ")))
        }
        groups.append(CableDetailGroup(title: "端口信息", rows: portRows))

        if let capability = port.cableCapability {
            var rows: [CableDetailRow] = []
            if let protocolText = protocolText(for: port) {
                rows.append(.init(label: "协议", value: protocolText))
            }
            if let power = cableCapabilityPowerText(capability) {
                rows.append(.init(label: "线缆功率", value: power))
            }
            if let speed = cableCapabilitySpeedText(capability) {
                rows.append(.init(label: "线缆速率", value: speed))
            }
            if let cableType = cableTypeText(capability.cableType) {
                rows.append(.init(label: "线缆类型", value: cableType))
            }
            if let eprCapable = capability.eprCapable {
                rows.append(.init(label: "EPR", value: eprCapable ? "支持" : "不支持"))
            }
            if let vbusThroughCable = capability.vbusThroughCable {
                rows.append(.init(label: "VBUS 贯通", value: vbusThroughCable ? "是" : "否"))
            }
            if !capability.warnings.isEmpty {
                rows.append(.init(label: "警告", value: capability.warnings.joined(separator: " · ")))
            }
            if !rows.isEmpty {
                groups.append(CableDetailGroup(title: "线缆规格", rows: rows))
            }
        }

        if let power = port.powerNegotiation {
            var rows: [CableDetailRow] = []
            if let sourceName = power.sourceName, !sourceName.isEmpty {
                rows.append(.init(label: "电源源", value: sourceName))
            }
            if let option = power.winningOption {
                rows.append(.init(label: "协商 PDO", value: powerOptionText(option)))
            }
            if let negotiated = power.negotiatedWatts {
                rows.append(.init(label: "协商功率", value: cableWattsText(negotiated)))
            }
            if let charger = power.chargerWatts {
                rows.append(.init(label: "适配器功率", value: cableWattsText(charger)))
            }
            if let cableMax = power.cableMaxWatts {
                rows.append(.init(label: "线缆上限", value: cableWattsText(cableMax)))
            }
            if let bottleneck = power.likelyBottleneck {
                rows.append(.init(label: "瓶颈", value: bottleneckText(bottleneck)))
            }
            if !power.options.isEmpty {
                let optionsText = power.options
                    .prefix(6)
                    .map(powerOptionText)
                    .joined(separator: " · ")
                rows.append(.init(label: "可选 PDO", value: optionsText))
            }
            if !rows.isEmpty {
                groups.append(CableDetailGroup(title: "供电协商", rows: rows))
            }
        }

        if let data = port.dataTransport, data.active {
            var rows: [CableDetailRow] = []
            if let effective = data.effectiveSpeedGbps {
                rows.append(.init(label: "有效速率", value: speedText(effective)))
            }
            if let advertised = data.cableAdvertisedSpeedGbps {
                rows.append(.init(label: "线缆宣告", value: speedText(advertised)))
            }
            if let controller = data.controllerCableSpeedGbps {
                rows.append(.init(label: "控制器速率", value: speedText(controller)))
            }
            if let usbDescription = data.usb3Description, !usbDescription.isEmpty {
                rows.append(.init(label: "USB 描述", value: usbDescription))
            }
            if let restricted = data.transportRestricted {
                rows.append(.init(label: "受限", value: restricted ? "是" : "否"))
            }
            if !rows.isEmpty {
                groups.append(CableDetailGroup(title: "数据链路", rows: rows))
            }
        }

        if let display = port.displayTransport, display.active {
            var rows: [CableDetailRow] = [
                .init(label: "状态", value: "活动")
            ]
            if let lanes = display.laneCount {
                rows.append(.init(label: "通道", value: "\(lanes) lanes"))
            }
            if let maxLanes = display.maxLaneCount {
                rows.append(.init(label: "最大通道", value: "\(maxLanes)"))
            }
            if let rate = display.linkRateDescription, !rate.isEmpty {
                rows.append(.init(label: "链路速率", value: rate))
            }
            if let payload = display.estimatedPayloadGbps {
                rows.append(.init(label: "估算负载", value: speedText(payload)))
            }
            if let role = display.role, !role.isEmpty {
                rows.append(.init(label: "角色", value: role))
            }
            if let sinks = display.sinkCount {
                rows.append(.init(label: "Sink 数", value: "\(sinks)"))
            }
            let monitors = display.monitors.compactMap { monitor in
                monitor.productName ?? monitor.name
            }
            if !monitors.isEmpty {
                rows.append(.init(label: "显示器", value: monitors.joined(separator: " · ")))
            }
            groups.append(CableDetailGroup(title: "显示链路", rows: rows))
        }

        if !port.cableIdentities.isEmpty {
            var rows: [CableDetailRow] = []
            for identity in port.cableIdentities {
                let endpoint: String
                switch identity.endpoint {
                case .sop: endpoint = "SOP"
                case .sopPrime: endpoint = "SOP'"
                case .sopDoublePrime: endpoint = "SOP''"
                }
                if let vendor = identity.vendorName, !vendor.isEmpty {
                    rows.append(.init(label: "\(endpoint) 厂商", value: vendor))
                }
                if let product = identity.productName, !product.isEmpty {
                    rows.append(.init(label: "\(endpoint) 产品", value: product))
                }
                if let revision = identity.specRevision, !revision.isEmpty {
                    rows.append(.init(label: "\(endpoint) 规范", value: revision))
                }
                if let vendorID = identity.vendorID {
                    rows.append(.init(label: "\(endpoint) VID", value: String(format: "0x%04X", vendorID)))
                }
                if let productID = identity.productID {
                    rows.append(.init(label: "\(endpoint) PID", value: String(format: "0x%04X", productID)))
                }
            }
            if !rows.isEmpty {
                groups.append(CableDetailGroup(title: "线缆身份", rows: rows))
            }
        }

        return groups
    }

    private func bottleneckText(_ bottleneck: PowerBottleneck) -> String {
        switch bottleneck {
        case .cable:
            return "线缆"
        case .charger:
            return "充电器"
        case .mac:
            return "本机"
        case .none:
            return "无明显瓶颈"
        case .unknown:
            return "未知"
        }
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
