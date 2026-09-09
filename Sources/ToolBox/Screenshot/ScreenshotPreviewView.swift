import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotClipboardWriter {
    func write(png: Data, to pasteboard: NSPasteboard) throws {
        guard let bitmap = NSBitmapImageRep(data: png),
              let tiff = bitmap.representation(using: .tiff, properties: [:])
        else {
            throw AnnotationRenderError.exportFailed
        }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png),
              item.setData(tiff, forType: .tiff)
        else {
            throw AnnotationRenderError.exportFailed
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw AnnotationRenderError.exportFailed
        }
    }
}

struct ScreenshotAnnotationDraft: Equatable {
    let tool: ScreenshotAnnotationTool
    let start: CGPoint
    var current: CGPoint
    var points: [CGPoint]
}

struct SimilarPixelPreviewResult: @unchecked Sendable {
    let patch: ScreenshotPixelPatch
    let image: CGImage
}

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    @Published private(set) var renderedImage: CGImage
    @Published private(set) var draft: ScreenshotAnnotationDraft?
    @Published var selectedTool: ScreenshotAnnotationTool = .rectangle
    @Published var annotationColor: Color = .red
    @Published var eraseSensitivity: Double = 15 {
        didSet { if hasPendingErase { scheduleErasePreview() } }
    }
    @Published private(set) var hasPendingErase = false
    @Published private(set) var isErasing = false
    @Published private(set) var eraseProgress: Double = 0
    @Published private(set) var erasePatch: ScreenshotPixelPatch?
    @Published var isComparingErase = false
    private var comparisonImage: CGImage?
    private var eraseWorker: Task<SimilarPixelPreviewResult, Error>?
    private var eraseTask: Task<Void, Never>?
    private var eraseGeneration = 0
    var displayedImage: CGImage { isComparingErase ? (comparisonImage ?? renderedImage) : renderedImage }
    @Published var lineWidth: Double = 4
    @Published var zoom: Double = 1
    @Published var errorMessage: String?
    @Published var showsTextPrompt = false
    @Published var textEntry = ""
    @Published private(set) var isExporting = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var ocrResult: OCRResult?
    @Published private(set) var ocrDocument: TextOCRDocument?
    @Published private(set) var ocrSelection = OCRSelectionState()
    @Published var ocrModelSelection: OCRModelSelection
    @Published private(set) var availableOCRSelections: [OCRModelSelection]
    @Published var showsOCRDownloadPrompt = false
    @Published private(set) var ocrDownloadPrompt = ""

    var onClose: () -> Void = {}
    var onExportingChange: (Bool) -> Void = { _ in }

    private var state: AnnotationEditorState
    private let preview: ScreenshotEditorPreview
    private let previewBuilder = ScreenshotEditorPreviewBuilder()
    private let exporter = ScreenshotPNGExporter()
    private let ocrService: any OCRFeatureServing
    private let ocrSettingsStore: OCRSettingsStore
    private var pendingTextOrigin: CGPoint?
    private var nextMarkerNumber = 1
    private var ocrTask: Task<Void, Never>?
    private var pendingOCRSettings: OCRSettings?

    var imageSize: CGSize { state.document.baseImage.pixelSize }
    var canUndo: Bool { !hasPendingErase && !state.undoStack.isEmpty }
    var canRedo: Bool { !hasPendingErase && !state.redoStack.isEmpty }
    var displayedOCRDocument: TextOCRDocument? {
        ocrDocument.map { ocrSelection.displayedDocument(from: $0) }
    }

    init(
        document: ScreenshotDocument,
        preview: ScreenshotEditorPreview,
        ocrService: any OCRFeatureServing = OCRFeatureService.shared,
        ocrSettingsStore: OCRSettingsStore = OCRSettingsStore()
    ) throws {
        self.preview = preview
        self.ocrService = ocrService
        self.ocrSettingsStore = ocrSettingsStore
        let storedSelection = ocrSettingsStore.load().settings.selection
        ocrModelSelection = storedSelection
        availableOCRSelections = [storedSelection]
        state = AnnotationEditorState(document: document)
        renderedImage = try previewBuilder.render(document: document, preview: preview)
        refreshAvailableOCRSelections()
    }

    deinit { ocrTask?.cancel(); eraseTask?.cancel(); eraseWorker?.cancel() }

    private func refreshAvailableOCRSelections() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let selections = try await ocrService.availableSelections()
                guard !selections.isEmpty else { return }
                availableOCRSelections = selections
                if !selections.contains(ocrModelSelection), let fallback = selections.first {
                    setOCRModelSelection(fallback)
                }
            } catch {
                errorMessage = localized(error)
            }
        }
    }

    func beginDraft(at point: CGPoint) {
        guard !hasPendingErase, !isExporting, !isRecognizing else { return }
        draft = ScreenshotAnnotationDraft(
            tool: selectedTool,
            start: point,
            current: point,
            points: [point]
        )
    }

    func updateDraft(to point: CGPoint) {
        guard var draft else { return }
        draft.current = point
        if draft.tool == .pen || draft.tool == .highlighter {
            if let last = draft.points.last,
               hypot(point.x - last.x, point.y - last.y) >= 0.5 {
                draft.points.append(point)
            }
        }
        self.draft = draft
    }

    func finishDraft(at point: CGPoint) {
        guard var draft else { return }
        draft.current = point
        self.draft = nil
        if draft.tool == .text {
            pendingTextOrigin = draft.start
            textEntry = ""
            showsTextPrompt = true
            return
        }
        do {
            let payload = try AnnotationDraftBuilder.payload(
                tool: draft.tool,
                start: draft.start,
                current: draft.current,
                points: draft.points,
                markerNumber: nextMarkerNumber
            )
            try add(payload)
            if draft.tool == .numberedMarker {
                nextMarkerNumber += 1
            }
        } catch AnnotationError.invalidGeometry {
            // A click without a drag is not an editor failure for shape tools.
        } catch {
            errorMessage = localized(error)
        }
    }

    func commitText() {
        defer {
            pendingTextOrigin = nil
            textEntry = ""
        }
        guard let origin = pendingTextOrigin else { return }
        do {
            let payload = try AnnotationDraftBuilder.payload(
                tool: .text,
                start: origin,
                current: origin,
                points: [],
                text: textEntry
            )
            try add(payload)
        } catch AnnotationError.invalidText {
            errorMessage = "请输入文字"
        } catch {
            errorMessage = localized(error)
        }
    }

    func undo() {
        guard !hasPendingErase else { return }
        applyHistory(.undo)
    }

    func redo() {
        guard !hasPendingErase else { return }
        applyHistory(.redo)
    }

    func requestOCR() {
        guard !isRecognizing, !hasPendingErase else { return }
        var settings = ocrSettingsStore.load().settings
        settings.selection = ocrModelSelection
        persistOCRSelection()
        ocrTask?.cancel()
        setRecognizing(true)
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer { setRecognizing(false) }
            do {
                let descriptor = try await ocrService.descriptor(for: settings.selection)
                try Task.checkCancellation()
                guard descriptor.state == .ready else {
                    pendingOCRSettings = settings
                    ocrDownloadPrompt = "\(selectionLabel(settings.selection)) 模型需要安装 \(Self.byteCountFormatter.string(fromByteCount: descriptor.downloadByteCount)) 的本地资源。文件仅保存在本机。"
                    showsOCRDownloadPrompt = true
                    return
                }
                let result = try await ocrService.recognize(
                    source: state.document.baseImage,
                    settings: settings
                )
                try Task.checkCancellation()
                applyOCRResult(result)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = localized(error)
            }
        }
    }

    func confirmOCRDownload() {
        guard let settings = pendingOCRSettings, !isRecognizing else { return }
        pendingOCRSettings = nil
        setRecognizing(true)
        ocrTask?.cancel()
        ocrTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ocrService.install(selection: settings.selection, userConsented: true)
                try Task.checkCancellation()
                let result = try await ocrService.recognize(
                    source: state.document.baseImage,
                    settings: settings
                )
                try Task.checkCancellation()
                applyOCRResult(result)
            } catch is CancellationError {
                // Closing the editor cancels model work without presenting an error.
            } catch {
                errorMessage = localized(error)
            }
            setRecognizing(false)
        }
    }

    func clearOCR() {
        ocrResult = nil
        ocrDocument = nil
        ocrSelection.reset()
    }

    func resetOCRSelection() {
        ocrSelection.reset()
    }

    func isOCRLineSelected(_ lineID: UUID) -> Bool {
        ocrSelection.selectedLineIDs.contains(lineID)
    }

    func selectOCRLine(at imagePoint: CGPoint, extendingSelection: Bool) {
        guard let document = ocrDocument else { return }
        let normalizedPoint = CGPoint(
            x: imagePoint.x / imageSize.width,
            y: imagePoint.y / imageSize.height
        )
        let lineID = OCRSelectionGeometry.lineID(at: normalizedPoint, in: document.lines)
        if extendingSelection {
            guard let lineID else { return }
            ocrSelection.toggle(lineID)
        } else {
            ocrSelection.replace(with: lineID.map { [$0] } ?? [])
        }
    }

    func selectOCRLines(in imageRect: CGRect, togglingSelection: Bool) {
        guard let document = ocrDocument else { return }
        let normalizedRect = CGRect(
            x: imageRect.minX / imageSize.width,
            y: imageRect.minY / imageSize.height,
            width: imageRect.width / imageSize.width,
            height: imageRect.height / imageSize.height
        )
        let lineIDs = OCRSelectionGeometry.lineIDs(
            intersecting: normalizedRect,
            in: document.lines
        )
        if togglingSelection {
            ocrSelection.toggleBatch(lineIDs)
        } else {
            ocrSelection.replace(with: lineIDs)
        }
    }

    func copyOCRText() {
        guard let result = ocrResult else { return }
        let text: String
        if case .text = result {
            text = displayedOCRDocument?.plainText ?? ""
        } else {
            text = result.plainText
        }
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            errorMessage = "无法复制识别文字"
            return
        }
        errorMessage = nil
    }

    @discardableResult
    func cancelBackgroundWork() -> Task<SimilarPixelPreviewResult, Error>? {
        eraseGeneration += 1
        eraseTask?.cancel()
        eraseWorker?.cancel()
        ocrTask?.cancel()
        ocrTask = nil
        return eraseWorker
    }

    func cancelOCR() {
        ocrTask?.cancel()
    }

    func copy(autoClose: Bool = false) {
        guard !isExporting, !isRecognizing, !hasPendingErase else { return }
        setExporting(true)
        let document = state.document
        let exporter = exporter
        let url = temporaryPNGURL()
        Task { [weak self] in
            do {
                let png = try await Task.detached {
                    defer { try? FileManager.default.removeItem(at: url) }
                    try exporter.export(document: document, to: url)
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                let pasteboard = NSPasteboard.general
                let previousItems = Self.copyPasteboardItems(pasteboard.pasteboardItems ?? [])
                do {
                    try ScreenshotClipboardWriter().write(png: png, to: pasteboard)
                } catch {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(previousItems)
                    throw error
                }
                self?.errorMessage = nil

                // Clear the exporting flag before auto-close so the controller's
                // close() guard (which rejects while exporting) accepts the close.
                self?.setExporting(false)
                if autoClose {
                    self?.onClose()
                }
            } catch {
                self?.errorMessage = self?.localized(error)
                self?.setExporting(false)
            }
        }
    }

    func save(autoClose: Bool = false) {
        // Check the busy flag before presenting the modal panel — otherwise an
        // in-flight export (e.g. the hidden Cmd+S shortcut, which stays active
        // while controls are disabled) pops a save dialog on top of it.
        guard !isExporting, !isRecognizing, !hasPendingErase else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ToolBox Screenshot.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setExporting(true)
        let document = state.document
        let exporter = exporter
        Task { [weak self] in
            do {
                try await Task.detached {
                    try exporter.export(document: document, to: url)
                }.value
                self?.errorMessage = nil

                self?.setExporting(false)
                if autoClose {
                    self?.onClose()
                }
            } catch {
                self?.errorMessage = self?.localized(error)
                self?.setExporting(false)
            }
        }
    }

    private func setExporting(_ value: Bool) {
        isExporting = value
        onExportingChange(value || isRecognizing)
    }

    func setOCRModelSelection(_ selection: OCRModelSelection) {
        guard selection.isKnownVariant else { return }
        ocrModelSelection = selection
        persistOCRSelection()
    }

    private func applyOCRResult(_ result: OCRResult) {
        ocrSelection.reset()
        ocrResult = result
        if case let .text(document) = result {
            ocrDocument = document
            errorMessage = document.lines.isEmpty ? "未识别到文字" : nil
        } else {
            ocrDocument = nil
            errorMessage = result.plainText.isEmpty ? "未识别到内容" : nil
        }
    }

    private func setRecognizing(_ value: Bool) {
        isRecognizing = value
        onExportingChange(value || isExporting)
    }

    func beginErase() {
        guard !hasPendingErase, !isExporting, !isRecognizing else { return }
        draft = nil
        comparisonImage = renderedImage
        if let effect = state.document.annotations.first(where: {
            if case .similarPixels = $0.payload { return true }
            return false
        }), case let .similarPixels(_, patch) = effect.payload {
            eraseSensitivity = patch.sensitivity
        }
        hasPendingErase = true
        scheduleErasePreview()
    }

    func cancelErase() {
        eraseGeneration += 1
        eraseTask?.cancel()
        eraseWorker?.cancel()
        let generation = eraseGeneration
        let worker = eraseWorker
        eraseTask = Task { [weak self] in
            _ = await worker?.result
            guard let self, self.eraseGeneration == generation else { return }
            self.eraseWorker = nil
            self.eraseTask = nil
        }
        erasePatch = nil
        hasPendingErase = false
        isErasing = false
        isComparingErase = false
        comparisonImage = nil
        refreshPreview()
    }

    func applyErase() {
        guard !isErasing, let patch = erasePatch else { return }
        do {
            var next = state
            try AnnotationCommandReducer.reduce(state: &next, command: .setPixelEffect(
                ScreenshotAnnotation(payload: .similarPixels(rect: CGRect(origin: .zero, size: imageSize), patch: patch), style: .default)
            ))
            state = next
            hasPendingErase = false
            erasePatch = nil
            isComparingErase = false
            comparisonImage = nil
            errorMessage = nil
        } catch {
            errorMessage = eraseErrorMessage(error)
        }
    }

    private func eraseErrorMessage(_ error: Error) -> String {
        switch error {
        case SimilarPixelEraseError.imageTooLarge: return L10n.string("图片超过整图处理上限")
        case SimilarPixelEraseError.storageUnavailable: return L10n.string("临时存储空间不足或不可用，无法处理图片")
        case SimilarPixelEraseError.historyTooLarge: return L10n.string("整图调整历史已达到缓存上限，请保存后重新截图")
        default: return localized(error)
        }
    }

    private func scheduleErasePreview() {
        guard hasPendingErase else { return }
        eraseGeneration += 1
        let generation = eraseGeneration
        eraseTask?.cancel()
        eraseWorker?.cancel()
        erasePatch = nil
        isErasing = true
        eraseProgress = 0
        errorMessage = nil
        let document = state.document
        let sensitivity = eraseSensitivity
        let preview = preview
        let previousWorker = eraseWorker
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            if let previousWorker { _ = await previousWorker.result }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 150_000_000)
            let patch = try SimilarPixelEraser().process(source: document.baseImage, sensitivity: sensitivity) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.eraseGeneration == generation, self.isErasing else { return }
                    self.eraseProgress = max(self.eraseProgress, min(0.99, progress))
                }
            }
            var adjusted = document
            adjusted.annotations.removeAll {
                if case .similarPixels = $0.payload { return true }
                return false
            }
            adjusted.annotations.insert(ScreenshotAnnotation(
                payload: .similarPixels(rect: CGRect(origin: .zero, size: document.baseImage.pixelSize), patch: patch), style: .default), at: 0)
            try Task.checkCancellation()
            let rendered = try ScreenshotEditorPreviewBuilder().render(document: adjusted, preview: preview)
            return SimilarPixelPreviewResult(patch: patch, image: rendered)
        }
        eraseWorker = worker
        eraseTask = Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.eraseGeneration == generation, !Task.isCancelled else { return }
                self.renderedImage = result.image
                self.erasePatch = result.patch
                self.eraseProgress = 1
                self.isErasing = false
                self.eraseWorker = nil
                self.eraseTask = nil
            } catch {
                guard let self, self.eraseGeneration == generation, !Task.isCancelled else { return }
                self.isErasing = false
                self.errorMessage = self.eraseErrorMessage(error)
                self.eraseWorker = nil
                self.eraseTask = nil
            }
        }
    }

    private func add(_ payload: ScreenshotAnnotationPayload) throws {
        let style = AnnotationStyle(
            color: annotationColorValue,
            lineWidth: CGFloat(lineWidth),
            opacity: 1
        )
        try AnnotationCommandReducer.reduce(
            state: &state,
            command: .add(ScreenshotAnnotation(payload: payload, style: style))
        )
        refreshPreview()
    }

    private func applyHistory(_ command: AnnotationCommand) {
        do {
            try AnnotationCommandReducer.reduce(state: &state, command: command)
            refreshPreview()
        } catch AnnotationError.historyUnavailable {
            return
        } catch {
            errorMessage = localized(error)
        }
    }

    private func refreshPreview() {
        do {
            renderedImage = try previewBuilder.render(document: state.document, preview: preview)
            errorMessage = nil
            objectWillChange.send()
        } catch {
            errorMessage = localized(error)
        }
    }

    private var annotationColorValue: AnnotationColor {
        let source = NSColor(annotationColor).usingColorSpace(.sRGB) ?? .systemRed
        return AnnotationColor(
            red: source.redComponent,
            green: source.greenComponent,
            blue: source.blueComponent,
            alpha: source.alphaComponent
        )
    }

    private func temporaryPNGURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-copy-\(UUID().uuidString).png")
    }

    private func localized(_ error: Error) -> String {
        switch error {
        case AnnotationRenderError.exportTooLarge:
            return "图片超过 512 MiB 导出上限"
        case AnnotationRenderError.bandTooLarge:
            return "图片过大，无法生成编辑预览"
        case AnnotationRenderError.contextCreationFailed:
            return "无法创建图像缓冲区"
        case AnnotationRenderError.fileMappingFailed:
            return "无法创建安全的导出缓存"
        case ScrollCaptureError.corruptMetadata:
            return "滚动截图数据已损坏"
        case ScrollCaptureError.storageFailure:
            return "无法读取滚动截图数据"
        case OCRModelDownloadError.consentRequired:
            return "需要确认后才能下载 OCR 模型"
        case OCRFeatureServiceError.modelNotInstalled:
            return "本地 OCR 模型尚未安装"
        case OCRFeatureServiceError.modelUnavailable:
            return "所选 OCR 模型未包含在当前签名清单中"
        case OCRFeatureServiceError.workerUnavailable:
            return "本地 OCR Worker 尚未打包"
        case OCRSettingsError.unavailablePipeline:
            return "所选 OCR 模型当前不可用"
        case let PaddleOCRInferenceError.sessionCreationFailed(message),
             let PaddleOCRInferenceError.inferenceFailed(message):
            return "本地 OCR 失败：\(message)"
        default:
            return "处理失败：\(error.localizedDescription)"
        }
    }

    private func selectionLabel(_ selection: OCRModelSelection) -> String {
        switch selection.pipeline {
        case .ppOCRv6: "PP-OCRv6 \(selection.variantID.capitalized)"
        case .ppStructureV3: "PP-StructureV3"
        case .paddleOCRVL: "PaddleOCR-VL \(selection.variantID)"
        case .systemVision: "System OCR"
        }
    }

    private func persistOCRSelection() {
        var settings = ocrSettingsStore.load().settings
        settings.selection = ocrModelSelection
        do {
            try ocrSettingsStore.save(settings)
        } catch {
            errorMessage = "无法保存 OCR 模型选择"
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func copyPasteboardItems(_ items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                } else if let value = source.string(forType: type) {
                    copy.setString(value, forType: type)
                }
            }
            return copy
        }
    }
}

struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    @State private var expandedPanel: SettingsPanel?
    @State private var showsCommandHints = false

    private enum SettingsPanel { case annotation, zoom, ocr }

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            if model.hasPendingErase {
                eraseOptions
            } else if let panel = expandedPanel {
                settingsPanel(panel)
            }
            Divider()
            HStack(spacing: 0) {
                ScreenshotCanvasView(model: model)
                    .frame(minWidth: 640, minHeight: 300)
                if model.ocrResult != nil {
                    Divider()
                    OCRResultPanel(model: model)
                        .frame(width: 260)
                }
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 820, minHeight: 540)
        .alert("添加文字", isPresented: $model.showsTextPrompt) {
            TextField("文字", text: $model.textEntry)
            Button("取消", role: .cancel) {}
            Button("添加") { model.commitText() }
                .keyboardShortcut(.defaultAction)
        }
        .alert("下载本地 OCR 模型", isPresented: $model.showsOCRDownloadPrompt) {
            Button("取消", role: .cancel) {}
            Button("下载并识别") { model.confirmOCRDownload() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.ocrDownloadPrompt)
        }
    }

    private var toolBar: some View {
        HStack(spacing: 5) {
            ForEach(ScreenshotAnnotationTool.allCases) { tool in
                ScreenshotToolbarIconButton(icon: icon(for: tool), title: label(for: tool),
                                            isSelected: model.selectedTool == tool && !model.hasPendingErase) {
                    let isAlreadyOpen = model.selectedTool == tool && expandedPanel == .annotation
                    model.selectedTool = tool
                    expandedPanel = isAlreadyOpen ? nil : .annotation
                }
                .disabled(model.hasPendingErase || model.isExporting || model.isRecognizing)
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            ScreenshotToolbarIconButton(icon: "eraser", title: "抹除近似像素", isSelected: model.hasPendingErase) {
                expandedPanel = nil
                model.beginErase()
            }
            .disabled(model.isExporting || model.isRecognizing)
            ScreenshotToolbarIconButton(icon: "magnifyingglass", title: "缩放", isSelected: expandedPanel == .zoom) {
                expandedPanel = expandedPanel == .zoom ? nil : .zoom
            }
            .disabled(model.hasPendingErase)
            ScreenshotToolbarIconButton(icon: "text.viewfinder", title: "识别文字", isSelected: expandedPanel == .ocr) {
                expandedPanel = expandedPanel == .ocr ? nil : .ocr
            }
            .disabled(model.hasPendingErase || model.isExporting)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func settingsPanel(_ panel: SettingsPanel) -> some View {
        HStack(spacing: 14) {
            switch panel {
            case .annotation:
                Text(LocalizedStringKey(label(for: model.selectedTool))).font(.callout.weight(.semibold))
                Divider().frame(height: 18)
                annotationOptions
            case .zoom:
                Text("缩放").font(.callout.weight(.semibold))
                Divider().frame(height: 18)
                zoomControls
                Spacer()
            case .ocr:
                Text("识别文字").font(.callout.weight(.semibold))
                Divider().frame(height: 18)
                ocrControls
                Spacer()
            }
            Button { expandedPanel = nil } label: {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("收起设置")
            .accessibilityLabel(Text("收起设置"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.04))
    }

    private var annotationOptions: some View {
        HStack(spacing: 10) {
            if model.selectedTool == .mosaic {
                Text("拖动框选以添加马赛克").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("颜色").font(.caption).foregroundStyle(.secondary)
                ColorPicker("颜色", selection: $model.annotationColor, supportsOpacity: true)
                    .labelsHidden().frame(width: 30)
                if model.selectedTool == .text {
                    Text("点击图片添加文字").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.selectedTool == .numberedMarker ? LocalizedStringKey("大小") : LocalizedStringKey("线宽"))
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $model.lineWidth, in: 1...24, step: 1).frame(width: 110)
                        .accessibilityLabel(Text(model.selectedTool == .numberedMarker ? LocalizedStringKey("大小") : LocalizedStringKey("线宽")))
                    Text("\(Int(model.lineWidth))").font(.caption.monospacedDigit()).frame(width: 24)
                }
            }
            Spacer()
        }
    }

    private var eraseOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { eraseSensitivityControl; Spacer(minLength: 12); eraseActions }
                VStack(alignment: .leading, spacing: 10) {
                    eraseSensitivityControl
                    HStack { Spacer(); eraseActions }
                }
            }
            HStack(spacing: 8) {
                if model.isErasing {
                    ProgressView(value: model.eraseProgress).frame(width: 90)
                    Text("正在处理整张截图…")
                    Text("\(Int(model.eraseProgress * 100))%").monospacedDigit()
                } else if let patch = model.erasePatch {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(patch.changedPixelCount == 0 ? LocalizedStringKey("与原图像素一致") : LocalizedStringKey("预览已更新"))
                } else {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("未能生成预览")
                }
                Spacer()
                Text("敏感度越高，合并的色差越大")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.05))
    }

    private var eraseSensitivityControl: some View {
        HStack(spacing: 10) {
            Text("整图处理").font(.callout.weight(.semibold))
            Divider().frame(height: 18)
            Text("敏感度").font(.callout)
            Slider(value: $model.eraseSensitivity, in: 0...100, step: 1)
                .frame(width: 180).accessibilityLabel(Text("敏感度"))
            Text("\(Int(model.eraseSensitivity))")
                .font(.callout.monospacedDigit()).frame(width: 30, alignment: .trailing)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var eraseActions: some View {
        HStack(spacing: 8) {
            Button {} label: {
                Label("按住对比", systemImage: "square.on.square")
            }
            .buttonStyle(ScreenshotCompareButtonStyle(isComparing: $model.isComparingErase))
            .accessibilityAction { model.isComparingErase.toggle() }
            .help("按住查看调整前，松开查看处理后")
            Button("取消") { model.cancelErase() }
                .keyboardShortcut(.cancelAction)
            Button("应用") { model.applyErase() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.isErasing || model.erasePatch == nil)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { model.zoom = ScreenshotZoomAdjuster.adjust(zoom: model.zoom, wheelDeltaY: -1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(model.zoom <= 1)
            .help("缩小")
            Slider(value: $model.zoom, in: ScreenshotZoomAdjuster.range, step: 0.25)
                .frame(width: 90)
                .help("缩放")
            Text("\(Int((model.zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
            Button { model.zoom = ScreenshotZoomAdjuster.adjust(zoom: model.zoom, wheelDeltaY: 1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(model.zoom >= 4)
            .help("放大")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var ocrControls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("OCR 模型", selection: Binding(
                    get: { model.ocrModelSelection },
                    set: { model.setOCRModelSelection($0) }
                )) {
                    ForEach(model.availableOCRSelections, id: \.self) { selection in
                        Text(ocrSelectionLabel(selection)).tag(selection)
                    }
                }
            } label: {
                Label(ocrSelectionLabel(model.ocrModelSelection), systemImage: "cpu")
            }
            .menuStyle(.borderlessButton)
            .help("选择 OCR 解析模型和规格")
            Button { model.requestOCR() } label: {
                Label("识别文字", systemImage: "text.viewfinder")
            }
            .disabled(model.isRecognizing || model.hasPendingErase)
            .help("使用本地 PaddleOCR 识别文字")
            if model.isRecognizing {
                ProgressView().controlSize(.small)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { model.undo() } label: { actionLabel(nil, icon: "arrow.uturn.backward", shortcut: "⌘Z") }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销")
            Button { model.redo() } label: { actionLabel(nil, icon: "arrow.uturn.forward", shortcut: "⇧⌘Z") }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("重做")
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            if model.isExporting {
                ProgressView().controlSize(.small)
            }
            if model.isRecognizing {
                Button("取消识别") { model.cancelOCR() }
            }
            Button { model.copy() } label: { actionLabel("复制", icon: "doc.on.doc", shortcut: "⌘C") }
                .disabled(model.isExporting || model.isRecognizing || model.hasPendingErase)
            Button { model.save() } label: { actionLabel("保存", icon: "square.and.arrow.down", shortcut: "⌘S") }
                .disabled(model.isExporting || model.isRecognizing || model.hasPendingErase)
            Button { model.onClose() } label: { actionLabel("关闭", icon: nil, shortcut: "⌘W") }
                .disabled(model.isExporting || model.isRecognizing)
                .keyboardShortcut("w", modifiers: .command)
            
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(ScreenshotCommandHintMonitor(isPressed: $showsCommandHints))
        .background {
            // Keyboard-only actions must not reserve space after the trailing buttons.
            VStack(spacing: 0) {
                Button("") { model.copy(autoClose: true) }.keyboardShortcut("c", modifiers: .command)
                Button("") { model.save(autoClose: true) }.keyboardShortcut("s", modifiers: .command)
                if !model.hasPendingErase {
                    Button("") { model.onClose() }.keyboardShortcut(.cancelAction)
                        .disabled(model.isExporting || model.isRecognizing)
                }
            }
            .hidden()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func actionLabel(_ title: String?, icon: String?, shortcut: String) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            if let title { Text(LocalizedStringKey(title)) }
            if showsCommandHints {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private func icon(for tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "character.cursor.ibeam"
        case .mosaic: "square.grid.3x3.fill"
        case .numberedMarker: "1.circle"
        }
    }

    private func ocrSelectionLabel(_ selection: OCRModelSelection) -> String {
        switch selection.pipeline {
        case .ppOCRv6: "PP-OCRv6 \(selection.variantID.capitalized)"
        case .ppStructureV3: "PP-StructureV3"
        case .paddleOCRVL: "PaddleOCR-VL \(selection.variantID)"
        case .systemVision: "System OCR"
        }
    }

    private func label(for tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .highlighter: "高亮"
        case .text: "文字"
        case .mosaic: "马赛克"
        case .numberedMarker: "编号"
        }
    }
}

/// A stable leading icon stays under the pointer while its name expands to the right.
struct ScreenshotToolbarIconButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .frame(width: 20, height: 20)
                if isHovered || isFocused {
                    Text(LocalizedStringKey(title))
                        .font(.callout)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background(isSelected ? Color.accentColor.opacity(0.13) : (isHovered ? Color.secondary.opacity(0.09) : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered || isFocused)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onDisappear { isHovered = false }
    }
}

private struct ScreenshotCompareButtonStyle: ButtonStyle {
    @Binding var isComparing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isComparing ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: configuration.isPressed) { _, pressed in isComparing = pressed }
            .onDisappear { isComparing = false }
    }
}

private struct OCRResultPanel: View {
    @ObservedObject var model: ScreenshotEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("识别结果").font(.headline)
                Spacer()
                Button { model.resetOCRSelection() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .disabled(!model.ocrSelection.isFiltering)
                .help("重置选区")
                Button { model.clearOCR() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("关闭识别结果")
            }
            Divider()
            resultContent
            Button("复制结果", systemImage: "doc.on.doc") { model.copyOCRText() }
                .disabled(model.ocrResult?.plainText.isEmpty != false)
        }
        .padding(12)
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.ocrResult {
        case let .text(document):
            HStack(spacing: 6) {
                Image(systemName: model.ocrSelection.isFiltering ? "checkmark.square" : "text.alignleft")
                    .foregroundStyle(.secondary)
                Text(model.ocrSelection.isFiltering
                     ? "已选 \(model.ocrSelection.selectedLineIDs.count) / \(document.lines.count) 行"
                     : "共 \(document.lines.count) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                let text = model.displayedOCRDocument?.plainText ?? ""
                Text(text.isEmpty
                     ? (model.ocrSelection.isFiltering ? "未选择识别区块" : "未识别到文字")
                     : text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        case let .structured(document):
            Text("布局块：\(document.blocks.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(document.blocks) { block in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.kind.rawValue.capitalized)
                                .font(.caption.bold())
                            if let text = block.text, !text.isEmpty {
                                Text(text).textSelection(.enabled)
                            }
                            if let html = block.html, !html.isEmpty {
                                Text(html).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .document(document):
            Text("文档块：\(document.blocks.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(document.markdown)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .font(.body.monospaced())
            }
        case nil:
            Text("未识别到内容")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScreenshotCanvasView: View {
    @ObservedObject var model: ScreenshotEditorModel
    @State private var ocrDragStart: CGPoint?
    @State private var ocrDragCurrent: CGPoint?
    @State private var pinchStartZoom: Double?

    var body: some View {
        GeometryReader { proxy in
            let fitScale = min(
                proxy.size.width / max(1, model.imageSize.width),
                proxy.size.height / max(1, model.imageSize.height)
            )
            let contentSize = CGSize(
                width: max(proxy.size.width, model.imageSize.width * fitScale * model.zoom),
                height: max(proxy.size.height, model.imageSize.height * fitScale * model.zoom)
            )
            ScrollView([.horizontal, .vertical]) {
                canvasSurface(size: contentSize)
                    .frame(width: contentSize.width, height: contentSize.height)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .background(ScreenshotZoomWheelMonitor(zoom: $model.zoom))
            .simultaneousGesture(magnifyGesture)
        }
    }

    @ViewBuilder
    private func canvasSurface(size: CGSize) -> some View {
        if let transform = try? ScreenshotCanvasTransform(
            imageSize: model.imageSize,
            viewportSize: size
        ) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(nsImage: NSImage(cgImage: model.displayedImage, size: model.imageSize))
                    .resizable()
                    .frame(width: transform.contentRect.width, height: transform.contentRect.height)
                    .position(x: transform.contentRect.midX, y: transform.contentRect.midY)
                ocrOverlay(transform: transform)
                ocrSelectionDragOverlay(transform: transform)
                draftOverlay(transform: transform)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(transform: transform))
        }
    }

    @ViewBuilder
    private func ocrOverlay(transform: ScreenshotCanvasTransform) -> some View {
        Canvas { context, _ in
            guard let result = model.ocrResult else { return }
            let overlays: [(UUID, [CGPoint], Bool, Color)]
            switch result {
            case let .text(document):
                overlays = document.lines.map { line in
                    (line.id, line.normalizedPolygon, model.isOCRLineSelected(line.id), .yellow)
                }
            case let .structured(document):
                overlays = document.blocks.map { block in
                    (block.id, block.normalizedPolygon, false, block.kind == .table ? .orange : .blue)
                }
            case let .document(document):
                overlays = document.blocks.map { block in
                    (block.id, block.normalizedPolygon, false, .mint)
                }
            }
            for (_, polygon, selected, color) in overlays {
                let points = polygon.map {
                    transform.viewPoint(forImagePoint: CGPoint(
                        x: $0.x * model.imageSize.width,
                        y: $0.y * model.imageSize.height
                    ))
                }
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                if selected {
                    context.fill(path, with: .color(.accentColor.opacity(0.26)))
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
                } else {
                    context.fill(path, with: .color(color.opacity(0.08)))
                    context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func dragGesture(transform: ScreenshotCanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.ocrDocument != nil && !model.hasPendingErase {
                    updateOCRSelectionDrag(value, transform: transform)
                    return
                }
                if model.draft == nil {
                    guard let start = transform.imagePoint(forViewPoint: value.startLocation) else { return }
                    model.beginDraft(at: start)
                }
                model.updateDraft(to: transform.clampedImagePoint(forViewPoint: value.location))
            }
            .onEnded { value in
                if model.ocrDocument != nil && !model.hasPendingErase {
                    finishOCRSelectionDrag(value, transform: transform)
                    return
                }
                guard model.draft != nil else { return }
                model.finishDraft(at: transform.clampedImagePoint(forViewPoint: value.location))
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let startZoom = pinchStartZoom ?? model.zoom
                if pinchStartZoom == nil { pinchStartZoom = startZoom }
                model.zoom = ScreenshotZoomAdjuster.pinch(
                    startZoom: startZoom,
                    magnification: value.magnification
                )
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private func updateOCRSelectionDrag(
        _ value: DragGesture.Value,
        transform: ScreenshotCanvasTransform
    ) {
        if ocrDragStart == nil {
            guard let start = transform.imagePoint(forViewPoint: value.startLocation) else { return }
            ocrDragStart = start
        }
        ocrDragCurrent = transform.clampedImagePoint(forViewPoint: value.location)
    }

    private func finishOCRSelectionDrag(
        _ value: DragGesture.Value,
        transform: ScreenshotCanvasTransform
    ) {
        defer {
            ocrDragStart = nil
            ocrDragCurrent = nil
        }
        guard let start = ocrDragStart else { return }
        let current = transform.clampedImagePoint(forViewPoint: value.location)
        let isShiftPressed = NSEvent.modifierFlags.contains(.shift)
        let viewDistance = hypot(current.x - start.x, current.y - start.y) * transform.scale
        if viewDistance < 4 {
            model.selectOCRLine(at: start, extendingSelection: isShiftPressed)
        } else {
            let imageRect = CGRect(
                x: start.x,
                y: start.y,
                width: current.x - start.x,
                height: current.y - start.y
            ).standardized
            model.selectOCRLines(in: imageRect, togglingSelection: isShiftPressed)
        }
    }

    @ViewBuilder
    private func ocrSelectionDragOverlay(transform: ScreenshotCanvasTransform) -> some View {
        Canvas { context, _ in
            guard model.ocrDocument != nil,
                  let start = ocrDragStart,
                  let current = ocrDragCurrent
            else { return }
            let startViewPoint = transform.viewPoint(forImagePoint: start)
            let currentViewPoint = transform.viewPoint(forImagePoint: current)
            let rect = CGRect(
                x: startViewPoint.x,
                y: startViewPoint.y,
                width: currentViewPoint.x - startViewPoint.x,
                height: currentViewPoint.y - startViewPoint.y
            ).standardized
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.12)))
            context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func draftOverlay(transform: ScreenshotCanvasTransform) -> some View {
        Canvas { context, _ in
            guard let draft = model.draft else { return }
            let color = model.annotationColor
            let width = max(1, model.lineWidth * Double(transform.scale))
            switch draft.tool {
            case .rectangle, .ellipse, .mosaic:
                let rect = viewRect(for: draft, transform: transform)
                if draft.tool == .mosaic {
                    context.fill(Path(rect), with: .color(.gray.opacity(0.35)))
                } else if draft.tool == .ellipse {
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width)
                } else {
                    context.stroke(Path(rect), with: .color(color), lineWidth: width)
                }
            case .arrow:
                var path = Path()
                path.move(to: transform.viewPoint(forImagePoint: draft.start))
                path.addLine(to: transform.viewPoint(forImagePoint: draft.current))
                context.stroke(path, with: .color(color), lineWidth: width)
            case .pen, .highlighter:
                guard let first = draft.points.first else { return }
                var path = Path()
                path.move(to: transform.viewPoint(forImagePoint: first))
                for point in draft.points.dropFirst() {
                    path.addLine(to: transform.viewPoint(forImagePoint: point))
                }
                let draftColor = draft.tool == .highlighter ? color.opacity(0.35) : color
                context.stroke(path, with: .color(draftColor), lineWidth: width)
            case .numberedMarker:
                let center = transform.viewPoint(forImagePoint: draft.start)
                let radius = max(10, model.lineWidth * 3) * Double(transform.scale)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(color)
                )
            case .text:
                break
            }
        }
        .allowsHitTesting(false)
    }

    private func viewRect(
        for draft: ScreenshotAnnotationDraft,
        transform: ScreenshotCanvasTransform
    ) -> CGRect {
        let start = transform.viewPoint(forImagePoint: draft.start)
        let current = transform.viewPoint(forImagePoint: draft.current)
        return CGRect(
            x: start.x,
            y: start.y,
            width: current.x - start.x,
            height: current.y - start.y
        ).standardized
    }
}

private final class ScreenshotZoomMonitorView: NSView {
    var onDiscreteScroll: (CGFloat) -> Void = { _ in }
    private var eventMonitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeEventMonitor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  ScreenshotZoomAdjuster.shouldZoom(
                      hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
                  )
            else { return event }
            self.onDiscreteScroll(event.scrollingDeltaY)
            return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        removeEventMonitor()
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}

private struct ScreenshotZoomWheelMonitor: NSViewRepresentable {
    @Binding var zoom: Double

    func makeNSView(context: Context) -> ScreenshotZoomMonitorView {
        let view = ScreenshotZoomMonitorView()
        view.onDiscreteScroll = context.coordinator.adjustZoom
        return view
    }

    func updateNSView(_ view: ScreenshotZoomMonitorView, context: Context) {
        context.coordinator.zoom = $zoom
        view.onDiscreteScroll = context.coordinator.adjustZoom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom)
    }

    final class Coordinator {
        var zoom: Binding<Double>

        init(zoom: Binding<Double>) {
            self.zoom = zoom
        }

        func adjustZoom(wheelDeltaY: CGFloat) {
            zoom.wrappedValue = ScreenshotZoomAdjuster.adjust(
                zoom: zoom.wrappedValue,
                wheelDeltaY: wheelDeltaY
            )
        }
    }
}

@MainActor
final class ScreenshotPreviewController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var previewTask: Task<Void, Never>?
    private var previewWorkerTask: Task<ScreenshotEditorPreview, Error>?
    private var editorModel: ScreenshotEditorModel?
    private var documentCleanup: (() -> Void)?
    private var generation: UInt64 = 0
    var onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    func show(image: CGImage) {
        show(document: ScreenshotDocument(baseImage: CGImageScreenshotSource(image: image)))
    }

    func show(document: ScreenshotDocument, cleanup: @escaping () -> Void = {}) {
        close()
        generation &+= 1
        let currentGeneration = generation
        documentCleanup = cleanup
        let loading = NSHostingController(rootView: ProgressView().controlSize(.large).frame(width: 320, height: 180))
        let window = NSWindow(contentViewController: loading)
        configure(window: window)
        let worker = Task.detached {
            try ScreenshotEditorPreviewBuilder().makeBasePreview(document: document)
        }
        previewWorkerTask = worker
        previewTask = Task { [weak self] in
            do {
                let preview = try await worker.value
                guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
                self.previewWorkerTask = nil
                let model = try ScreenshotEditorModel(document: document, preview: preview)
                model.onClose = { [weak self] in self?.close() }
                model.onExportingChange = { [weak self] exporting in
                    self?.setWindowCloseEnabled(!exporting)
                }
                self.editorModel = model
                window.contentViewController = NSHostingController(rootView: ScreenshotEditorView(model: model))
                window.setContentSize(NSSize(width: 1_100, height: 760))
                window.center()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.previewWorkerTask = nil
                window.contentViewController = NSHostingController(
                    rootView: Text("无法打开截图：\(error.localizedDescription)")
                        .foregroundStyle(.red)
                        .padding(24)
                )
            }
        }
    }

    private func configure(window: NSWindow) {
        window.title = "截图编辑"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 820, height: 540)
        window.setContentSize(NSSize(width: 1_100, height: 760))
        window.center()
        window.delegate = self
        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func bringForward() {
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window = windowController?.window else { return }
        guard editorModel?.isExporting != true, editorModel?.isRecognizing != true else {
            NSSound.beep()
            return
        }
        generation &+= 1
        let worker = previewWorkerTask
        previewWorkerTask = nil
        worker?.cancel()
        previewTask?.cancel()
        previewTask = nil
        let pixelWorker = editorModel?.cancelBackgroundWork()
        editorModel = nil
        window.delegate = nil
        windowController = nil
        window.close()
        releaseDocument(after: worker, pixelWorker: pixelWorker)
        onClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorModel?.isExporting != true, editorModel?.isRecognizing != true else {
            NSSound.beep()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        generation &+= 1
        let worker = previewWorkerTask
        previewWorkerTask = nil
        worker?.cancel()
        previewTask?.cancel()
        previewTask = nil
        let pixelWorker = editorModel?.cancelBackgroundWork()
        editorModel = nil
        windowController = nil
        releaseDocument(after: worker, pixelWorker: pixelWorker)
        onClose()
    }

    private func setWindowCloseEnabled(_ enabled: Bool) {
        windowController?.window?.standardWindowButton(.closeButton)?.isEnabled = enabled
    }

    private func releaseDocument(after worker: Task<ScreenshotEditorPreview, Error>?, pixelWorker: Task<SimilarPixelPreviewResult, Error>?) {
        let cleanup = documentCleanup
        documentCleanup = nil
        guard let cleanup else { return }
        guard worker != nil || pixelWorker != nil else {
            cleanup()
            return
        }
        Task {
            _ = try? await worker?.value
            _ = try? await pixelWorker?.value
            cleanup()
        }
    }
}

private struct ScreenshotCommandHintMonitor: NSViewRepresentable {
    @Binding var isPressed: Bool

    func makeNSView(context: Context) -> ScreenshotCommandHintView {
        let view = ScreenshotCommandHintView()
        view.onChange = { isPressed = $0 }
        return view
    }

    func updateNSView(_ view: ScreenshotCommandHintView, context: Context) {
        view.onChange = { isPressed = $0 }
    }
}

private final class ScreenshotCommandHintView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeMonitor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            self.onChange(event.modifierFlags.contains(.command))
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
            self?.onChange(false)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onChange(self.window?.isKeyWindow == true && NSEvent.modifierFlags.contains(.command))
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }

    deinit { removeMonitor() }
}
