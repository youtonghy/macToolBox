import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var model: ShortcutSettingsModel
    @State private var recordingAction: ShortcutActionID?
    @State private var recorderErrorAction: ShortcutActionID?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                if let loadIssue = model.loadIssue {
                    loadIssueSection(loadIssue)
                }

                if let issue = model.issue, model.issueAction == nil {
                    issueSection(issue)
                }

                SettingsSection(title: "全局快捷键") {
                    VStack(spacing: 8) {
                        ForEach(model.rules, id: \.id) { rule in
                            shortcutRow(rule)
                        }
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        recorderErrorAction = nil
                        model.restoreDefaults()
                    } label: {
                        Label("恢复全部默认", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }

                ShortcutRecorderView(
                    isRecording: Binding(
                        get: { recordingAction != nil },
                        set: { if !$0 { recordingAction = nil } }
                    ),
                    onCapture: { binding in
                        guard let action = recordingAction else { return }
                        recorderErrorAction = nil
                        model.setBinding(binding, for: action)
                    },
                    onInvalid: {
                        recorderErrorAction = recordingAction
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }

    private func shortcutRow(_ rule: ShortcutRule) -> some View {
        let isRecording = recordingAction == rule.id
        let rowIssue = model.issueAction == rule.id ? model.issue : nil

        return SettingsInnerCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    SettingsIconBadge(
                        systemName: rule.id.symbolName,
                        accent: rule.id.accent,
                        emphasized: rule.isEnabled
                    )

                    Text(rule.id.title)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer(minLength: 8)

                    Text(isRecording ? "录制中" : rule.binding.displayText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isRecording ? rule.id.accent : .primary)
                        .frame(minWidth: 88, alignment: .trailing)

                    Button {
                        recorderErrorAction = nil
                        model.clearIssue()
                        recordingAction = isRecording ? nil : rule.id
                    } label: {
                        Image(systemName: isRecording ? "xmark" : "keyboard.badge.ellipsis")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(isRecording ? "取消录制" : "录制快捷键")

                    Button {
                        recorderErrorAction = nil
                        model.restoreDefault(for: rule.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .disabled(isDefault(rule))
                    .opacity(isDefault(rule) ? 0.42 : 1)
                    .help("恢复默认")

                    if rule.id.canDisable {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { rule.isEnabled },
                                set: { model.setEnabled($0, for: rule.id) }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .help("退出快捷键始终启用")
                    }
                }

                if recorderErrorAction == rule.id {
                    inlineIssue("快捷键必须包含 Control、Option、Shift 或 Command")
                } else if let rowIssue {
                    inlineIssue(issueMessage(rowIssue))
                }
            }
        }
    }

    private func inlineIssue(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadIssueSection(_ issue: ShortcutRuleStoreIssue) -> some View {
        SettingsSection(title: "规则状态") {
            SettingsInnerCard {
                HStack(spacing: 12) {
                    SettingsIconBadge(
                        systemName: "exclamationmark.triangle.fill",
                        accent: Color(nsColor: .systemOrange),
                        emphasized: true
                    )
                    Text(loadIssueMessage(issue))
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func issueSection(_ issue: ShortcutSettingsIssue) -> some View {
        SettingsSection(title: "快捷键状态") {
            SettingsInnerCard {
                HStack(spacing: 12) {
                    SettingsIconBadge(
                        systemName: "exclamationmark.triangle.fill",
                        accent: Color(nsColor: .systemOrange),
                        emphasized: true
                    )
                    Text(issueMessage(issue))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Button {
                        model.clearIssue()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
            }
        }
    }

    private func isDefault(_ rule: ShortcutRule) -> Bool {
        ShortcutRule.defaults.first(where: { $0.id == rule.id }) == rule
    }

    private func issueMessage(_ issue: ShortcutSettingsIssue) -> String {
        switch issue {
        case .duplicateBinding:
            return "该组合键已用于其他动作"
        case .invalidShortcut:
            return "快捷键规则无效"
        case .protectedShortcut:
            return "擦屏幕退出快捷键必须保持启用"
        case .systemConflict:
            return "系统或其他应用已占用该组合键"
        case .registryUnavailable:
            return "快捷键服务尚未启动"
        case .cleanupRequired:
            return "快捷键服务需要重新启动后再修改"
        case .persistenceFailure:
            return "快捷键无法保存"
        case .rollbackFailure:
            return "快捷键恢复失败，请重新启动应用"
        }
    }

    private func loadIssueMessage(_ issue: ShortcutRuleStoreIssue) -> String {
        switch issue {
        case .corruptData:
            return "已保存的快捷键规则损坏，当前使用默认规则"
        case let .unknownSchema(version):
            return "快捷键规则版本 \(version) 不受支持，当前使用默认规则"
        }
    }
}

private extension ShortcutActionID {
    var title: String {
        switch self {
        case .captureRegion: "区域截图"
        case .screenWipeExit: "退出擦屏幕"
        }
    }

    var symbolName: String {
        switch self {
        case .captureRegion: "camera.viewfinder"
        case .screenWipeExit: "rectangle.inset.filled"
        }
    }

    var accent: Color {
        switch self {
        case .captureRegion: Color(nsColor: .systemBlue)
        case .screenWipeExit: Color(nsColor: .systemIndigo)
        }
    }

    var canDisable: Bool { self == .captureRegion }
}
