import AppKit
import SwiftUI

/// Shared section chrome for menu-bar panel sections. Used by the live panel
/// and by the settings customization editor so both render identical cards.
struct MenuPanelSection<SectionContent: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: SectionContent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: MenuPanelLayout.sectionSpacing) {
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

            content
        }
        .padding(MenuPanelLayout.sectionPadding)
        .background(shape.fill(MenuPanelSectionTheme.background))
        .overlay(shape.strokeBorder(MenuPanelSectionTheme.border, lineWidth: 1))
        .clipShape(shape)
    }
}

enum MenuPanelSectionTheme {
    static var background: Color { Color.primary.opacity(0.055) }
    static var border: Color { Color.white.opacity(0.14) }
}

/// Renders the live content of one menu-bar element. This is the single
/// rendering dispatch shared by the real menu-bar panel and the settings
/// editor; the editor only swaps the interaction layer (`isInteractive`).
struct MenuBarElementSectionView: View {
    let element: MenuBarElementID
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel
    @ObservedObject var audioRouting: AudioRoutingService
    @ObservedObject var focusMode: FocusModeCoordinator
    @ObservedObject var wifiSignal: WiFiSignalModel
    @ObservedObject var networkLocation: NetworkLocationModel
    @ObservedObject var state: FeatureState
    var isInteractive: Bool

    var body: some View {
        switch element {
        case .chipPower:
            chipPowerSection
        case .appAudio:
            audioSection
        case .cableStatus:
            cableSection
        case .wifiSignal:
            wifiSection
        case .displayControl:
            displaySection
        case .quickControls:
            quickControlsSection
        }
    }

    // MARK: - 芯片功耗

    private var chipPowerSection: some View {
        MenuPanelSection(title: "芯片功耗") {
            HStack(spacing: 10) {
                PowerChartRepresentable(
                    title: "CPU",
                    samples: hardware.samples(for: .cpu),
                    displayText: hardware.displayText(for: .cpu),
                    isAverageMode: hardware.isAverageMode(.cpu),
                    accentColor: .systemOrange,
                    onToggle: isInteractive ? { hardware.toggleDisplayMode(for: .cpu) } : {}
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: MenuPanelLayout.chartHeight,
                    idealHeight: MenuPanelLayout.chartHeight,
                    maxHeight: MenuPanelLayout.chartHeight
                )
                .clipped()

                PowerChartRepresentable(
                    title: "GPU",
                    samples: hardware.samples(for: .gpu),
                    displayText: hardware.displayText(for: .gpu),
                    isAverageMode: hardware.isAverageMode(.gpu),
                    accentColor: .systemTeal,
                    onToggle: isInteractive ? { hardware.toggleDisplayMode(for: .gpu) } : {}
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: MenuPanelLayout.chartHeight,
                    idealHeight: MenuPanelLayout.chartHeight,
                    maxHeight: MenuPanelLayout.chartHeight
                )
                .clipped()
            }
        }
    }

    // MARK: - 应用音频

    private var audioSection: some View {
        MenuPanelSection(title: "应用音频") {
            AudioRoutingPanel(service: audioRouting)
                .frame(
                    height: MenuPanelLayout.audioContentHeight(
                        rowCount: audioRouting.menuRows.count,
                        isLiteMode: audioRouting.isLiteMode
                    ),
                    alignment: .topLeading
                )
        }
        .disabled(!isInteractive)
    }

    // MARK: - 线缆状态

    private var cableSection: some View {
        MenuPanelSection(title: "线缆状态") {
            CableListView(items: hardware.visibleCableItems)
                .frame(height: hardware.cableListHeight)
        }
    }

    // MARK: - Wi-Fi 信号

    private var wifiSection: some View {
        MenuPanelSection(
            title: "Wi-Fi 信号",
            subtitle: wifiSignal.snapshot.state == .connected
                ? "\(wifiSignal.snapshot.identityText) · \(wifiSignal.snapshot.band.displayText)"
                : "当前连接"
        ) {
            WiFiSignalPopoverView(model: wifiSignal)
        }
    }

    // MARK: - 显示器控制

    private var displaySection: some View {
        MenuPanelSection(
            title: "显示器控制",
            subtitle: displayControl.selectedDisplayName
        ) {
            DisplayControlPanel(model: displayControl)
        }
        .disabled(!isInteractive)
    }

    // MARK: - 快捷控制

    private var quickControlsSection: some View {
        MenuQuickControlsBar(
            state: state,
            focusMode: focusMode,
            networkLocation: networkLocation,
            isInteractive: isInteractive
        )
    }
}

/// The compact quick-controls row: the network-location switcher sits at the
/// leading edge, the circular toggles at the trailing edge. Rendered live in
/// the menu-bar panel and read-only inside the settings editor card.
struct MenuQuickControlsBar: View {
    @ObservedObject var state: FeatureState
    @ObservedObject var focusMode: FocusModeCoordinator
    @ObservedObject var networkLocation: NetworkLocationModel
    var isInteractive: Bool

    var body: some View {
        HStack(spacing: 10) {
            locationSwitcher

            Spacer(minLength: 0)

            circularControlButton(
                systemName: "rectangle.inset.filled",
                title: "擦屏幕",
                subtitle: "黑屏 60 秒",
                isOn: Binding(
                    get: { state.wipeOn },
                    set: { if isInteractive { state.wipeOn = $0 } }
                ),
                accent: Color(nsColor: .systemIndigo)
            )

            circularControlButton(
                systemName: "cup.and.saucer.fill",
                title: "后台干",
                subtitle: "阻止系统睡眠",
                isOn: Binding(
                    get: { state.awakeOn },
                    set: { if isInteractive { state.awakeOn = $0 } }
                ),
                accent: Color(nsColor: .systemOrange)
            )

            circularControlButton(
                systemName: "scope",
                title: "聚焦模式",
                subtitle: "突出当前使用的显示器",
                isOn: Binding(
                    get: { focusMode.isEnabled },
                    set: { if isInteractive { focusMode.setEnabled($0) } }
                ),
                accent: Color(nsColor: .systemTeal)
            )
        }
        .frame(
            maxWidth: .infinity,
            minHeight: MenuPanelLayout.controlsHeight,
            maxHeight: MenuPanelLayout.controlsHeight
        )
    }

    /// Capsule switcher for the active network location. Creating locations
    /// and SSID rules lives in Settings → 网络位置.
    private var locationSwitcher: some View {
        let pill = Capsule(style: .continuous)

        return Menu {
            ForEach(networkLocation.snapshot.locations, id: \.self) { name in
                Toggle(
                    name,
                    isOn: Binding(
                        get: { networkLocation.snapshot.current == name },
                        set: { isOn in
                            if isOn { networkLocation.switchTo(name) }
                        }
                    )
                )
            }
        } label: {
            HStack(spacing: 7) {
                if networkLocation.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12, weight: .semibold))
                }

                Text(networkLocation.snapshot.current ?? L10n.string("未知"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            .foregroundStyle(
                networkLocation.errorMessage != nil
                    ? Color.red
                    : Color.primary.opacity(0.78)
            )
            .padding(.horizontal, 13)
            .frame(height: MenuPanelLayout.controlButtonSize)
            .background(pill.fill(MenuPanelSectionTheme.background))
            .overlay(pill.strokeBorder(MenuPanelSectionTheme.border, lineWidth: 1))
            .contentShape(pill)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isInteractive || networkLocation.snapshot.locations.isEmpty)
        .help(locationSwitcherHelp)
        .accessibilityLabel(L10n.string("网络位置"))
        .accessibilityValue(networkLocation.snapshot.current ?? L10n.string("未知"))
    }

    private var locationSwitcherHelp: String {
        networkLocation.errorMessage
            ?? networkLocation.lastAutoSwitchMessage
            ?? L10n.string("切换网络位置")
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
                        .fill(active ? accent.opacity(0.92) : MenuPanelSectionTheme.background)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            active ? accent.opacity(0.4) : MenuPanelSectionTheme.border,
                            lineWidth: 1
                        )
                )
                .shadow(color: active ? accent.opacity(0.28) : .clear, radius: 7, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .help("\(title)：\(subtitle)")
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityValue(active ? "已启用" : "已关闭")
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.16), value: active)
    }
}
