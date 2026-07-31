import SwiftUI

struct ScreenshotSettingsView: View {
    @AppStorage("screenshot.smartElementCandidates") private var smartCandidates = true
    @AppStorage("screenshot.scrollCapture.automatic") private var automaticScroll = true
    @AppStorage("screenshot.scrollCapture.stepPixels") private var scrollStep = 160.0
    @State private var screenCaptureGranted = Permissions.isScreenCaptureTrusted
    @State private var accessibilityGranted = Permissions.isAccessibilityTrusted
    @State private var eventPostingGranted = Permissions.canPostEvents
    @State private var ocrSettings = OCRSettingsStore().load().settings
    @State private var ocrModelState: OCRModelState = .notInstalled
    @State private var ocrDownloadSize: Int64 = 0
    @State private var isDownloadingOCR = false
    @State private var showsOCRDownloadPrompt = false
    @State private var ocrError: String?

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
                SettingsSection(title: "本地文字识别") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("引擎")
                            Spacer()
                            Text("PP-OCRv6")
                                .foregroundStyle(.secondary)
                        }
                        Picker("规格", selection: $ocrSettings.profile) {
                            Text("Tiny").tag(PPOCRv6Profile.tiny)
                            Text("Small").tag(PPOCRv6Profile.small)
                            Text("Medium").tag(PPOCRv6Profile.medium)
                        }
                        .pickerStyle(.segmented)
                        Picker("运行方式", selection: $ocrSettings.executionProvider) {
                            Text("CPU").tag(OCRExecutionProvider.cpu)
                            Text("Core ML").tag(OCRExecutionProvider.coreML)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Image(systemName: modelStateIcon)
                                .foregroundStyle(modelStateColor)
                            Text(modelStateLabel)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isDownloadingOCR {
                                ProgressView().controlSize(.small)
                            } else if ocrModelState != .ready {
                                Button("下载") { showsOCRDownloadPrompt = true }
                            }
                        }
                        Divider()
                        advancedPipelineRow("PP-StructureV3")
                        advancedPipelineRow("PaddleOCR-VL")
                        if let ocrError {
                            Text(ocrError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            refresh()
            ocrSettings = OCRSettingsStore().load().settings
            refreshOCRState()
        }
        .onChange(of: ocrSettings) { _, _ in saveOCRSettings() }
        .alert("下载本地 OCR 模型", isPresented: $showsOCRDownloadPrompt) {
            Button("取消", role: .cancel) {}
            Button("下载") { downloadOCRModel() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("将下载 \(profileLabel(ocrSettings.profile))（\(byteCountText)）。模型仅保存在本机。")
        }
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

    private func saveOCRSettings() {
        do {
            try OCRSettingsStore().save(ocrSettings)
            ocrError = nil
            refreshOCRState()
        } catch {
            ocrError = "无法保存 OCR 设置"
        }
    }

    private func refreshOCRState() {
        let profile = ocrSettings.profile
        Task {
            do {
                let descriptor = try await OCRFeatureService.shared.descriptor(for: profile)
                guard ocrSettings.profile == profile else { return }
                ocrModelState = descriptor.state
                ocrDownloadSize = descriptor.downloadByteCount
            } catch {
                ocrError = "无法读取 OCR 模型状态"
            }
        }
    }

    private func downloadOCRModel() {
        let profile = ocrSettings.profile
        isDownloadingOCR = true
        ocrError = nil
        Task {
            defer {
                isDownloadingOCR = false
                refreshOCRState()
            }
            do {
                try await OCRFeatureService.shared.install(profile: profile, userConsented: true)
                if ocrSettings.profile == profile { ocrModelState = .ready }
            } catch is CancellationError {
                return
            } catch {
                ocrModelState = .failed
                ocrError = "OCR 模型下载或校验失败"
            }
        }
    }

    private func advancedPipelineRow(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("当前版本未启用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelStateLabel: String {
        switch ocrModelState {
        case .notInstalled: "模型未下载"
        case .downloading: "正在下载"
        case .validating: "正在校验"
        case .ready: "模型已就绪"
        case .corrupt: "模型校验失败"
        case .updateAvailable: "有可用更新"
        case .failed: "模型不可用"
        }
    }

    private var modelStateIcon: String {
        ocrModelState == .ready ? "checkmark.circle.fill" : "arrow.down.circle"
    }

    private var modelStateColor: Color {
        ocrModelState == .ready ? .green : .secondary
    }

    private var byteCountText: String {
        Self.byteCountFormatter.string(fromByteCount: ocrDownloadSize)
    }

    private func profileLabel(_ profile: PPOCRv6Profile) -> String {
        switch profile {
        case .tiny: "PP-OCRv6 Tiny"
        case .small: "PP-OCRv6 Small"
        case .medium: "PP-OCRv6 Medium"
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
