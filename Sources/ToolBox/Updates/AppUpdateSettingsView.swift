import AppKit
import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject var updater: AppUpdateCoordinator

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: "ToolBox") {
                    SettingsInnerCard {
                        HStack(spacing: 14) {
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("ToolBox")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("版本 \(updater.currentVersion)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                SettingsSection(title: "自动更新") {
                    VStack(spacing: 8) {
                        SettingsInnerCard {
                            HStack(spacing: 12) {
                                SettingsIconBadge(
                                    systemName: "arrow.triangle.2.circlepath",
                                    accent: Color(nsColor: .systemBlue),
                                    emphasized: updater.automaticallyChecks
                                )
                                Text("自动检查更新")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 8)
                                Toggle("", isOn: $updater.automaticallyChecks)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }

                        SettingsInnerCard {
                            HStack(spacing: 12) {
                                SettingsIconBadge(
                                    systemName: "arrow.down.circle.fill",
                                    accent: Color(nsColor: .systemGreen),
                                    emphasized: updater.automaticallyDownloads
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("自动下载更新")
                                        .font(.system(size: 13, weight: .semibold))
                                    if updater.isDevelopmentBuild {
                                        Text("开发版始终只提醒，不会自动下载")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Toggle("", isOn: $updater.automaticallyDownloads)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .disabled(updater.isDevelopmentBuild)
                            }
                        }

                        SettingsInnerCard {
                            HStack(spacing: 12) {
                                SettingsIconBadge(
                                    systemName: "shippingbox.fill",
                                    accent: updater.channel == .beta
                                        ? Color(nsColor: .systemOrange)
                                        : Color(nsColor: .systemTeal),
                                    emphasized: true
                                )
                                Text("更新通道")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 8)
                                Picker("", selection: $updater.channel) {
                                    ForEach(AppUpdateChannel.allCases) { channel in
                                        Text(channel.title).tag(channel)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 180)
                            }
                        }

                        if updater.channel == .beta {
                            SettingsInnerCard {
                                HStack(alignment: .top, spacing: 12) {
                                    SettingsIconBadge(
                                        systemName: "exclamationmark.triangle.fill",
                                        accent: Color(nsColor: .systemOrange),
                                        emphasized: true
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Beta 版本可能不稳定")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("可能包含尚未充分验证的功能；Beta 通道也会接收更新的正式版。")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsSection(title: "更新状态") {
                    SettingsInnerCard {
                        HStack(spacing: 12) {
                            statusIcon
                            VStack(alignment: .leading, spacing: 3) {
                                Text(statusTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(statusDetail)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            statusAction
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }

    private var statusIcon: some View {
        Group {
            switch updater.state {
            case .checking, .downloading:
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            case .ready:
                SettingsIconBadge(systemName: "checkmark.circle.fill", accent: .green, emphasized: true)
            case .failed:
                SettingsIconBadge(systemName: "exclamationmark.circle.fill", accent: .red, emphasized: true)
            default:
                SettingsIconBadge(systemName: "info.circle.fill", accent: .blue, emphasized: true)
            }
        }
    }

    private var statusTitle: String {
        switch updater.state {
        case .idle: return "尚未检查"
        case .checking: return "正在检查更新"
        case .upToDate: return "已是最新版本"
        case .available(let version): return "发现版本 \(version)"
        case .downloading(let version): return "正在下载 \(version)"
        case .ready(let version): return "版本 \(version) 已准备好"
        case .failed: return "更新失败"
        }
    }

    private var statusDetail: String {
        switch updater.state {
        case .idle: return "连接 GitHub Release 检查最新版本。"
        case .checking: return "正在读取 GitHub Release。"
        case .upToDate: return "当前通道没有更新的版本。"
        case .available:
            return updater.isDevelopmentBuild ? "开发版只提醒，不会下载。" : "可以下载并在重启后安装。"
        case .downloading: return "下载完成后会验证应用版本和代码签名。"
        case .ready: return "重启 ToolBox 完成安装。"
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        switch updater.state {
        case .available:
            if !updater.isDevelopmentBuild {
                Button("下载") { updater.downloadAvailableUpdate() }
            } else {
                Button("检查更新") { updater.checkForUpdates() }
            }
        case .ready:
            Button("重启更新") { updater.restartAndInstall() }
                .buttonStyle(.borderedProminent)
        case .checking, .downloading:
            EmptyView()
        default:
            Button("检查更新") { updater.checkForUpdates() }
        }
    }
}
