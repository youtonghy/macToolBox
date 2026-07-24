import SwiftUI

struct AudioRoutingSettingsView: View {
    @ObservedObject var service: AudioRoutingService

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                if let error = service.globalError {
                    SettingsValueRow(title: "状态", value: error, accent: .red)
                }
                if service.playingRows.isEmpty {
                    SettingsEmptyState(
                        symbolName: "speaker.slash",
                        title: "暂无音频应用"
                    )
                }
                ForEach(service.playingRows) { row in
                    SettingsSection(title: row.name, subtitle: subtitle(for: row)) {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(nsImage: AppIconResolver.icon(for: row.bundleID))
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 18, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .accessibilityHidden(true)
                                Text("路由状态")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(statusText(for: row.state))
                                    .foregroundStyle(statusColor(for: row.state))
                            }
                            .font(.system(size: 12))

                            HStack(spacing: 10) {
                                Image(systemName: "speaker.wave.1.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Slider(
                                    value: Binding(
                                        get: { Double(row.volumePercent) },
                                        set: { service.setVolume(bundleID: row.bundleID, percent: Int($0.rounded())) }
                                    ),
                                    in: 0...300,
                                    step: 1
                                )
                                .controlSize(.small)
                                Image(systemName: "speaker.wave.3.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text("\(row.volumePercent)%")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .frame(width: 44, alignment: .trailing)
                                Button { service.setVolume(bundleID: row.bundleID, percent: 100) } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.borderless)
                                .disabled(row.volumePercent == 100)
                                .help("恢复 100%")
                            }

                            Picker(
                                "输出设备",
                                selection: Binding(
                                    get: { row.outputDeviceUID ?? "" },
                                    set: { service.setOutputDevice(bundleID: row.bundleID, uid: $0.isEmpty ? nil : $0) }
                                )
                            ) {
                                Text("跟随系统默认").tag("")
                                ForEach(service.devices) { device in
                                    Text(deviceLabel(device))
                                        .tag(device.uid)
                                        .disabled(!device.isRoutable)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func deviceLabel(_ device: AudioOutputDevice) -> String {
        guard device.isAvailable else { return "\(device.name)（不可用）" }
        guard let issue = device.compatibilityIssue else { return device.name }
        return "\(device.name)（\(issue.message)）"
    }

    private func subtitle(for row: AudioRoutingRow) -> String {
        if row.isCurrentlyPlaying {
            switch row.state {
            case .active: return "正在播放 · 设置已应用"
            case .starting: return "正在播放 · 正在应用设置"
            case .awaitingAudio: return "正在播放 · 等待音频"
            case .degraded, .failed: return "正在播放 · 路由未生效"
            default: return "正在播放"
            }
        }

        switch row.state {
        case .inactive:
            return "已保存设置 · 未播放"
        case .waitingForProcess:
            return "已保存设置 · 等待应用"
        case .starting:
            return "正在应用设置"
        case .awaitingAudio:
            return "设置已应用，等待音频"
        case .active:
            return "设置已应用"
        case .degraded, .failed:
            return "路由未生效"
        }
    }

    private func statusText(for state: AudioRouteState) -> String {
        switch state {
        case .inactive: "原生输出"
        case .waitingForProcess: "等待应用"
        case .starting: "正在启动"
        case let .awaitingAudio(message): message
        case .active: "已启用"
        case let .degraded(message), let .failed(message): message
        }
    }

    private func statusColor(for state: AudioRouteState) -> Color {
        switch state {
        case .active: .green
        case .awaitingAudio: .orange
        case .degraded, .failed: .red
        default: .secondary
        }
    }
}
