import Foundation
import OSLog

struct DisplayBrightnessMemoryIdentity: Codable, Hashable, Sendable {
    var vendorNumber: UInt32
    var modelNumber: UInt32
    var serialNumber: UInt32
}

protocol DisplayBrightnessRemembering {
    func load(for identity: DisplayBrightnessMemoryIdentity) -> Double?
    func save(_ normalizedValue: Double, for identity: DisplayBrightnessMemoryIdentity)
}

/// Versioned persistence for the last known brightness of serial-numbered displays.
struct DisplayBrightnessMemoryStore: DisplayBrightnessRemembering {
    static let defaultKey = "display.brightnessMemory.v1"

    private let defaults: UserDefaults
    private let key: String
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayBrightnessMemoryStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        key: String = DisplayBrightnessMemoryStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func load(for identity: DisplayBrightnessMemoryIdentity) -> Double? {
        guard let document = loadDocument() else { return nil }
        guard let value = document.entries.first(where: { $0.identity == identity })?.normalizedValue else {
            return nil
        }
        guard Self.isValid(value) else {
            logger.error("Stored brightness is outside the normalized range")
            return nil
        }
        return value
    }

    func save(_ normalizedValue: Double, for identity: DisplayBrightnessMemoryIdentity) {
        guard Self.isValid(normalizedValue) else {
            logger.error("Refusing to persist brightness outside the normalized range")
            return
        }

        var document = loadDocument() ?? DisplayBrightnessMemoryDocumentV1(
            schemaVersion: 1,
            entries: []
        )
        document.entries.removeAll { $0.identity == identity }
        document.entries.append(DisplayBrightnessMemoryEntryV1(
            identity: identity,
            normalizedValue: normalizedValue
        ))

        do {
            defaults.set(try encoder.encode(document), forKey: key)
        } catch {
            logger.error("Failed to encode brightness memory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadDocument() -> DisplayBrightnessMemoryDocumentV1? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let document = try decoder.decode(DisplayBrightnessMemoryDocumentV1.self, from: data)
            guard document.schemaVersion == 1 else {
                logger.error("Unknown brightness memory schema \(document.schemaVersion, privacy: .public)")
                return nil
            }
            return document
        } catch {
            logger.error("Failed to decode brightness memory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func isValid(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

private struct DisplayBrightnessMemoryDocumentV1: Codable {
    var schemaVersion: Int
    var entries: [DisplayBrightnessMemoryEntryV1]
}

private struct DisplayBrightnessMemoryEntryV1: Codable {
    var identity: DisplayBrightnessMemoryIdentity
    var normalizedValue: Double
}
