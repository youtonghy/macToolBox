import SwiftUI

struct ScreenshotSettingsView: View {
    @AppStorage("screenshot.smartElementCandidates") private var smartCandidates = true
    @AppStorage("screenshot.scrollCapture.automatic") private var automaticScroll = true
    @AppStorage("screenshot.scrollCapture.stepPixels") private var scrollStep = 160.0
    @State private var screenCaptureGranted = Permissions.isScreenCaptureTrusted
    @State private var accessibilityGranted = Permissions.isAccessibilityTrusted
    @State private var eventPostingGranted = Permissions.canPostEvents

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
                SettingsSection(title: "滚动截图") {
                    VStack(spacing: 12) {
                        Toggle("自动滚动", isOn: $automaticScroll)
                            .toggleStyle(.switch)
                        HStack {
                            Text("步长")
                            Slider(value: $scrollStep, in: 40...400, step: 20)
                            Text("\(Int(scrollStep)) px")
                                .font(.caption.monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                        }
                        if automaticScroll && !eventPostingGranted {
                            permissionRow(
                                title: "事件投递",
                                granted: false,
                                request: { eventPostingGranted = Permissions.requestEventPosting() }
                            )
                        }
                    }
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
        eventPostingGranted = Permissions.canPostEvents
    }
}
