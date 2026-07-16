import ServiceManagement
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case home
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .general:
            return "通用"
        }
    }

    var subtitle: String {
        switch self {
        case .home:
            return "总览"
        case .general:
            return "启动和偏好"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .general:
            return "switch.2"
        }
    }
}

struct SettingsView: View {
    @AppStorage("settings.selectedTab") private var selectedTab = SettingsTab.home.rawValue
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    private var currentTab: SettingsTab {
        SettingsTab(rawValue: selectedTab) ?? .home
    }

    var body: some View {
        HStack(spacing: 18) {
            sidebar
                .frame(width: 188)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(Color.clear)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ToolBox")
                    .font(.system(size: 24, weight: .semibold))
                Text("系统工具与硬件概览")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarButton(for: tab)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("版本 1.0")
                    .font(.system(size: 11, weight: .semibold))
                Text("菜单栏常驻，轻量操作。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsGlass.sectionBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SettingsGlass.sectionBorder, lineWidth: 1)
            )
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentTab.title)
                        .font(.system(size: 26, weight: .semibold))
                    Text(currentTabDescription)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(currentTab.subtitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
            }

            Group {
                switch currentTab {
                case .home:
                    SettingsHomeView()
                case .general:
                    GeneralSettingsView(launchAtLogin: launchAtLogin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var currentTabDescription: String {
        switch currentTab {
        case .home:
            return "概览菜单栏弹窗、快捷入口和当前信息组织。"
        case .general:
            return "管理开机启动、登录项入口和窗口行为偏好。"
        }
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab.rawValue
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(tab.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(sidebarBackground(for: tab))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(sidebarBorder(for: tab), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sidebarBackground(for tab: SettingsTab) -> some ShapeStyle {
        tab == currentTab ? Color.white.opacity(0.11) : SettingsGlass.sectionBackground
    }

    private func sidebarBorder(for tab: SettingsTab) -> Color {
        tab == currentTab ? Color.white.opacity(0.22) : SettingsGlass.sectionBorder
    }
}

private struct SettingsHomeView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(title: "菜单栏面板", subtitle: "现在使用 AppKit 玻璃浮层承载实时状态") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsFeatureRow(
                            symbolName: "cursorarrow.click.2",
                            title: "左键打开主面板",
                            description: "查看功耗曲线、线缆状态和显示器控制，点外部自动收起。"
                        )
                        SettingsFeatureRow(
                            symbolName: "button.horizontal.top.press",
                            title: "右键快速菜单",
                            description: "直接切换“擦屏幕”和“后台干”，或进入设置、退出应用。"
                        )
                    }
                }

                SettingsSection(title: "当前能力", subtitle: "围绕高频操作做轻量组织") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsFeatureRow(
                            symbolName: "cpu",
                            title: "硬件概览",
                            description: "CPU / GPU 功耗以图表和即时读数呈现，可在实时值与平均值之间切换。"
                        )
                        SettingsFeatureRow(
                            symbolName: "display.2",
                            title: "外接显示器控制",
                            description: "在菜单中直接选择外接屏并调整亮度、对比度、音量与静音。"
                        )
                        SettingsFeatureRow(
                            symbolName: "sparkles.rectangle.stack",
                            title: "统一玻璃风格",
                            description: "菜单浮层和设置窗口共享同一套液态玻璃容器、描边和阴影层次。"
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(title: "启动", subtitle: "登录后自动保持菜单栏常驻") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("开机自启动")
                                .font(.system(size: 13, weight: .semibold))
                            Text("登录 macOS 后自动启动 ToolBox，并保持菜单栏常驻。")
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

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    Button {
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.square")
                            Text("打开系统登录项设置")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsSection(title: "当前状态", subtitle: "帮助确认设置已经生效") {
                    SettingsValueRow(title: "开机启动", value: launchAtLogin.isEnabled ? "已启用" : "未启用")
                    SettingsValueRow(title: "应用形态", value: "仅菜单栏显示，不进入 Dock")
                    SettingsValueRow(title: "设置窗口", value: "液态玻璃样式")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 8)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(16)
        .background(SettingsGlass.sectionBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SettingsGlass.sectionBorder, lineWidth: 1)
        )
    }
}

private struct SettingsFeatureRow: View {
    let symbolName: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.vertical, 2)
    }
}

private enum SettingsGlass {
    static let sectionBackground = Color.primary.opacity(0.055)
    static let sectionBorder = Color.white.opacity(0.14)
}
