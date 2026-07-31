import SwiftUI

struct ScreenshotSettingsView: View {
    @AppStorage("screenshot.smartElementCandidates") private var smartCandidates = true
    @State private var screenCaptureGranted = Permissions.isScreenCaptureTrusted
    @State private var accessibilityGranted = Permissions.isAccessibilityTrusted

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                SettingsSection(title: "权限") {
                    VStack(spacing: 10) {
                        permissionRow(
                            title: "屏幕录制",
                            granted: screenCaptureGranted,
                            request: {
                                screenCaptureGranted = Permissions.requestScreenCapture()
                                if !screenCaptureGranted { Permissions.openScreenCaptureSettings() }
                            }
                        )
                        permissionRow(
                            title: "辅助功能",
                            granted: accessibilityGranted,
                            request: {
                                accessibilityGranted = Permissions.requestAccessibilityOnce()
                                if !accessibilityGranted { Permissions.openAccessibilitySettings() }
                            }
                        )
                    }
                }
                SettingsSection(title: "选择") {
                    Toggle("显示智能元素候选", isOn: $smartCandidates)
                        .toggleStyle(.switch)
                        .padding(12)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        request: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            Text(granted ? "已授权" : "未授权").foregroundStyle(.secondary)
            if !granted { Button("授权", action: request) }
        }
        .padding(12)
    }

    private func refresh() {
        screenCaptureGranted = Permissions.isScreenCaptureTrusted
        accessibilityGranted = Permissions.isAccessibilityTrusted
    }
}
