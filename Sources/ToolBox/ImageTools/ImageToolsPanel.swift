import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 图像工具面板的状态与任务编排。
@MainActor
final class ImageToolsPanelModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case compress = "压缩"
        case convert = "转换"
        case rehash = "换 Hash"

        var id: String { rawValue }

        var localizedTitle: String { L10n.string(rawValue) }
    }

    struct Row: Identifiable {
        let id = UUID()
        let url: URL
        var status: String
        var isPositive: Bool
    }

    @Published var urls: [URL] = []
    @Published var rows: [Row] = []
    @Published var mode: Mode = .compress
    @Published var level = ImageQualityTable.defaultLevel
    @Published var outputFormat: ImageFormat? = nil // nil = 保持原格式（仅压缩模式）
    @Published var maxDimensionText = ""
    @Published var stripMetadata = false
    @Published var renameInsteadOfOverwrite = false
    @Published var isRunning = false
    @Published var progressCompleted = 0
    @Published var progressTotal = 0
    @Published var summaryLine: String?
    @Published var errorLine: String?

    /// 当前运行中的任务句柄：新任务/清空/窗口关闭时取消，
    /// 管线在分块边界协作响应取消。
    private var runTask: Task<Void, Never>?

    private(set) var supportedFormats: [(label: String, format: ImageFormat?)] = []

    init() {
        // 运行时能力探测决定格式下拉项（AVIF 视系统而定）；
        // 转换模式不提供“保持原格式”（否则语义退化为压缩）。
        var formats: [(String, ImageFormat?)] = [("保持原格式", nil)]
        for format in [ImageFormat.webp, .jpeg, .png, .heic, .avif, .tiff] {
            if ImageCapabilities.canEncode(format) {
                formats.append((format.rawValue.uppercased(), format))
            }
        }
        supportedFormats = formats
    }

    var maxDimension: Int? {
        let text = maxDimensionText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Int(text), value > 0 else { return nil }
        return value
    }

    var canRun: Bool {
        !urls.isEmpty && !isRunning
    }

    /// 当前模式下可选的格式项（转换模式排除“保持原格式”）。
    var availableFormats: [(label: String, format: ImageFormat?)] {
        mode == .convert ? supportedFormats.filter { $0.format != nil } : supportedFormats
    }

    /// 切换模式时确保选项合法：转换模式不允许 nil 格式。
    func switchMode(_ newMode: Mode) {
        mode = newMode
        if newMode == .convert, outputFormat == nil {
            outputFormat = availableFormats.first?.format ?? .webp
        }
    }

    func addURLs(_ newURLs: [URL]) {
        let collector = ImageFileCollector.self
        var expanded: [URL] = []
        for url in newURLs {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                expanded.append(contentsOf: (try? ImageFileCollector.collect(
                    paths: [url.path],
                    recursive: true
                )) ?? [])
            } else if collector.supportedExtensions.contains(
                url.pathExtension.lowercased()
            ) {
                expanded.append(url)
            }
        }
        var known = Set(urls.map(\.standardizedFileURL))
        for url in expanded where known.insert(url.standardizedFileURL).inserted {
            urls.append(url)
        }
        refreshRows()
    }

    func removeURLs(at offsets: IndexSet) {
        urls.remove(atOffsets: offsets)
        refreshRows()
    }

    func clearAll() {
        cancelRunningTask()
        urls.removeAll()
        rows.removeAll()
        summaryLine = nil
        errorLine = nil
    }

    /// 取消进行中的任务（新任务开始/清空/窗口关闭时调用）。
    func cancelRunningTask() {
        runTask?.cancel()
        runTask = nil
        if isRunning {
            isRunning = false
            summaryLine = L10n.string("已取消")
        }
    }

    private func refreshRows() {
        rows = urls.map { Row(url: $0, status: L10n.string("待处理"), isPositive: false) }
        if !urls.isEmpty { errorLine = nil }
    }

    // MARK: - 执行

    func run() {
        guard canRun else { return }
        cancelRunningTask()
        isRunning = true
        progressCompleted = 0
        progressTotal = urls.count
        summaryLine = nil
        errorLine = nil
        for index in rows.indices {
            rows[index].status = L10n.string("处理中…")
            rows[index].isPositive = false
        }

        let urls = self.urls
        let mode = self.mode
        let options = ImageJobOptions(
            level: level,
            outputFormat: mode == .convert ? (outputFormat ?? .webp) : outputFormat,
            maxDimension: maxDimension,
            stripMetadata: stripMetadata,
            naming: renameInsteadOfOverwrite ? .suffix(ImageOutputNaming.defaultSuffix) : .overwrite
        )

        runTask = Task { @MainActor in
            defer { isRunning = false }
            switch mode {
            case .compress, .convert:
                let results = await ImagePipeline.process(urls: urls, options: options) {
                    [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.progressCompleted = completed
                        self?.progressTotal = total
                    }
                }
                if !Task.isCancelled { apply(results) }
            case .rehash:
                let results = await ImageHashChanger.rehash(urls: urls) {
                    [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.progressCompleted = completed
                        self?.progressTotal = total
                    }
                }
                if !Task.isCancelled { apply(results) }
            }
        }
    }

    private func apply(_ results: [ImageJobResult]) {
        var saved = 0
        var succeeded = 0
        for (index, result) in results.enumerated() where rows.indices.contains(index) {
            switch result.outcome {
            case .replaced, .savedAs, .converted:
                succeeded += 1
                saved += result.savedBytes
                rows[index].status = Self.describe(result.outcome)
                rows[index].isPositive = true
            default:
                rows[index].status = Self.describe(result.outcome)
                rows[index].isPositive = false
            }
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        summaryLine = String(
            format: L10n.string("共 %d 个文件，成功 %d 个，节省 %@"),
            results.count, succeeded, formatter.string(fromByteCount: Int64(saved))
        )
    }

    private func apply(_ results: [ImageHashResult]) {
        var succeeded = 0
        for (index, result) in results.enumerated() where rows.indices.contains(index) {
            switch result.outcome {
            case .replaced:
                succeeded += 1
                rows[index].status = L10n.string("哈希已更换（像素未变）")
                rows[index].isPositive = true
            case let .unsupported(detail), let .failed(detail):
                rows[index].status = detail
                rows[index].isPositive = false
            }
        }
        summaryLine = String(
            format: L10n.string("共 %d 个文件，换 Hash 成功 %d 个"),
            results.count, succeeded
        )
    }

    private static func describe(_ outcome: ImageOutcome) -> String {
        switch outcome {
        case let .replaced(original, result, _):
            return "\(ByteCountFormatter.string(fromByteCount: Int64(original), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(result), countStyle: .file))"
        case let .savedAs(target, original, result, _):
            return String(
                format: L10n.string("另存 %@：%@ → %@"),
                target.lastPathComponent,
                ByteCountFormatter.string(fromByteCount: Int64(original), countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(result), countStyle: .file)
            )
        case let .converted(_, target, original, result, _):
            return String(
                format: L10n.string("转换为 %@（源已删除）：%@ → %@"),
                target.lastPathComponent,
                ByteCountFormatter.string(fromByteCount: Int64(original), countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(result), countStyle: .file)
            )
        case let .noBenefit(_, _, detail):
            return detail
        case let .unsupported(detail):
            return detail
        case let .failed(detail):
            return detail
        }
    }
}

/// 图像工具面板视图：拖放区 + 文件列表 + 参数区 + 进度 + 结果。
struct ImageToolsPanelView: View {
    @ObservedObject var model: ImageToolsPanelModel

    var body: some View {
        VStack(spacing: 12) {
            Picker(L10n.string("操作"), selection: Binding(
                get: { model.mode },
                set: { model.switchMode($0) }
            )) {
                ForEach(ImageToolsPanelModel.Mode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            DropZoneView { urls in
                model.addURLs(urls)
            }

            if !model.urls.isEmpty {
                List {
                    ForEach(model.rows) { row in
                        HStack {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(row.status)
                                    .font(.caption)
                                    .foregroundStyle(row.isPositive ? Color.green : Color.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { model.removeURLs(at: $0) }
                }
                .frame(minHeight: 120, maxHeight: 260)
                .overlay(alignment: .bottom) {
                    if model.isRunning {
                        ProgressView(value: Double(model.progressCompleted), total: Double(max(model.progressTotal, 1)))
                            .padding(8)
                    }
                }
            }

            if model.mode != .rehash {
                controlsView
            }

            if let summary = model.summaryLine {
                Text(summary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.errorLine {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L10n.string("清空")) { model.clearAll() }
                    .disabled(model.urls.isEmpty || model.isRunning)
                Spacer()
                Button(model.isRunning ? L10n.string("处理中…") : L10n.string("开始")) { model.run() }
                    .keyboardShortcut(.return)
                    .disabled(!model.canRun)
            }
        }
        .padding(4)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            // 窗口关闭时取消进行中的批量任务，避免后台残留处理。
            model.cancelRunningTask()
        }
    }

    @ViewBuilder
    private var controlsView: some View {
        VStack(spacing: 10) {
            HStack {
                Text(String(format: L10n.string("质量级别 %d"), model.level))
                    .frame(width: 110, alignment: .leading)
                Slider(value: .init(
                    get: { Double(model.level) },
                    set: { model.level = Int($0) }
                ), in: 1 ... 6, step: 1)
            }
            if model.mode == .convert {
                HStack {
                    Text(L10n.string("输出格式"))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: Binding<String>(
                        get: { model.outputFormat?.rawValue ?? "" },
                        set: { raw in
                            model.outputFormat = ImageFormat(rawValue: raw)
                        }
                    )) {
                        ForEach(model.availableFormats, id: \.label) { entry in
                            Text(entry.label)
                                .tag(entry.format?.rawValue ?? "")
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Text(L10n.string("最长边上限"))
                    .frame(width: 110, alignment: .leading)
                TextField(L10n.string("不缩放"), text: $model.maxDimensionText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Spacer()
            }
            HStack {
                Toggle(L10n.string("剥离元数据"), isOn: $model.stripMetadata)
                Spacer()
                Toggle(L10n.string("另存而非覆盖"), isOn: $model.renameInsteadOfOverwrite)
            }
        }
    }
}

/// 拖放区：接受文件/文件夹拖入，也支持点击选择。
struct DropZoneView: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(L10n.string("拖入图像或文件夹"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
                        )
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            let group = DispatchGroup()
            var collected: [URL] = []
            let lock = NSLock()
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        collected.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                onDrop(collected)
            }
            return true
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            if panel.runModal() == .OK {
                onDrop(panel.urls)
            }
        }
    }
}
