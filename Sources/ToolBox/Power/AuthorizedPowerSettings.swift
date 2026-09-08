import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AuthorizedPowerSettings: ObservableObject {
    @Published private(set) var requested = false
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    private let service = SMAppService.daemon(plistName: PowerSamplingService.plistName)

    init() { refresh() }

    func refresh() {
        requested = UserDefaults.standard.bool(forKey: PowerSamplingService.enabledKey)
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        errorMessage = nil
        isChanging = true
        Task {
            defer { isChanging = false; refresh() }
            do {
                if enabled {
                    if service.status != .enabled && service.status != .requiresApproval {
                        try service.register()
                    }
                    UserDefaults.standard.set(true, forKey: PowerSamplingService.enabledKey)
                    if service.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } else {
                    UserDefaults.standard.set(false, forKey: PowerSamplingService.enabledKey)
                    if service.status != .notRegistered && service.status != .notFound {
                        try await service.unregister()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct AuthorizedPowerSettingsSection: View {
    @StateObject private var settings = AuthorizedPowerSettings()

    var body: some View {
        SettingsSection(title: "功耗采集") {
            SettingsInnerCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("授权功耗采集", isOn: Binding(
                        get: { settings.requested }, set: { settings.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(settings.isChanging)
                    Text("CPU 功耗不可用时，可授权系统辅助服务采集。关闭后停止采集并移除服务。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if settings.requested {
                        if settings.status == .enabled {
                            Text("已授权，将在显示功耗时采集。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if settings.status == .requiresApproval {
                            Text("等待系统授权。请在登录项设置中允许 ToolBox 后台服务。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                        } else {
                            Text("采集服务未注册或不可用，请重新启用。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("重新启用功耗采集") { settings.setEnabled(true) }
                                .disabled(settings.isChanging)
                        }
                    } else if settings.status == .enabled || settings.status == .requiresApproval {
                        Button("移除功耗采集服务") { settings.setEnabled(false) }
                            .disabled(settings.isChanging)
                    }
                    if let error = settings.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
