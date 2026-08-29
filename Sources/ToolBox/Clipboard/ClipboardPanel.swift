import AppKit
import SwiftUI
import ApplicationServices
import Combine

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { normalizeSelection() } }
    @Published private(set) var selectedIndex: Int?
    let store: ClipboardStore
    private var storeCancellable: AnyCancellable?

    init(store: ClipboardStore) {
        self.store = store
        selectedIndex = store.items.isEmpty ? nil : 0
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.normalizeSelection()
                self?.objectWillChange.send()
            }
        }
    }

    var filteredItems: [ClipboardItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.items }
        return store.items.filter { item in
            guard let text = item.textContent, !item.isImage else { return false }
            return text.localizedCaseInsensitiveContains(term)
        }
    }

    var selectedItem: ClipboardItem? {
        guard let selectedIndex, filteredItems.indices.contains(selectedIndex) else { return nil }
        return filteredItems[selectedIndex]
    }

    var listHeight: CGFloat {
        min(340, max(72, CGFloat(filteredItems.count) * 58))
    }

    var panelHeight: CGFloat { listHeight + 62 }

    func moveSelection(by offset: Int) {
        let count = filteredItems.count
        guard count > 0 else { selectedIndex = nil; return }
        let current = selectedIndex ?? 0
        selectedIndex = (current + offset + count) % count
    }

    func selectFirst() { selectedIndex = filteredItems.isEmpty ? nil : 0 }
    func select(index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        selectedIndex = index
    }

    private func normalizeSelection() {
        let count = filteredItems.count
        guard count > 0 else { selectedIndex = nil; return }
        selectedIndex = min(selectedIndex ?? 0, count - 1)
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool
    let onActivate: (ClipboardItem) -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField("搜索剪贴板", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($searchFocused)
                .onSubmit { if let item = model.selectedItem { onActivate(item) } }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        if model.filteredItems.isEmpty {
                            ContentUnavailableView(
                                model.query.isEmpty ? "暂无剪贴板历史" : "没有匹配结果",
                                systemImage: model.query.isEmpty ? "clipboard" : "magnifyingglass"
                            )
                            .frame(maxWidth: .infinity, minHeight: model.listHeight)
                        } else {
                            ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(item: item, selected: index == model.selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.select(index: index) }
                                    .onTapGesture(count: 2) { onActivate(item) }
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
                .scrollIndicators(.visible)
                .overlay(alignment: .trailing) {
                    if model.filteredItems.count > 5 {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3, height: 36)
                            .padding(.trailing, 1)
                    }
                }
                .onChange(of: model.selectedIndex) { _, index in
                    if let index, model.filteredItems.indices.contains(index) {
                        proxy.scrollTo(model.filteredItems[index].id, anchor: .center)
                    }
                }
            }
            .frame(height: model.listHeight)
        }
        .padding(12)
        .frame(width: 340, height: model.panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1)
            case .down: model.moveSelection(by: 1)
            default: break
            }
        }
        .onAppear { searchFocused = true; model.selectFirst() }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let data = item.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 42, height: 42)
            } else {
                Image(systemName: "doc.on.clipboard").frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isImage ? "图片" : (item.textContent ?? "未知内容"))
                    .lineLimit(2)
                if item.isImage {
                    Text("图像剪贴板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor
final class ClipboardPanelController: NSWindowController, NSWindowDelegate {
    private let model: ClipboardPanelModel
    private let pasteService: ClipboardPasteService
    private var monitors: [Any] = []
    private var targetApplication: NSRunningApplication?

    init(store: ClipboardStore) {
        model = ClipboardPanelModel(store: store)
        pasteService = ClipboardPasteService()
        let hosting = NSHostingController(rootView: ClipboardPanelView(model: model) { _ in })
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 430),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = nil
        super.init(window: panel)
        panel.delegate = self
        hosting.rootView = ClipboardPanelView(model: model) { [weak self] item in self?.activate(item) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        targetApplication = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let size = NSSize(width: 340, height: model.panelHeight)
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height)
        if let visible = screen?.visibleFrame {
            if origin.x + size.width > visible.maxX { origin.x = mouse.x - size.width - 14 }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        window?.setContentSize(size)
        window?.setFrame(NSRect(origin: origin, size: size), display: false)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    private func installMonitor() {
        guard monitors.isEmpty else { return }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.window?.isVisible == true else { return event }
            if event.type == .keyDown {
                switch event.keyCode {
                case 126: // Up arrow
                    model.moveSelection(by: -1)
                    return nil
                case 125: // Down arrow
                    model.moveSelection(by: 1)
                    return nil
                case 53: close(); return nil
                case 36, 76:
                    if let item = model.selectedItem { activate(item) }
                    return nil
                default: break
                }
            } else if event.window !== window { close() }
            return event
        }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.window?.isVisible == true else { return }
            self.close()
        }
        monitors = [localMonitor, globalMonitor].compactMap { $0 }
    }

    private func activate(_ item: ClipboardItem) {
        pasteService.write(item)
        close()
        pasteService.paste(into: targetApplication)
    }

    override func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { close() }
}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ClipboardPasteService {
    func write(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if let text = item.textContent { pasteboard.setString(text, forType: .string) }
        if let image = item.imageData { pasteboard.setData(image, forType: .png) }
    }

    func paste(into application: NSRunningApplication?) {
        guard let application else { return }
        application.activate()
        // Enter is an explicit user action, so this is an appropriate time to
        // register the app with TCC and request the required permissions.
        guard Permissions.isAccessibilityTrusted else {
            _ = Permissions.requestAccessibilityOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard Permissions.isAccessibilityTrusted else { return }
                self?.sendCommandV()
            }
            return
        }
        guard Permissions.canPostEvents || Permissions.requestEventPosting() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard Permissions.canPostEvents else { return }
                self?.sendCommandV()
            }
            return
        }
        sendCommandV()
    }

    private func sendCommandV() {
        // Activation is asynchronous; wait briefly so Cmd-V reaches the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
