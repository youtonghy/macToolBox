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

    var subtitle: String {
        switch self {
        case .home:
            return "总览面板能力与交互"
        case .cables:
            return "查看连接中的端口与协商细节"
        case .display:
            return "调节外接屏亮度、对比度与音量"
        case .general:
            return "启动偏好与当前状态"
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
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(size: 22, weight: .semibold))
                Text("ToolBox")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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

            SettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("版本 1.0")
                        .font(.system(size: 12, weight: .semibold))
                    Text("菜单栏常驻，轻量操作")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.contentSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTab.title)
                    .font(.system(size: 24, weight: .semibold))
                Text(currentTab.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: "菜单栏面板", subtitle: "主面板与快捷入口") {
                    VStack(spacing: 8) {
                        SettingsFeatureRow(
                            symbolName: "cursorarrow.click.2",
                            accent: Color(nsColor: .systemBlue),
                            title: "左键打开主面板",
                            description: "查看功耗曲线、线缆状态和显示器控制，点外部自动收起。"
                        )
                        SettingsFeatureRow(
                            symbolName: "button.horizontal.top.press",
                            accent: Color(nsColor: .systemPurple),
                            title: "右键快速菜单",
                            description: "直接切换“擦屏幕”和“后台干”，或进入设置、退出应用。"
                        )
                    }
                }

                SettingsSection(title: "当前能力", subtitle: "围绕高频操作做轻量组织") {
                    VStack(spacing: 8) {
                        SettingsFeatureRow(
                            symbolName: "cpu",
                            accent: Color(nsColor: .systemOrange),
                            title: "硬件概览",
                            description: "CPU / GPU 功耗以图表和即时读数呈现，可在实时值与平均值之间切换。"
                        )
                        SettingsFeatureRow(
                            symbolName: "cable.connector",
                            accent: Color(nsColor: .systemPurple),
                            title: "线缆详情",
                            description: "在设置页展开端口规格、PD 协商、数据与显示链路等完整状态。"
                        )
                        SettingsFeatureRow(
                            symbolName: "display.2",
                            accent: Color(nsColor: .systemTeal),
                            title: "外接显示器控制",
                            description: "菜单快捷调节，设置页提供更大的滑杆和更完整的显示器状态。"
                        )
                    }
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
                            title: "没有检测到活动线缆",
                            description: "接入 USB-C / Thunderbolt / MagSafe 设备后，这里会显示完整协商状态。"
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
                        title: "暂无更多细节",
                        description: "该端口当前只报告了基础连接信息。"
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
                            title: "没有外接显示器",
                            description: "连接支持 DDC/VCP 的外接屏后，可在这里调节亮度、对比度和音量。"
                        )
                    }
                }

                if model.hasExternalDisplay {
                    SettingsSection(title: "实时控制", subtitle: model.selectedDisplayName) {
                        VStack(spacing: 10) {
                            SettingsInnerCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.statusText)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("通过 DDC/VCP 写回硬件；部分显示器为 write-only，读数可能是估算值。")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }

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

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("静音")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(model.muteAvailable ? "切换显示器音频静音" : "当前显示器不支持静音控制")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }

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

                if model.hasExternalDisplay {
                    SettingsSection(title: "当前选择", subtitle: "状态摘要") {
                        VStack(spacing: 8) {
                            SettingsValueRow(
                                title: "显示器",
                                value: model.selectedDisplayName,
                                accent: Color(nsColor: .systemTeal)
                            )
                            SettingsValueRow(
                                title: "控制通道",
                                value: model.statusText,
                                accent: Color(nsColor: .systemBlue)
                            )
                            SettingsValueRow(
                                title: "静音",
                                value: model.muteAvailable
                                    ? (model.selectedMuted ? "已静音" : "未静音")
                                    : "不可用",
                                accent: model.muteAvailable
                                    ? Color(nsColor: .systemPink)
                                    : Color.secondary
                            )
                        }
                    }
                }
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

    private var statusAccent: Color {
        if mediaKeys.isTapActive {
            return Color(nsColor: .systemGreen)
        }
        if mediaKeys.needsPermission {
            return Color(nsColor: .systemOrange)
        }
        return Color.secondary
    }

    private var permissionAccent: Color {
        switch mediaKeys.inputMonitoringStatus {
        case .granted:
            return Color(nsColor: .systemGreen)
        case .denied:
            return Color(nsColor: .systemRed)
        case .unknown:
            return Color(nsColor: .systemOrange)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            SettingsInnerCard {
                HStack(spacing: 12) {
                    SettingsIconBadge(
                        systemName: "keyboard",
                        accent: permissionAccent,
                        emphasized: mediaKeys.inputMonitoringStatus == .granted
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("输入监控")
                            .font(.system(size: 13, weight: .semibold))
                        Text("拦截 F1/F2 亮度与音量媒体键，转发给外接显示器。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Text(mediaKeys.inputMonitoringStatus.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(permissionAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(permissionAccent.opacity(0.12))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(permissionAccent.opacity(0.22), lineWidth: 1)
                        )
                }
            }

            SettingsValueRow(
                title: "媒体键监听",
                value: mediaKeys.statusText,
                accent: statusAccent
            )

            HStack(spacing: 8) {
                Button {
                    mediaKeys.openInputMonitoringSettings()
                } label: {
                    permissionActionLabel(
                        symbolName: "arrow.up.right.square",
                        title: "打开系统设置",
                        accent: Color(nsColor: .systemBlue)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    mediaKeys.refreshAndRetry(promptIfNeeded: true)
                } label: {
                    permissionActionLabel(
                        symbolName: "arrow.clockwise",
                        title: "重新检测",
                        accent: Color(nsColor: .systemIndigo)
                    )
                }
                .buttonStyle(.plain)
            }

            if mediaKeys.needsPermission || mediaKeys.inputMonitoringStatus != .granted {
                SettingsInnerCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("授权后仍失败？")
                            .font(.system(size: 12, weight: .bold))
                        Text("1. 在「隐私与安全性 → 输入监控」中确认 ToolBox 开关已打开。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("2. 调试版可能有多条记录，只打开当前正在运行的那一项。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("3. 刚打开开关后若仍失败，完全退出再打开 ToolBox。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            mediaKeys.refreshAndRetry(promptIfNeeded: false)
        }
    }

    private func permissionActionLabel(
        symbolName: String,
        title: String,
        accent: Color
    ) -> some View {
        HStack(spacing: 10) {
            SettingsIconBadge(
                systemName: symbolName,
                accent: accent,
                emphasized: false
            )

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                .fill(SettingsChrome.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                .strokeBorder(SettingsChrome.cardBorder, lineWidth: 1)
        )
        .contentShape(
            RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
        )
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var mediaKeys: DisplayControlMediaKeyController

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: "权限", subtitle: "捕获亮度 / 音量媒体键") {
                    MediaKeyPermissionSection(mediaKeys: mediaKeys)
                }

                SettingsSection(title: "启动", subtitle: "登录后保持菜单栏常驻") {
                    VStack(spacing: 8) {
                        SettingsInnerCard {
                            HStack(spacing: 12) {
                                SettingsIconBadge(
                                    systemName: "power.circle.fill",
                                    accent: Color(nsColor: .systemGreen),
                                    emphasized: launchAtLogin.isEnabled
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("开机自启动")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("登录 macOS 后自动启动 ToolBox。")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }

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

                        Button {
                            SMAppService.openSystemSettingsLoginItems()
                        } label: {
                            HStack(spacing: 10) {
                                SettingsIconBadge(
                                    systemName: "arrow.up.right.square",
                                    accent: Color(nsColor: .systemBlue),
                                    emphasized: false
                                )

                                Text("打开系统登录项设置")
                                    .font(.system(size: 13, weight: .semibold))

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                                    .fill(SettingsChrome.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                                    .strokeBorder(SettingsChrome.cardBorder, lineWidth: 1)
                            )
                            .contentShape(
                                RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                SettingsSection(title: "当前状态", subtitle: "确认设置已经生效") {
                    VStack(spacing: 8) {
                        SettingsValueRow(
                            title: "开机启动",
                            value: launchAtLogin.isEnabled ? "已启用" : "未启用",
                            accent: launchAtLogin.isEnabled
                                ? Color(nsColor: .systemGreen)
                                : Color.secondary
                        )
                        SettingsValueRow(
                            title: "应用形态",
                            value: "仅菜单栏",
                            accent: Color(nsColor: .systemBlue)
                        )
                        SettingsValueRow(
                            title: "窗口风格",
                            value: "液态玻璃",
                            accent: Color(nsColor: .systemIndigo)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }
}


