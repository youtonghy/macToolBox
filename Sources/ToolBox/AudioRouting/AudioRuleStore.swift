import Foundation
import OSLog

enum AudioRuleStoreIssue: Equatable, Sendable {
    case corruptData
    case unknownSchema(Int)
}

enum AudioRuleStoreError: Error {
    case invalidBundleID
}

struct AudioRuleLoadResult: Equatable, Sendable {
    var rules: [AppAudioRule]
    var issue: AudioRuleStoreIssue?
}

struct AudioRuleStore {
    static let defaultKey = "audio.routingRules.v1"

    private let defaults: UserDefaults
    private let key: String
    private let logger = Logger(subsystem: "ToolBox", category: "AudioRuleStore")
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = AudioRuleStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() -> AudioRuleLoadResult {
        guard let data = defaults.data(forKey: key) else {
            return AudioRuleLoadResult(rules: [], issue: nil)
        }

        do {
            let document = try decoder.decode(AudioRuleDocumentV1.self, from: data)
            guard document.schemaVersion == 1 else {
                logger.error("Unknown audio rule schema \(document.schemaVersion, privacy: .public)")
                return AudioRuleLoadResult(rules: [], issue: .unknownSchema(document.schemaVersion))
            }
            guard document.rules.allSatisfy(Self.isValid) else {
                logger.error("Audio routing rules contain an empty bundle identifier")
                return AudioRuleLoadResult(rules: [], issue: .corruptData)
            }
            return AudioRuleLoadResult(rules: canonicalize(document.rules), issue: nil)
        } catch {
            logger.error("Corrupt audio routing rules")
            CorruptDefaultsBackup.backup(defaults: defaults, key: key)
            return AudioRuleLoadResult(rules: [], issue: .corruptData)
        }
    }

    func save(_ rules: [AppAudioRule]) throws {
        guard rules.allSatisfy(Self.isValid) else {
            throw AudioRuleStoreError.invalidBundleID
        }
        let data = try encoder.encode(
            AudioRuleDocumentV1(schemaVersion: 1, rules: canonicalize(rules))
        )
        defaults.set(data, forKey: key)
    }

    private static func isValid(_ rule: AppAudioRule) -> Bool {
        !rule.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canonicalize(_ rules: [AppAudioRule]) -> [AppAudioRule] {
        var latestByBundleID: [String: (index: Int, rule: AppAudioRule)] = [:]
        for (index, rule) in rules.enumerated() {
            latestByBundleID[rule.bundleID] = (index, rule)
        }
        return latestByBundleID.values.sorted { $0.index < $1.index }.map(\.rule)
    }
}

private struct AudioRuleDocumentV1: Codable {
    let schemaVersion: Int
    let rules: [AppAudioRule]
}
