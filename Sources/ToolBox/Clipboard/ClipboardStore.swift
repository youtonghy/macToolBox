import Foundation
import AppKit
import Combine

/// In-memory store for clipboard history with time and memory limits
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private var timeLimit: TimeInterval = 86400 // 24 hours
    private var memoryLimit: Int = 50 * 1024 * 1024 // 50 MB
    private var currentMemoryUsage: Int = 0
    private var cleanupTimer: Timer?

    init(timeLimit: TimeInterval = 86400, memoryLimit: Int = 50 * 1024 * 1024) {
        self.timeLimit = timeLimit
        self.memoryLimit = memoryLimit
        startCleanupTimer()
    }

    deinit {
        cleanupTimer?.invalidate()
    }

    /// Add new item or update timestamp if duplicate hash exists.
    ///
    /// Returns false when the item alone exceeds the memory limit; in that
    /// case nothing is stored and the existing history is left untouched.
    @discardableResult
    func addOrUpdate(
        hash: String,
        text: String?,
        image: Data?,
        types: Set<NSPasteboard.PasteboardType>,
        imageType: NSPasteboard.PasteboardType? = nil
    ) -> Bool {
        // Check for duplicate
        if let existingIndex = items.firstIndex(where: { $0.contentHash == hash }) {
            // Update timestamp of existing item, keeping its stored payload
            let existing = items[existingIndex]
            let updated = ClipboardItem(
                id: existing.id,
                timestamp: Date(),
                contentHash: existing.contentHash,
                types: existing.types,
                textContent: existing.textContent,
                imageData: existing.imageData,
                imageType: existing.imageType
            )
            items.remove(at: existingIndex)
            items.insert(updated, at: 0)
            return true
        }

        // Create new item
        let item = ClipboardItem(
            contentHash: hash,
            types: types,
            textContent: text,
            imageData: image,
            imageType: imageType
        )

        // A single item larger than the whole budget can never fit; reject it
        // instead of evicting the entire history and still exceeding the limit.
        guard item.estimatedSize <= memoryLimit else { return false }

        // Check memory limit before adding
        if currentMemoryUsage + item.estimatedSize > memoryLimit {
            evictOldestUntilFits(requiredSpace: item.estimatedSize)
        }

        // Insert at beginning (most recent first)
        items.insert(item, at: 0)
        currentMemoryUsage += item.estimatedSize
        return true
    }

    /// Remove items from oldest until enough space is available
    private func evictOldestUntilFits(requiredSpace: Int) {
        while currentMemoryUsage + requiredSpace > memoryLimit, !items.isEmpty {
            let removed = items.removeLast()
            currentMemoryUsage -= removed.estimatedSize
        }
    }

    /// Remove items older than timeLimit
    func cleanupExpiredItems() {
        let cutoff = Date().addingTimeInterval(-timeLimit)
        let oldCount = items.count

        items.removeAll { item in
            if item.timestamp < cutoff {
                currentMemoryUsage -= item.estimatedSize
                return true
            }
            return false
        }

        if items.count != oldCount {
            objectWillChange.send()
        }
    }

    /// Clear all history
    func clear() {
        items.removeAll()
        currentMemoryUsage = 0
    }

    /// Update time limit and trigger cleanup
    func setTimeLimit(_ limit: TimeInterval) {
        timeLimit = limit
        cleanupExpiredItems()
    }

    /// Update memory limit and trigger eviction if needed
    func setMemoryLimit(_ limit: Int) {
        memoryLimit = limit
        if currentMemoryUsage > memoryLimit {
            evictOldestUntilFits(requiredSpace: 0)
        }
    }

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupExpiredItems()
            }
        }
    }

    // MARK: - Accessors

    var memoryUsage: Int { currentMemoryUsage }
    var itemCount: Int { items.count }
}
