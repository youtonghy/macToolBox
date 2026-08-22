import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try setEnabledOrThrow(enabled)
            refresh()
        } catch {
            refresh()
            AppAlert.show(
                title: enabled ? "无法启用开机自启动" : "无法关闭开机自启动",
                message: error.localizedDescription,
                primaryButton: ("打开登录项设置", {
                    SMAppService.openSystemSettingsLoginItems()
                })
            )
        }
    }

    func setEnabledOrThrow(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        refresh()
    }
}
