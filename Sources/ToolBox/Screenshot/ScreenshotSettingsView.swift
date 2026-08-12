import SwiftUI

struct ScreenshotSettingsView: View {
    @ObservedObject var permissions: ShortcutPermissionCenter
    @AppStorage("screenshot.smartElementCandidates") private var smartCandidates = true
    @AppStorage("screenshot.scrollCapture.automatic") private var automaticScroll = true
    @AppStorage("screenshot.scrollCapture.stepPixels") private var scrollStep = 160.0
    @State private var ocrSettings = OCRSettingsStore().load().settings
    @State private var availableOCRSelections = PPOCRv6Profile.allCases.map {
        OCRModelSelection(pipeline: .ppOCRv6, variantID: $0.rawValue)
    }
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
                            granted: permissions.snapshot.screenCaptureTrusted,
                            request: { permissions.requestScreenCapture() }
                        )
                        permissionRow(
                            title: "辅助功能",
                            granted: permissions.snapshot.accessibilityTrusted,
                            request: { permissions.requestAccessibility() }
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
                        if automaticScroll && !permissions.snapshot.canPostEvents {
                            permissionRow(
                                title: "事件投递",
                                granted: false,
                                request: { permissions.requestEventPosting() }
                            )
                        }
                    }
                    .padding(12)
                }
                SettingsSection(title: "本地文字识别") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("解析管线")
                            Spacer()
                            Picker("管线", selection: Binding(
                                get: { ocrSettings.pipeline },
                                set: { ocrSettings.selection = OCRModelSelection(pipeline: $0) }
                            )) {
                                ForEach(availableOCRPipelines, id: \.self) { pipeline in
                                    Text(pipeline.displayName).tag(pipeline)
                                }
                            }
                            .labelsHidden()
                        }
                        Picker("模型 / 规模", selection: Binding(
                            get: { ocrSettings.selection.variantID },
                            set: { ocrSettings.selection.variantID = $0 }
                        )) {
                            ForEach(availableVariants, id: \.self) { variant in
                                Text(variantLabel(variant, pipeline: ocrSettings.pipeline)).tag(variant)
                            }
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
            permissions.refresh()
            ocrSettings = OCRSettingsStore().load().settings
            refreshAvailableOCRSelections()
            refreshOCRState()
        }
        .onChange(of: ocrSettings) { _, _ in saveOCRSettings() }
        .alert("下载本地 OCR 模型", isPresented: $showsOCRDownloadPrompt) {
            Button("取消", role: .cancel) {}
            Button("下载") { downloadOCRModel() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("将准备 \(selectionLabel(ocrSettings.selection))（\(byteCountText)）。模型仅保存在本机。")
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
        let selection = ocrSettings.selection
        Task {
            do {
                let descriptor = try await OCRFeatureService.shared.descriptor(for: selection)
                guard ocrSettings.selection == selection else { return }
                ocrModelState = descriptor.state
                ocrDownloadSize = descriptor.downloadByteCount
            } catch {
                ocrError = "无法读取 OCR 模型状态"
            }
        }
    }

    private func refreshAvailableOCRSelections() {
        Task {
            do {
                let selections = try await OCRFeatureService.shared.availableSelections()
                guard !selections.isEmpty else { return }
                availableOCRSelections = selections
                if !selections.contains(ocrSettings.selection), let fallback = selections.first {
                    ocrSettings.selection = fallback
                }
            } catch {
                ocrError = "无法读取可用 OCR 模型"
            }
        }
    }

    private var availableOCRPipelines: [OCRPipelineID] {
        availableOCRSelections.reduce(into: []) { result, selection in
            if !result.contains(selection.pipeline) { result.append(selection.pipeline) }
        }
    }

    private var availableVariants: [String] {
        availableOCRSelections
            .filter { $0.pipeline == ocrSettings.pipeline }
            .map(\.variantID)
    }

    private func downloadOCRModel() {
        let selection = ocrSettings.selection
        isDownloadingOCR = true
        ocrError = nil
        Task {
            defer {
                isDownloadingOCR = false
                refreshOCRState()
            }
            do {
                _ = try await OCRFeatureService.shared.install(selection: selection, userConsented: true)
                if ocrSettings.selection == selection { ocrModelState = .ready }
            } catch is CancellationError {
                return
            } catch {
                ocrModelState = .failed
                ocrError = modelErrorMessage(error)
            }
        }
    }

    private func modelErrorMessage(_ error: Error) -> String {
        switch error {
        case OCRFeatureServiceError.modelUnavailable:
            "所选 OCR 模型未包含在当前签名清单中"
        case OCRFeatureServiceError.workerUnavailable:
            "本地 OCR Worker 尚未打包"
        case OCRModelStoreError.lengthMismatch, OCRModelStoreError.hashMismatch:
            "OCR 模型校验失败"
        case OCRModelDownloadError.invalidHTTPResponse:
            "OCR 模型下载失败"
        default:
            "OCR 模型下载或校验失败：\(error.localizedDescription)"
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

    private func selectionLabel(_ selection: OCRModelSelection) -> String {
        switch selection.pipeline {
        case .ppOCRv6: "PP-OCRv6 \(selection.variantID.capitalized)"
        case .ppStructureV3: "PP-StructureV3"
        case .paddleOCRVL: "PaddleOCR-VL \(selection.variantID)"
        case .systemVision: "System OCR"
        }
    }

    private func variantLabel(_ variant: String, pipeline: OCRPipelineID) -> String {
        switch (pipeline, variant) {
        case (.ppOCRv6, "tiny"): "Tiny"
        case (.ppOCRv6, "small"): "Small"
        case (.ppOCRv6, "medium"): "Medium"
        case (.ppStructureV3, _): "Default"
        case (.paddleOCRVL, _): variant
        default: variant
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
