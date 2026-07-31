import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotAnnotationDraft: Equatable {
    let tool: ScreenshotAnnotationTool
    let start: CGPoint
    var current: CGPoint
    var points: [CGPoint]
}

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    @Published private(set) var renderedImage: CGImage
    @Published private(set) var draft: ScreenshotAnnotationDraft?
    @Published var selectedTool: ScreenshotAnnotationTool = .rectangle
    @Published var annotationColor: Color = .red
    @Published var lineWidth: Double = 4
    @Published var zoom: Double = 1
    @Published var errorMessage: String?
    @Published var showsTextPrompt = false
    @Published var textEntry = ""
    @Published private(set) var isExporting = false

    var onClose: () -> Void = {}
    var onExportingChange: (Bool) -> Void = { _ in }

    private var state: AnnotationEditorState
    private let preview: ScreenshotEditorPreview
    private let previewBuilder = ScreenshotEditorPreviewBuilder()
    private let exporter = ScreenshotPNGExporter()
    private var pendingTextOrigin: CGPoint?
    private var nextMarkerNumber = 1

    var imageSize: CGSize { state.document.baseImage.pixelSize }
    var canUndo: Bool { !state.undoStack.isEmpty }
    var canRedo: Bool { !state.redoStack.isEmpty }

    init(document: ScreenshotDocument, preview: ScreenshotEditorPreview) throws {
        self.preview = preview
        state = AnnotationEditorState(document: document)
        renderedImage = try previewBuilder.render(document: document, preview: preview)
    }

    func beginDraft(at point: CGPoint) {
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
        applyHistory(.undo)
    }

    func redo() {
        applyHistory(.redo)
    }

    func copy() {
        guard !isExporting else { return }
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
                pasteboard.clearContents()
                guard pasteboard.setData(png, forType: .png) else {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(previousItems)
                    throw AnnotationRenderError.exportFailed
                }
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = self?.localized(error)
            }
            self?.setExporting(false)
        }
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ToolBox Screenshot.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !isExporting else { return }
        setExporting(true)
        let document = state.document
        let exporter = exporter
        Task { [weak self] in
            do {
                try await Task.detached {
                    try exporter.export(document: document, to: url)
                }.value
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = self?.localized(error)
            }
            self?.setExporting(false)
        }
    }

    private func setExporting(_ value: Bool) {
        isExporting = value
        onExportingChange(value)
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
        default:
            return "处理失败：\(error.localizedDescription)"
        }
    }

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

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            Divider()
            ScreenshotCanvasView(model: model)
                .frame(minWidth: 640, minHeight: 400)
            Divider()
            actionBar
        }
        .alert("添加文字", isPresented: $model.showsTextPrompt) {
            TextField("文字", text: $model.textEntry)
            Button("取消", role: .cancel) {}
            Button("添加") { model.commitText() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var toolBar: some View {
        HStack(spacing: 6) {
            ForEach(ScreenshotAnnotationTool.allCases) { tool in
                Button {
                    model.selectedTool = tool
                } label: {
                    Image(systemName: icon(for: tool))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(
                    model.selectedTool == tool ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .help(label(for: tool))
            }
            Divider().frame(height: 22)
            ColorPicker("", selection: $model.annotationColor, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 30)
                .help("颜色")
            Image(systemName: "line.diagonal")
                .foregroundStyle(.secondary)
            Slider(value: $model.lineWidth, in: 1...24, step: 1)
                .frame(width: 110)
                .help("线宽")
            Text("\(Int(model.lineWidth))")
                .font(.caption.monospacedDigit())
                .frame(width: 24)
            Divider().frame(height: 22)
            Button { model.zoom = max(1, model.zoom - 0.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(model.zoom <= 1)
            .help("缩小")
            Slider(value: $model.zoom, in: 1...4, step: 0.25)
                .frame(width: 90)
                .help("缩放")
            Button { model.zoom = min(4, model.zoom + 0.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(model.zoom >= 4)
            .help("放大")
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
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
            Button("复制", systemImage: "doc.on.doc") { model.copy() }
                .disabled(model.isExporting)
            Button("保存", systemImage: "square.and.arrow.down") { model.save() }
                .disabled(model.isExporting)
            Button("关闭") { model.onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }

    private func icon(for tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        case .numberedMarker: "1.circle"
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

private struct ScreenshotCanvasView: View {
    @ObservedObject var model: ScreenshotEditorModel

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
                Image(nsImage: NSImage(cgImage: model.renderedImage, size: model.imageSize))
                    .resizable()
                    .frame(width: transform.contentRect.width, height: transform.contentRect.height)
                    .position(x: transform.contentRect.midX, y: transform.contentRect.midY)
                draftOverlay(transform: transform)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(transform: transform))
        }
    }

    private func dragGesture(transform: ScreenshotCanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.draft == nil {
                    guard let start = transform.imagePoint(forViewPoint: value.startLocation) else { return }
                    model.beginDraft(at: start)
                }
                model.updateDraft(to: transform.clampedImagePoint(forViewPoint: value.location))
            }
            .onEnded { value in
                guard model.draft != nil else { return }
                model.finishDraft(at: transform.clampedImagePoint(forViewPoint: value.location))
            }
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
                window.setContentSize(NSSize(width: 900, height: 680))
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
        window.setContentSize(NSSize(width: 900, height: 680))
        window.center()
        window.delegate = self
        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func bringForward() {
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window = windowController?.window else { return }
        guard editorModel?.isExporting != true else {
            NSSound.beep()
            return
        }
        generation &+= 1
        let worker = previewWorkerTask
        previewWorkerTask = nil
        worker?.cancel()
        previewTask?.cancel()
        previewTask = nil
        editorModel = nil
        window.delegate = nil
        windowController = nil
        window.close()
        releaseDocument(after: worker)
        onClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorModel?.isExporting != true else {
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
        editorModel = nil
        windowController = nil
        releaseDocument(after: worker)
        onClose()
    }

    private func setWindowCloseEnabled(_ enabled: Bool) {
        windowController?.window?.standardWindowButton(.closeButton)?.isEnabled = enabled
    }

    private func releaseDocument(after worker: Task<ScreenshotEditorPreview, Error>?) {
        let cleanup = documentCleanup
        documentCleanup = nil
        guard let cleanup else { return }
        guard let worker else {
            cleanup()
            return
        }
        Task {
            _ = try? await worker.value
            cleanup()
        }
    }
}
