import AppKit
import SwiftUI

struct PopoverContent: View {
    @ObservedObject var state: FeatureState
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel
    @ObservedObject var audioRouting: AudioRoutingService
    @ObservedObject var focusMode: FocusModeCoordinator
    @ObservedObject var wifiSignal: WiFiSignalModel

    var body: some View {
        VStack(alignment: .leading, spacing: MenuPanelLayout.outerSpacing) {
            header

            VStack(alignment: .leading, spacing: MenuPanelLayout.contentSpacing) {
                hardwareSection

                if !audioRouting.menuRows.isEmpty {
                    section(title: "应用音频", subtitle: "0–300%") {
                        AudioRoutingPanel(service: audioRouting)
                            .frame(
                                height: MenuPanelLayout.audioContentHeight(
                                    rowCount: audioRouting.menuRows.count
                                ),
                                alignment: .topLeading
                            )
                    }
                }

                if !hardware.cableItems.isEmpty {
                    section(title: "线缆状态") {
                        CableListView(items: hardware.visibleCableItems)
                            .frame(height: hardware.cableListHeight)
                    }
                }

                section(
                    title: "Wi-Fi 信号",
                    subtitle: wifiSignal.snapshot.state == .connected
                        ? "\(wifiSignal.snapshot.identityText) · \(wifiSignal.snapshot.band.displayText)"
                        : "当前连接"
                ) {
                    WiFiSignalPopoverView(model: wifiSignal)
                }

                section(
                    title: "显示器控制",
                    subtitle: displayControl.hasExternalDisplay ? displayControl.selectedDisplayName : "系统显示设置"
                ) {
                    DisplayControlPanel(model: displayControl)
                }
            }

            controlsBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }

    private var header: some View {
        Text("ToolBox")
            .font(.system(size: 22, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .frame(height: MenuPanelLayout.headerHeight, alignment: .center)
    }

    private var hardwareSection: some View {
        section(title: "芯片功耗") {
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
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            circularControlButton(
                systemName: "rectangle.inset.filled",
                title: "擦屏幕",
                subtitle: "黑屏 60 秒",
                isOn: $state.wipeOn,
                accent: Color(nsColor: .systemIndigo)
            )

            circularControlButton(
                systemName: "cup.and.saucer.fill",
                title: "后台干",
                subtitle: "阻止系统睡眠",
                isOn: $state.awakeOn,
                accent: Color(nsColor: .systemOrange)
            )

            circularControlButton(
                systemName: "scope",
                title: "聚焦模式",
                subtitle: "突出当前使用的显示器",
                isOn: Binding(
                    get: { focusMode.isEnabled },
                    set: { focusMode.setEnabled($0) }
                ),
                accent: Color(nsColor: .systemTeal)
            )
        }
        .frame(maxWidth: .infinity, minHeight: MenuPanelLayout.controlsHeight, maxHeight: MenuPanelLayout.controlsHeight)
    }

    private func section<SectionContent: View>(
        title: String,
        subtitle: String = "",
        @ViewBuilder content: () -> SectionContent
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return VStack(alignment: .leading, spacing: MenuPanelLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 8)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            content()
        }
        .padding(MenuPanelLayout.sectionPadding)
        .background(shape.fill(sectionBackground))
        .overlay(shape.strokeBorder(sectionBorder, lineWidth: 1))
        .clipShape(shape)
    }

    private func circularControlButton(
        systemName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        accent: Color
    ) -> some View {
        let size = MenuPanelLayout.controlButtonSize
        let active = isOn.wrappedValue

        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.78))
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(active ? accent.opacity(0.92) : sectionBackground)
                )
                .overlay(
                    Circle()
                        .strokeBorder(active ? accent.opacity(0.4) : sectionBorder, lineWidth: 1)
                )
                .shadow(color: active ? accent.opacity(0.28) : .clear, radius: 7, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(title)：\(subtitle)")
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityValue(active ? "已启用" : "已关闭")
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.16), value: active)
    }

    private var sectionBackground: Color {
        Color.primary.opacity(0.055)
    }

    private var sectionBorder: Color {
        Color.white.opacity(0.14)
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
