import SwiftUI

struct ClipboardSettingsView: View {
    @EnvironmentObject var state: FeatureState
    @ObservedObject var coordinator: ClipboardCoordinator

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: L10n.string("功能开关")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L10n.string("剪贴板历史"), isOn: $state.clipboardOn)
                            .toggleStyle(.switch)

                        Text(L10n.string("启用后会持续读取剪贴板内容"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                SettingsSection(title: L10n.string("保留策略")) {
                    VStack(spacing: 10) {
                        HStack {
                            Text(L10n.string("时长"))
                            Spacer()
                            Picker("", selection: $coordinator.timeLimit) {
                                Text(L10n.string("1 小时")).tag(TimeInterval(3600))
                                Text(L10n.string("6 小时")).tag(TimeInterval(21600))
                                Text(L10n.string("24 小时")).tag(TimeInterval(86400))
                                Text(L10n.string("48 小时")).tag(TimeInterval(172800))
                                Text(L10n.string("7 天")).tag(TimeInterval(604800))
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        HStack {
                            Text(L10n.string("内存限额"))
                            Spacer()
                            Picker("", selection: $coordinator.memoryLimit) {
                                Text("20 MB").tag(20 * 1024 * 1024)
                                Text("50 MB").tag(50 * 1024 * 1024)
                                Text("100 MB").tag(100 * 1024 * 1024)
                                Text("200 MB").tag(200 * 1024 * 1024)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .padding(12)
                }

                SettingsSection(title: L10n.string("使用情况")) {
                    VStack(spacing: 10) {
                        HStack {
                            Text(L10n.string("当前用量"))
                            Spacer()
                            Text(formatBytes(coordinator.memoryUsage))
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(L10n.string("历史条目"))
                            Spacer()
                            Text("\(coordinator.itemCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
