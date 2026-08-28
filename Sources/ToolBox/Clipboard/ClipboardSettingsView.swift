import SwiftUI

struct ClipboardSettingsView: View {
    @EnvironmentObject var state: FeatureState
    @ObservedObject var coordinator: ClipboardCoordinator

    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("剪贴板历史"), isOn: $state.clipboardOn)

                Text(L10n.string("启用后会持续读取剪贴板内容"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("保留策略")) {
                Picker(L10n.string("时长"), selection: $coordinator.timeLimit) {
                    Text(L10n.string("1 小时")).tag(TimeInterval(3600))
                    Text(L10n.string("6 小时")).tag(TimeInterval(21600))
                    Text(L10n.string("24 小时")).tag(TimeInterval(86400))
                    Text(L10n.string("48 小时")).tag(TimeInterval(172800))
                    Text(L10n.string("7 天")).tag(TimeInterval(604800))
                }

                Picker(L10n.string("内存限额"), selection: $coordinator.memoryLimit) {
                    Text("20 MB").tag(20 * 1024 * 1024)
                    Text("50 MB").tag(50 * 1024 * 1024)
                    Text("100 MB").tag(100 * 1024 * 1024)
                    Text("200 MB").tag(200 * 1024 * 1024)
                }
            }

            Section {
                HStack {
                    Text(L10n.string("当前用量"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatBytes(coordinator.memoryUsage))
                }

                HStack {
                    Text(L10n.string("历史条目"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(coordinator.itemCount)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
