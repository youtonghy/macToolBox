import Foundation
import AppKit
import CryptoKit

/// Represents a single clipboard history entry
struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let contentHash: String
    let types: Set<NSPasteboard.PasteboardType>
    let textContent: String?
    let imageData: Data?
    let estimatedSize: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        contentHash: String,
        types: Set<NSPasteboard.PasteboardType>,
        textContent: String?,
        imageData: Data?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.contentHash = contentHash
        self.types = types
        self.textContent = textContent
        self.imageData = imageData

        // Estimate memory footprint
        var size = 0
        size += MemoryLayout<UUID>.size
        size += MemoryLayout<Date>.size
        size += contentHash.utf8.count
        size += types.count * 64 // Rough estimate per type
        size += textContent?.utf8.count ?? 0
        size += imageData?.count ?? 0
        self.estimatedSize = size
    }

    var isImage: Bool {
        imageData != nil
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension ClipboardItem {
    /// Compute SHA-256 hash from clipboard content
    static func computeHash(text: String?, image: Data?) -> String {
        var hasher = SHA256()

        if let text = text {
            hasher.update(data: Data(text.utf8))
        }

        if let image = image {
            hasher.update(data: image)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
