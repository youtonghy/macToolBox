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
    /// Pasteboard type the image bytes were actually read as (.png / .tiff).
    /// Kept so the item is written back with a truthful type declaration.
    let imageType: NSPasteboard.PasteboardType?
    let estimatedSize: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        contentHash: String,
        types: Set<NSPasteboard.PasteboardType>,
        textContent: String?,
        imageData: Data?,
        imageType: NSPasteboard.PasteboardType? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.contentHash = contentHash
        self.types = types
        self.textContent = textContent
        self.imageData = imageData
        if let imageData {
            // Never store untyped image bytes with an unverified type claim:
            // sniff the PNG/TIFF magic when the caller did not record the
            // read type. Unknown bytes carry NO type claim rather than a
            // false .png; the write path makes that fallback explicit.
            self.imageType = imageType ?? Self.sniffedImageType(in: imageData)
        } else {
            self.imageType = nil
        }

        // Estimate memory footprint
        var size = 0
        size += MemoryLayout<UUID>.size
        size += MemoryLayout<Date>.size
        size += contentHash.utf8.count
        size += types.count * 64 // Rough estimate per type
        size += textContent?.utf8.count ?? 0
        size += imageData?.count ?? 0
        size += imageType?.rawValue.utf8.count ?? 0
        self.estimatedSize = size
    }

    var isImage: Bool {
        imageData != nil
    }

    /// Best-effort format sniffing from the PNG / TIFF magic bytes; nil when
    /// the bytes are neither. Clipboard image data only ever comes from
    /// `.png` / `.tiff` pasteboard reads, so nil indicates a caller error or
    /// corrupt data — never silently re-labelled as PNG.
    static func sniffedImageType(in data: Data) -> NSPasteboard.PasteboardType? {
        let magic = data.prefix(4)
        if magic == Data([0x89, 0x50, 0x4E, 0x47]) { return .png }
        // TIFF little-endian "II*\0" or big-endian "MM\0*".
        if magic == Data([0x49, 0x49, 0x2A, 0x00]) || magic == Data([0x4D, 0x4D, 0x00, 0x2A]) {
            return .tiff
        }
        return nil
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension ClipboardItem {
    /// Compute SHA-256 hash from clipboard content.
    ///
    /// Parts are domain-separated: each part is prefixed with a kind tag
    /// ("T" for text, "I" for image) and an 8-byte big-endian length, so text
    /// bytes never collide with image bytes and shifted concatenations
    /// (e.g. text "ab" + image "c" vs text "a" + image "bc") hash differently.
    static func computeHash(text: String?, image: Data?) -> String {
        var hasher = SHA256()

        if let text = text {
            hasher.update(data: Data("T".utf8))
            appendLength(UInt64(text.utf8.count), to: &hasher)
            hasher.update(data: Data(text.utf8))
        }

        if let image = image {
            hasher.update(data: Data("I".utf8))
            appendLength(UInt64(image.count), to: &hasher)
            hasher.update(data: image)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLength(_ length: UInt64, to hasher: inout SHA256) {
        withUnsafeBytes(of: length.bigEndian) { bytes in
            hasher.update(bufferPointer: bytes)
        }
    }
}
