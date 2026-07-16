import AppKit
import SwiftUI

struct PopoverContent: View {
    @ObservedObject var state: FeatureState
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: MenuPanelLayout.outerSpacing) {
            header

            VStack(alignment: .leading, spacing: MenuPanelLayout.contentSpacing) {
                hardwareSection

                if !hardware.cableItems.isEmpty {
                    section(title: "线缆状态", subtitle: hardware.cableSectionSubtitle) {
                        CableListView(items: hardware.visibleCableItems)
                            .frame(height: hardware.cableListHeight)
                    }
                }

                if displayControl.hasExternalDisplay {
                    section(title: "显示器控制", subtitle: "DDC / VCP 实时写回外接屏幕") {
                        DisplayControlPanel(model: displayControl)
                    }
                }
            }

            controlsBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ToolBox")
                    .font(.system(size: 22, weight: .semibold))

                Text("菜单栏里的硬件概览和常用系统工具")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HeaderBadgeStack(
                powerSummary: livePowerSummary,
                displaySummary: displaySummary
            )
            .frame(width: MenuPanelLayout.headerBadgesWidth)
        }
        .padding(.horizontal, 2)
        .frame(height: MenuPanelLayout.headerHeight)
    }

    private var hardwareSection: some View {
        section(title: "芯片功耗", subtitle: "点击数值可切换实时读数与 5 分钟平均值") {
            HStack(spacing: 10) {
                PowerChartRepresentable(
                    title: "CPU",
                    samples: hardware.samples(for: .cpu),
                    displayText: hardware.displayText(for: .cpu),
                    isAverageMode: hardware.isAverageMode(.cpu),
                    accentColor: .systemOrange,
                    onToggle: { hardware.toggleDisplayMode(for: .cpu) }
                )
                .frame(maxWidth: .infinity, minHeight: MenuPanelLayout.chartHeight, idealHeight: MenuPanelLayout.chartHeight, maxHeight: MenuPanelLayout.chartHeight)
                .clipped()

                PowerChartRepresentable(
                    title: "GPU",
                    samples: hardware.samples(for: .gpu),
                    displayText: hardware.displayText(for: .gpu),
                    isAverageMode: hardware.isAverageMode(.gpu),
                    accentColor: .systemTeal,
                    onToggle: { hardware.toggleDisplayMode(for: .gpu) }
                )
                .frame(maxWidth: .infinity, minHeight: MenuPanelLayout.chartHeight, idealHeight: MenuPanelLayout.chartHeight, maxHeight: MenuPanelLayout.chartHeight)
                .clipped()
            }
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            glassToggle(
                title: "擦屏幕",
                subtitle: "黑屏 60 秒",
                isOn: $state.wipeOn
            )

            glassToggle(
                title: "后台干",
                subtitle: "阻止系统睡眠",
                isOn: $state.awakeOn
            )
        }
        .frame(maxWidth: .infinity, minHeight: MenuPanelLayout.controlsHeight, maxHeight: MenuPanelLayout.controlsHeight)
    }

    private func section<SectionContent: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> SectionContent
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return VStack(alignment: .leading, spacing: MenuPanelLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 8)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            content()
        }
        .padding(MenuPanelLayout.sectionPadding)
        .background(shape.fill(sectionBackground))
        .overlay(shape.strokeBorder(sectionBorder, lineWidth: 1))
        .clipShape(shape)
    }

    private func glassToggle(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: MenuPanelLayout.controlsHeight, maxHeight: MenuPanelLayout.controlsHeight)
        .background(shape.fill(sectionBackground))
        .overlay(shape.strokeBorder(sectionBorder, lineWidth: 1))
        .clipShape(shape)
    }

    private var sectionBackground: Color {
        Color.primary.opacity(0.055)
    }

    private var sectionBorder: Color {
        Color.white.opacity(0.14)
    }

    private var livePowerSummary: String {
        let cpu = hardware.displayText(for: .cpu)
        let gpu = hardware.displayText(for: .gpu)
        return "CPU \(cpu)  GPU \(gpu)"
    }

    private var displaySummary: String {
        displayControl.hasExternalDisplay ? displayControl.selectedDisplayName : "未连接"
    }
}

struct HeaderBadgeStack: View {
    let powerSummary: String
    let displaySummary: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            badge(title: "功耗", value: powerSummary)
            badge(title: "显示器", value: displaySummary)
        }
    }

    private func badge(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct CableListView: View {
    var items: [CableDisplayItem]

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: MenuPanelLayout.cableGridSpacing, alignment: .top),
            count: HardwareMenuLayout.cableColumnCount(itemCount: items.count)
        )

        LazyVGrid(columns: columns, alignment: .leading, spacing: MenuPanelLayout.cableGridSpacing) {
            ForEach(items) { item in
                CableRowView(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CableRowView: View {
    var item: CableDisplayItem

    private var visibleLines: [String] {
        Array(item.lines.prefix(4))
    }

    private var accentColor: Color {
        switch item.cableType {
        case .active:
            return .purple
        case .opticallyIsolated:
            return .green
        case .passive, .unknown, .none:
            break
        }

        switch item.kind {
        case .magSafe, .power:
            return .orange
        case .usbC:
            return .blue
        case .thunderbolt:
            return .indigo
        case .display:
            return .teal
        case .unknown:
            return .gray
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .magSafe, .power:
            return "bolt.fill"
        case .usbC:
            return "cable.connector"
        case .thunderbolt:
            return "bolt.horizontal.circle"
        case .display:
            return "display"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var badgeText: String? {
        switch item.cableType {
        case .active:
            return "主动线"
        case .passive:
            return "被动线"
        case .opticallyIsolated:
            return "光隔离"
        case .unknown, .none:
            break
        }

        switch item.kind {
        case .magSafe:
            return "MagSafe"
        case .power:
            return "供电"
        case .usbC:
            return "USB-C"
        case .thunderbolt:
            return "TB / USB4"
        case .display:
            return "显示"
        case .unknown:
            return nil
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 18, height: 18)
                    .background(accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(0.10), in: Capsule(style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(visibleLines.indices, id: \.self) { index in
                    let line = visibleLines[index]
                    Text(line)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            maxWidth: .infinity,
            minHeight: MenuPanelLayout.cableRowHeight,
            maxHeight: MenuPanelLayout.cableRowHeight,
            alignment: .topLeading
        )
        .background(cardShape.fill(Color.primary.opacity(0.055)))
        .overlay(
            cardShape.strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
        )
        .clipShape(cardShape)
        .accessibilityElement(children: .combine)
    }
}
