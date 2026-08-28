import Foundation
import AppKit

/// Coordinates clipboard monitoring and history panel display
@MainActor
final class ClipboardCoordinator: ObservableObject {
    private let store: ClipboardStore
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0

    nonisolated init(store: ClipboardStore) {
        self.store = store
    }

    convenience init() {
        self.init(store: ClipboardStore())
    }

    /// Start monitoring clipboard changes
    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardChange()
            }
        }
    }

    /// Stop monitoring clipboard changes
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Show clipboard history panel (placeholder for now)
    func showPanel() {
        // TODO: Implement in slice 4
        print("[ClipboardCoordinator] showPanel() called")
    }

    private func checkPasteboardChange() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        captureCurrentPasteboard()
    }

    private func captureCurrentPasteboard() {
        let pasteboard = NSPasteboard.general

        guard let types = pasteboard.types else { return }

        // Filter sensitive types
        if types.contains(where: { isSensitiveType($0) }) {
            return
        }

        // Extract text content
        let text = pasteboard.string(forType: .string)

        // Extract image data (PNG or TIFF)
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)

        // Must have either text or image
        guard text != nil || imageData != nil else { return }

        // Compute hash for deduplication
        let hash = ClipboardItem.computeHash(text: text, image: imageData)

        // Add to store
        store.addOrUpdate(
            hash: hash,
            text: text,
            image: imageData,
            types: Set(types)
        )
    }

    // MARK: - Sensitive Type Filtering

    private func isSensitiveType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let rawValue = type.rawValue

        // Filter transient and concealed types
        if rawValue.contains("TransientType") || rawValue.contains("ConcealedType") {
            return true
        }

        // Filter remote clipboard items
        if rawValue == "com.apple.is-remote-clipboard" {
            return true
        }

        return false
    }

    // MARK: - Settings

    @Published var timeLimit: TimeInterval = 86400 {
        didSet {
            store.setTimeLimit(timeLimit)
        }
    }

    @Published var memoryLimit: Int = 50 * 1024 * 1024 {
        didSet {
            store.setMemoryLimit(memoryLimit)
        }
    }

    var memoryUsage: Int { store.memoryUsage }
    var itemCount: Int { store.itemCount }
}
