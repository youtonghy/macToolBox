import ServiceManagement
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case home
    case cables
    case display
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .cables:
            return "线缆"
        case .display:
            return "显示器"
        case .general:
            return "通用"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .cables:
            return "cable.connector"
        case .display:
            return "display"
        case .general:
            return "switch.2"
        }
    }

    var accent: Color {
        switch self {
        case .home:
            return Color(nsColor: .systemBlue)
        case .cables:
            return Color(nsColor: .systemPurple)
        case .display:
            return Color(nsColor: .systemTeal)
        case .general:
            return Color(nsColor: .systemOrange)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel
    @ObservedObject var mediaKeys: DisplayControlMediaKeyController
    @ObservedObject var brightnessSchedule: BrightnessScheduleCoordinator
    @AppStorage("settings.selectedTab") private var selectedTab = SettingsTab.home.rawValue
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    private var currentTab: SettingsTab {
        SettingsTab(rawValue: selectedTab) ?? .home
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsChrome.contentSpacing) {
            sidebar
                .frame(width: SettingsChrome.sidebarWidth)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(Color.clear)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
            Text("设置")
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            SettingsCard {
                VStack(spacing: 8) {
                    ForEach(SettingsTab.allCases) { tab in
                        sidebarButton(for: tab)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.contentSpacing) {
            Text(currentTab.title)
                .font(.system(size: 24, weight: .semibold))
                .padding(.horizontal, 2)

            Group {
                switch currentTab {
                case .home:
                    SettingsHomeView()
                case .cables:
                    SettingsCablesView(hardware: hardware)
                case .display:
                    SettingsDisplayView(
                        model: displayControl,
                        brightnessSchedule: brightnessSchedule,
                        launchAtLogin: launchAtLogin
                    )
                case .general:
                    GeneralSettingsView(launchAtLogin: launchAtLogin, mediaKeys: mediaKeys)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        let isSelected = tab == currentTab

        return Button {
            selectedTab = tab.rawValue
        } label: {
            HStack(spacing: 12) {
                SettingsIconBadge(
                    systemName: tab.symbolName,
                    accent: isSelected ? tab.accent : Color.primary.opacity(0.55),
                    emphasized: isSelected
                )

                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.20) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
    }
}

private struct SettingsHomeView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            SettingsSection(title: "功能") {
                VStack(spacing: 8) {
                    SettingsFeatureRow(
                        symbolName: "cpu",
                        accent: Color(nsColor: .systemOrange),
                        title: "芯片功耗"
                    )
                    SettingsFeatureRow(
                        symbolName: "cable.connector",
                        accent: Color(nsColor: .systemPurple),
                        title: "线缆状态"
                    )
                    SettingsFeatureRow(
                        symbolName: "display.2",
                        accent: Color(nsColor: .systemTeal),
                        title: "显示器控制"
                    )
                    SettingsFeatureRow(
                        symbolName: "rectangle.inset.filled",
                        accent: Color(nsColor: .systemIndigo),
                        title: "擦屏幕"
                    )
                    SettingsFeatureRow(
                        symbolName: "cup.and.saucer.fill",
                        accent: Color(nsColor: .systemOrange),
                        title: "后台干"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }
}

private struct SettingsCablesView: View {
    @ObservedObject var hardware: HardwareMenuModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(
                    title: "连接概览",
                    subtitle: hardware.cableItems.isEmpty ? "当前无活动链路" : "共 \(hardware.cableItems.count) 条连接"
                ) {
                    if let adapter = hardware.powerAdapterGroup {
                        SettingsDetailGroupCard(group: adapter, accent: Color(nsColor: .systemOrange))
                    } else if hardware.cableItems.isEmpty {
                        SettingsEmptyState(
                            symbolName: "cable.connector.slash",
                            title: "无活动线缆"
                        )
                    } else {
                        SettingsValueRow(
                            title: "活动端口",
                            value: "\(hardware.cableItems.count)",
                            accent: Color(nsColor: .systemPurple)
                        )
                    }
                }

                ForEach(hardware.cableItems) { item in
                    SettingsCableDetailCard(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }
}

private struct SettingsCableDetailCard: View {
    let item: CableDisplayItem

    private var accent: Color {
        switch item.kind {
        case .magSafe, .power:
            return Color(nsColor: .systemOrange)
        case .usbC:
            return Color(nsColor: .systemBlue)
        case .thunderbolt:
            return Color(nsColor: .systemIndigo)
        case .display:
            return Color(nsColor: .systemTeal)
        case .unknown:
            return Color.secondary
        }
    }

    private var kindLabel: String {
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
            return "未知"
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

    var body: some View {
        SettingsSection(title: item.title, subtitle: kindLabel) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SettingsIconBadge(systemName: symbolName, accent: accent, emphasized: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                        if !item.lines.isEmpty {
                            Text(item.lines.prefix(2).joined(separator: "  ·  "))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if item.detailGroups.isEmpty {
                    SettingsEmptyState(
                        symbolName: "info.circle",
                        title: "暂无更多细节"
                    )
                } else {
                    ForEach(item.detailGroups) { group in
                        SettingsDetailGroupCard(group: group, accent: accent)
                    }
                }
            }
        }
    }
}

private struct SettingsDetailGroupCard: View {
    let group: CableDetailGroup
    let accent: Color

    var body: some View {
        SettingsInnerCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(group.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)

                VStack(spacing: 6) {
                    ForEach(group.rows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text(row.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)

                            Text(row.value)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsDisplayView: View {
    @ObservedObject var model: DisplayControlMenuModel
    @ObservedObject var brightnessSchedule: BrightnessScheduleCoordinator
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(
                    title: "外接显示器",
                    subtitle: model.hasExternalDisplay
                        ? "\(model.displayItems.count) 台可管理"
                        : "未检测到外接屏"
                ) {
                    if model.hasExternalDisplay {
                        VStack(spacing: 8) {
                            ForEach(model.displayItems) { item in
                                displayPickerRow(item)
                            }
                        }
                    } else {
                        SettingsEmptyState(
                            symbolName: "display.trianglebadge.exclamationmark",
                            title: "无外接显示器"
                        )
                    }
                }

                if model.hasExternalDisplay {
                    SettingsSection(title: "实时控制", subtitle: model.selectedDisplayName) {
                        VStack(spacing: 10) {
                            ForEach(model.sliderItems) { item in
                                displaySliderCard(item)
                            }

                            SettingsInnerCard {
                                HStack(spacing: 12) {
                                    SettingsIconBadge(
                                        systemName: model.selectedMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                        accent: Color(nsColor: .systemPink),
                                        emphasized: model.muteAvailable
                                    )

                                    Text("静音")
                                        .font(.system(size: 13, weight: .semibold))

                                    Spacer(minLength: 12)

                                    Button {
                                        model.toggleMute()
                                    } label: {
                                        Text(model.selectedMuted ? "取消静音" : "静音")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(
                                                        model.muteAvailable
                                                            ? Color(nsColor: .systemPink).opacity(0.16)
                                                            : Color.primary.opacity(0.06)
                                                    )
                                            )
                                            .overlay(
                                                Capsule(style: .continuous)
                                                    .strokeBorder(
                                                        model.muteAvailable
                                                            ? Color(nsColor: .systemPink).opacity(0.28)
                                                            : Color.white.opacity(0.10),
                                                        lineWidth: 1
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!model.muteAvailable)
                                }
                            }
                        }
                    }
                }

                BrightnessScheduleSettingsView(
                    coordinator: brightnessSchedule,
                    launchAtLogin: launchAtLogin
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }

    private func displayPickerRow(_ item: DisplayControlPickerItem) -> some View {
        let isSelected = model.selectedDisplayID == item.id

        return Button {
            model.select(displayID: item.id)
        } label: {
            HStack(spacing: 12) {
                SettingsIconBadge(
                    systemName: "display",
                    accent: isSelected ? Color(nsColor: .systemTeal) : Color.secondary,
                    emphasized: isSelected
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(item.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemTeal))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : SettingsChrome.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color(nsColor: .systemTeal).opacity(0.35) : SettingsChrome.cardBorder,
                        lineWidth: 1
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func displaySliderCard(_ item: DisplayControlSliderItem) -> some View {
        SettingsInnerCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SettingsIconBadge(
                        systemName: item.symbolName,
                        accent: sliderAccent(for: item.kind),
                        emphasized: item.isEnabled
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(chineseTitle(for: item.kind))
                            .font(.system(size: 13, weight: .semibold))
                        if let reason = item.unavailableReason, !item.isEnabled {
                            Text(reason)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(item.percentText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(item.isEnabled ? .primary : .secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: binding(for: item.kind),
                    in: 0...1,
                    step: max(item.step, 0.01)
                )
                .disabled(!item.isEnabled)
            }
        }
    }

    private func binding(for kind: DisplayControlKind) -> Binding<Double> {
        Binding(
            get: {
                model.sliderItems.first(where: { $0.kind == kind })?.value ?? 0
            },
            set: { newValue in
                model.setValue(kind: kind, value: newValue)
            }
        )
    }

    private func chineseTitle(for kind: DisplayControlKind) -> String {
        switch kind {
        case .brightness:
            return "亮度"
        case .contrast:
            return "对比度"
        case .volume:
            return "音量"
        case .mute:
            return "静音"
        }
    }

    private func sliderAccent(for kind: DisplayControlKind) -> Color {
        switch kind {
        case .brightness:
            return Color(nsColor: .systemOrange)
        case .contrast:
            return Color(nsColor: .systemIndigo)
        case .volume:
            return Color(nsColor: .systemPink)
        case .mute:
            return Color(nsColor: .systemPink)
        }
    }
}

private struct MediaKeyPermissionSection: View {
    @ObservedObject var mediaKeys: DisplayControlMediaKeyController

    private var isReady: Bool {
        mediaKeys.isTapActive
    }

    private var accent: Color {
        isReady ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
    }

    var body: some View {
        SettingsInnerCard {
            HStack(spacing: 12) {
                SettingsIconBadge(
                    systemName: isReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    accent: accent,
                    emphasized: isReady
                )

                Text("媒体键权限")
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 12)

                Text(isReady ? "已授权" : "未授权")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(accent.opacity(0.12))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(accent.opacity(0.22), lineWidth: 1)
                    )

                if !isReady {
                    Button("请求权限") {
                        mediaKeys.openRequiredPermissionSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            mediaKeys.refreshAndRetry(promptIfNeeded: false)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var mediaKeys: DisplayControlMediaKeyController

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: "权限") {
                    MediaKeyPermissionSection(mediaKeys: mediaKeys)
                }

                SettingsSection(title: "启动") {
                    SettingsInnerCard {
                        HStack(spacing: 12) {
                            SettingsIconBadge(
                                systemName: "power.circle.fill",
                                accent: Color(nsColor: .systemGreen),
                                emphasized: launchAtLogin.isEnabled
                            )

                            Text("开机自启动")
                                .font(.system(size: 13, weight: .semibold))

                            Spacer(minLength: 12)

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { launchAtLogin.isEnabled },
                                    set: { launchAtLogin.setEnabled($0) }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }
}

