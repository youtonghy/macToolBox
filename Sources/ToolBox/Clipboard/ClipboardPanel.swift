import AppKit
import SwiftUI
import ApplicationServices
import Combine
import os

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { normalizeSelection() } }
    /// Selection tracked by item identity so list mutations (head inserts,
    /// dedup reordering) never silently rebind what Enter will paste.
    @Published private(set) var selectedItemID: ClipboardItem.ID?
    @Published private(set) var presentationID = UUID()
    let store: ClipboardStore
    private var storeCancellable: AnyCancellable?

    init(store: ClipboardStore) {
        self.store = store
        selectedItemID = store.items.first?.id
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

    var selectedIndex: Int? {
        guard let selectedItemID else { return nil }
        return filteredItems.firstIndex(where: { $0.id == selectedItemID })
    }

    var selectedItem: ClipboardItem? {
        guard let selectedItemID else { return nil }
        return filteredItems.first(where: { $0.id == selectedItemID })
    }

    var listHeight: CGFloat {
        min(340, max(72, CGFloat(filteredItems.count) * 58))
    }

    var panelHeight: CGFloat { listHeight + 62 }

    func moveSelection(by offset: Int) {
        let items = filteredItems
        guard !items.isEmpty else { selectedItemID = nil; return }
        let current = selectedIndex ?? 0
        let next = (current + offset + items.count) % items.count
        selectedItemID = items[next].id
    }

    func selectFirst() { selectedItemID = filteredItems.first?.id }

    func prepareForPresentation() {
        query = ""
        selectFirst()
        // Recreate the scroll view even if the selected item hasn't changed:
        // the user may have scrolled away from it before hiding the panel.
        presentationID = UUID()
    }

    func select(index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        selectedItemID = filteredItems[index].id
    }

    private func normalizeSelection() {
        let items = filteredItems
        guard !items.isEmpty else { selectedItemID = nil; return }
        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) { return }
        // Tracked item disappeared (expired / evicted / cleared): fall back
        // to the first row.
        selectedItemID = items[0].id
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool
    let onActivate: (ClipboardItem) -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField(L10n.string("搜索剪贴板"), text: $model.query)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($searchFocused)
                .onSubmit { if let item = model.selectedItem { onActivate(item) } }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        if model.filteredItems.isEmpty {
                            ContentUnavailableView(
                                model.query.isEmpty ? L10n.string("暂无剪贴板历史") : L10n.string("没有匹配结果"),
                                systemImage: model.query.isEmpty ? "clipboard" : "magnifyingglass"
                            )
                            .frame(maxWidth: .infinity, minHeight: model.listHeight)
                        } else {
                            ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(item: item, selected: item.id == model.selectedItemID)
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
                .onChange(of: model.selectedItemID) { _, id in
                    if let id {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .id(model.presentationID)
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
        .onAppear { searchFocused = true }
        .onChange(of: model.presentationID) { _, _ in searchFocused = true }
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
                Text(item.isImage ? L10n.string("图片") : (item.textContent ?? L10n.string("未知内容")))
                    .lineLimit(2)
                if item.isImage {
                    Text(L10n.string("图像剪贴板"))
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
        model.prepareForPresentation()
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
        let changeCount = pasteService.write(item)
        close()
        pasteService.paste(into: targetApplication, changeCount: changeCount)
    }

    override func close() {
        // Supersede any permission wait still polling from a previous paste,
        // and stop pending pastes entirely when the feature is disabled
        // (ClipboardCoordinator.stop() closes a presented panel here).
        pasteService.cancelPendingPaste()
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
    private static let logger = Logger(subsystem: "ToolBox", category: "ClipboardPaste")

    /// In-flight permission wait. Superseded by each new paste and cancelled
    /// on close, so stacked Cmd-V sends are impossible.
    private var pendingWait: Permissions.PermissionWait?

    /// Monotonic paste generation. Every paste captures the current value and
    /// re-validates it before acting. Cancelling bumps the value so ALL
    /// in-flight callbacks — permission waits and the delayed Cmd-V closure
    /// (which a cancel cannot reach directly) — become no-ops.
    private var pasteGeneration = 0

    /// Writes the item and returns the pasteboard changeCount snapshot, so a
    /// delayed paste can detect that the user copied something else meanwhile.
    @discardableResult
    func write(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        if let text = item.textContent { pasteboard.setString(text, forType: .string) }
        if let image = item.imageData {
            // Declare the type the bytes were actually captured as; writing
            // TIFF bytes as PNG breaks strict decoders in target apps. The
            // fallback only fires for items built outside the capture path
            // with unrecognized bytes — an explicit, documented last resort.
            pasteboard.setData(image, forType: item.imageType ?? .png)
        }
        return pasteboard.changeCount
    }

    func cancelPendingPaste() {
        // Invalidate every in-flight callback first: a cancel alone cannot
        // stop a completion already dispatched to the main queue, nor the
        // delayed Cmd-V closure.
        pasteGeneration += 1
        pendingWait?.cancel()
        pendingWait = nil
    }

    func paste(into application: NSRunningApplication?, changeCount: Int) {
        guard let application else { return }
        // One in-flight paste at a time: supersede any earlier wait so repeated
        // Enter presses can never stack multiple Cmd-V sends.
        cancelPendingPaste()
        let generation = pasteGeneration
        application.activate()
        // Enter is an explicit user action, so this is an appropriate time to
        // register the app with TCC and request the required permissions.
        guard Permissions.isAccessibilityTrusted else {
            _ = Permissions.requestAccessibilityOnce()
            // The TCC prompt can take a while to complete; poll up to 60s
            // instead of a single 0.5s check that silently abandons the paste.
            pendingWait = Permissions.awaitAccessibility(timeout: 60) { [weak self] granted in
                guard let self else { return }
                guard self.pasteGeneration == generation else { return }
                guard granted else {
                    Self.logger.warning("Accessibility not granted within 60s; paste abandoned")
                    return
                }
                self.requestEventPostingThenSend(
                    application: application,
                    changeCount: changeCount,
                    generation: generation
                )
            }
            return
        }
        requestEventPostingThenSend(application: application, changeCount: changeCount, generation: generation)
    }

    private func requestEventPostingThenSend(
        application: NSRunningApplication,
        changeCount: Int,
        generation: Int
    ) {
        guard Permissions.canPostEvents || Permissions.requestEventPosting() else {
            pendingWait = Permissions.awaitEventPosting(timeout: 60) { [weak self] granted in
                guard let self else { return }
                guard self.pasteGeneration == generation else { return }
                guard granted else {
                    Self.logger.warning("Event posting not granted within 60s; paste abandoned")
                    return
                }
                self.sendCommandV(application: application, changeCount: changeCount, generation: generation)
            }
            return
        }
        sendCommandV(application: application, changeCount: changeCount, generation: generation)
    }

    private func sendCommandV(application: NSRunningApplication, changeCount: Int, generation: Int) {
        guard pasteGeneration == generation else { return }
        // The user may have copied something else while we waited for TCC;
        // pasting now would emit the wrong content.
        guard NSPasteboard.general.changeCount == changeCount else {
            Self.logger.info("Pasteboard overwritten while waiting for permissions; paste abandoned")
            return
        }
        activateAndSend(application: application, changeCount: changeCount, generation: generation, attempt: 0)
    }

    /// Bounded retries for the asynchronous part of `activate()`: at fire time
    /// the target must actually be the active app, otherwise Cmd-V would land
    /// in whatever app grabbed focus in the meantime.
    private static let focusSettleMaxAttempts = 3 // ≈0.32s total settle budget

    private func activateAndSend(
        application: NSRunningApplication,
        changeCount: Int,
        generation: Int,
        attempt: Int
    ) {
        guard pasteGeneration == generation else { return }
        // Focus may have shifted (TCC dialogs, manual app switching); bring
        // the original target back frontmost so Cmd-V lands in the right app.
        if application.isTerminated {
            Self.logger.info("Target application terminated; paste abandoned")
            return
        }
        guard application.isActive || application.activate() else {
            Self.logger.info("Target application no longer available; paste abandoned")
            return
        }
        // Activation is asynchronous; wait briefly so Cmd-V reaches the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // close()/stop()/a newer paste may have invalidated this flow while
            // the activation delay was pending — the token is the only way to
            // reach in here.
            guard self.pasteGeneration == generation else { return }
            guard NSPasteboard.general.changeCount == changeCount else {
                Self.logger.info("Pasteboard overwritten before Cmd-V was sent; paste abandoned")
                return
            }
            // Re-validate focus INSIDE the window: activation may have been
            // slower than the delay, the user may have switched apps, or the
            // target may have quit. Never post Cmd-V into a non-target app.
            if application.isTerminated || !application.isActive {
                guard attempt < Self.focusSettleMaxAttempts else {
                    Self.logger.info("Target app did not regain focus in time; paste abandoned")
                    return
                }
                self.activateAndSend(
                    application: application,
                    changeCount: changeCount,
                    generation: generation,
                    attempt: attempt + 1
                )
                return
            }
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
