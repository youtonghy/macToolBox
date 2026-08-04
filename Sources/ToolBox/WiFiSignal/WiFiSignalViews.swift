import SwiftUI

struct WiFiSignalPopoverView: View {
    @ObservedObject var model: WiFiSignalModel

    private enum Layout {
        static let qualityWidth: CGFloat = 70
        static let qualityMetricsSpacing: CGFloat = 26
        static let metricColumnSpacing: CGFloat = 20
        static let metricTextSpacing: CGFloat = 6
        static let metricTitleWidth: CGFloat = 30
        static let leftValueWidth: CGFloat = 84
        static let rightValueWidth: CGFloat = 98
    }

    var body: some View {
        Group {
            switch model.snapshot.state {
            case .connected:
                connectedContent
            case .noInterface:
                unavailableContent(
                    symbol: "wifi.slash",
                    title: "未检测到 Wi-Fi 接口",
                    detail: "当前 Mac 没有可用的无线接口"
                )
            case .poweredOff:
                unavailableContent(
                    symbol: "wifi.slash",
                    title: "Wi-Fi 已关闭",
                    detail: "打开 Wi-Fi 后将自动恢复监控"
                )
            case .disconnected:
                unavailableContent(
                    symbol: "wifi.exclamationmark",
                    title: "当前未连接",
                    detail: "连接网络后将显示实时链路信息"
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: MenuPanelLayout.wifiSectionContentHeight, alignment: .leading)
    }

    private var connectedContent: some View {
        HStack(spacing: Layout.qualityMetricsSpacing) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: model.snapshot.quality?.symbolName ?? "wifi.exclamationmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(qualityColor)
                    .frame(width: 28, height: 28)

                Text(model.snapshot.quality?.displayText ?? "指标不可用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(qualityColor)
            }
            .frame(width: Layout.qualityWidth, alignment: .leading)

            VStack(spacing: 7) {
                metricRow(
                    leftTitle: "信号",
                    leftValue: dbmText(model.snapshot.rssi),
                    rightTitle: "SNR",
                    rightValue: dbText(model.snapshot.snr)
                )
                metricRow(
                    leftTitle: "链路",
                    leftValue: rateText(model.snapshot.transmitRate),
                    rightTitle: "信道",
                    rightValue: channelText
                )
                metricRow(
                    leftTitle: "噪声",
                    leftValue: dbmText(model.snapshot.noise),
                    rightTitle: "宽度",
                    rightValue: model.snapshot.channelWidth.displayText
                )
            }
        }
        .frame(width: MenuPanelLayout.wifiConnectedContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func metricRow(
        leftTitle: String,
        leftValue: String,
        rightTitle: String,
        rightValue: String
    ) -> some View {
        HStack(spacing: Layout.metricColumnSpacing) {
            metric(title: leftTitle, value: leftValue, valueWidth: Layout.leftValueWidth)
            metric(title: rightTitle, value: rightValue, valueWidth: Layout.rightValueWidth)
        }
    }

    private func metric(title: String, value: String, valueWidth: CGFloat) -> some View {
        HStack(spacing: Layout.metricTextSpacing) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: Layout.metricTitleWidth, alignment: .leading)
            Text(value)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func unavailableContent(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualityColor: Color {
        switch model.snapshot.quality {
        case .veryPoor: return Color(nsColor: .systemRed)
        case .poor: return Color(nsColor: .systemOrange)
        case .fair: return Color(nsColor: .systemYellow)
        case .good: return Color(nsColor: .systemGreen)
        case .excellent: return Color(nsColor: .systemTeal)
        case nil: return .secondary
        }
    }

    private var channelText: String {
        guard let number = model.snapshot.channelNumber else { return "--" }
        return "\(number) · \(model.snapshot.band.displayText)"
    }
}

private enum WiFiChartMetric: String, CaseIterable, Identifiable {
    case rssi = "RSSI"
    case snr = "SNR"

    var id: String { rawValue }
}

struct WiFiSettingsView: View {
    @ObservedObject var model: WiFiSignalModel
    @State private var chartMetric = WiFiChartMetric.rssi

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: "实时信号", subtitle: "最近 5 分钟 · 每 2 秒采样") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("图表指标", selection: $chartMetric) {
                            ForEach(WiFiChartMetric.allCases) { metric in
                                Text(metric.rawValue).tag(metric)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)

                        WiFiHistoryChart(
                            points: model.history,
                            metric: chartMetric,
                            referenceTimestamp: model.snapshot.timestamp
                        )
                            .frame(height: 150)
                    }
                }

                if model.snapshot.state == .connected {
                    connectedSections
                } else {
                    SettingsSection(title: "监控状态") {
                        SettingsEmptyState(
                            symbolName: unavailableSymbol,
                            title: unavailableTitle,
                            description: unavailableDescription
                        )
                    }
                }

                SettingsSection(title: "采样状态") {
                    detailGrid([
                        ("状态", statusText),
                        ("最近更新", model.snapshot.timestamp.formatted(date: .omitted, time: .standard))
                    ])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var connectedSections: some View {
        SettingsSection(title: "连接质量", subtitle: model.snapshot.quality?.displayText ?? "指标暂不可用") {
            detailGrid([
                ("RSSI", dbmText(model.snapshot.rssi)),
                ("噪声", dbmText(model.snapshot.noise)),
                ("SNR", dbText(model.snapshot.snr)),
                ("链路速率", rateText(model.snapshot.transmitRate))
            ])
        }

        SettingsSection(title: "无线链路") {
            detailGrid([
                ("接口", model.snapshot.interfaceName ?? "系统未提供"),
                ("PHY", model.snapshot.phyMode ?? "系统未提供"),
                ("信道", model.snapshot.channelNumber.map(String.init) ?? "系统未提供"),
                ("频段", model.snapshot.band.displayText),
                ("信道宽度", model.snapshot.channelWidth.displayText),
                ("安全模式", model.snapshot.security ?? "系统未提供")
            ])
        }

        SettingsSection(title: "网络身份", subtitle: "不申请定位权限") {
            detailGrid([
                ("SSID", model.snapshot.ssid ?? "系统未提供"),
                ("BSSID", model.snapshot.bssid ?? "系统未提供")
            ])
        }
    }

    private func detailGrid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .font(.system(size: 12, weight: .semibold))
                        .fontDesign(.monospaced)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .textSelection(.enabled)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    private var statusText: String {
        switch model.snapshot.state {
        case .noInterface: return "无 Wi-Fi 接口"
        case .poweredOff: return "Wi-Fi 已关闭"
        case .disconnected: return "未连接"
        case .connected: return "正在监控"
        }
    }

    private var unavailableSymbol: String {
        model.snapshot.state == .disconnected ? "wifi.exclamationmark" : "wifi.slash"
    }

    private var unavailableTitle: String { statusText }

    private var unavailableDescription: String {
        switch model.snapshot.state {
        case .noInterface: return "当前 Mac 没有可供 CoreWLAN 读取的无线接口。"
        case .poweredOff: return "打开 Wi-Fi 后，ToolBox 会自动恢复采样。"
        case .disconnected: return "连接到网络后，将显示实时信号和无线链路参数。"
        case .connected: return ""
        }
    }
}

private struct WiFiHistoryChart: View {
    let points: [WiFiHistoryPoint]
    let metric: WiFiChartMetric
    let referenceTimestamp: Date

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if points.isEmpty {
                    Text("等待有效信号样本")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    chart(in: proxy.size)
                }
            }
        }
    }

    @ViewBuilder
    private func chart(in size: CGSize) -> some View {
        let values = metric == .rssi
            ? points.map { ($0.timestamp, Double($0.rssi)) }
            : points.map { ($0.timestamp, Double($0.snr)) }
        let secondary = metric == .rssi
            ? points.map { ($0.timestamp, Double($0.noise)) }
            : []
        let range = metric == .rssi ? (-100.0)...(-30.0) : 0.0...60.0

        ZStack {
            Canvas { context, canvasSize in
                drawGrid(context: &context, size: canvasSize)
                drawLine(
                    values,
                    latestTimestamp: referenceTimestamp,
                    range: range,
                    color: .green,
                    context: &context,
                    size: canvasSize
                )
                if !secondary.isEmpty {
                    drawLine(
                        secondary,
                        latestTimestamp: referenceTimestamp,
                        range: range,
                        color: .secondary,
                        context: &context,
                        size: canvasSize
                    )
                }
            }
            .accessibilityLabel(metric == .rssi ? "RSSI 与噪声历史图" : "SNR 历史图")
            .accessibilityValue(accessibilityValue)
        }
        .frame(width: size.width, height: size.height)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for fraction in [0.25, 0.5, 0.75] {
            var path = Path()
            let y = size.height * fraction
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
        }
    }

    private func drawLine(
        _ samples: [(Date, Double)],
        latestTimestamp: Date,
        range: ClosedRange<Double>,
        color: Color,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !samples.isEmpty else { return }
        var path = Path()
        let span = max(1, range.upperBound - range.lowerBound)
        let historyWindow: TimeInterval = 5 * 60
        var previousTimestamp: Date?

        for (timestamp, value) in samples {
            let elapsed = timestamp.timeIntervalSince(latestTimestamp)
            let xProgress = min(max(1 + elapsed / historyWindow, 0), 1)
            let x = size.width * CGFloat(xProgress)
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let normalized = (clamped - range.lowerBound) / span
            let point = CGPoint(x: x, y: size.height * (1 - normalized))
            if previousTimestamp.map({ timestamp.timeIntervalSince($0) > 6 }) ?? true {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            previousTimestamp = timestamp
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        if let latest = samples.last {
            let elapsed = latest.0.timeIntervalSince(latestTimestamp)
            let xProgress = min(max(1 + elapsed / historyWindow, 0), 1)
            let clamped = min(max(latest.1, range.lowerBound), range.upperBound)
            let normalized = (clamped - range.lowerBound) / span
            let rect = CGRect(
                x: size.width * CGFloat(xProgress) - 2.5,
                y: size.height * (1 - normalized) - 2.5,
                width: 5,
                height: 5
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private var accessibilityValue: String {
        guard let latest = points.last else { return "暂无样本" }
        switch metric {
        case .rssi:
            return "当前 RSSI \(latest.rssi) dBm，噪声 \(latest.noise) dBm"
        case .snr:
            return "当前 SNR \(latest.snr) dB"
        }
    }
}

private func dbmText(_ value: Int?) -> String {
    value.map { "\($0) dBm" } ?? "--"
}

private func dbText(_ value: Int?) -> String {
    value.map { "\($0) dB" } ?? "--"
}

private func rateText(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(Int(value.rounded())) Mbps"
}
