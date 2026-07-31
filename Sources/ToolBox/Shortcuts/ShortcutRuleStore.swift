import Carbon.HIToolbox
import Foundation
import OSLog

struct ShortcutRuleLoadResult: Equatable, Sendable {
    var rules: [ShortcutRule]
    var issue: ShortcutRuleStoreIssue?
}

struct ShortcutRuleStore {
    static let defaultKey = "shortcuts.rules.v1"

    private let defaults: UserDefaults
    private let key: String
    private let logger = Logger(subsystem: "ToolBox", category: "ShortcutRuleStore")
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = ShortcutRuleStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() -> ShortcutRuleLoadResult {
        guard let data = defaults.data(forKey: key) else {
            return ShortcutRuleLoadResult(rules: ShortcutRule.defaults, issue: nil)
        }

        do {
            let envelope = try decoder.decode(ShortcutRuleVersionEnvelope.self, from: data)
            guard envelope.schemaVersion == 1 else {
                logger.error("Unknown shortcut rule schema \(envelope.schemaVersion, privacy: .public)")
                return ShortcutRuleLoadResult(
                    rules: ShortcutRule.defaults,
                    issue: .unknownSchema(envelope.schemaVersion)
                )
            }
            let document = try decoder.decode(ShortcutRuleDocumentV1.self, from: data)
            guard Self.validationError(for: document.rules) == nil else {
                logger.error("Shortcut rules do not satisfy the registry invariants")
                return ShortcutRuleLoadResult(rules: ShortcutRule.defaults, issue: .corruptData)
            }
            return ShortcutRuleLoadResult(rules: document.rules, issue: nil)
        } catch {
            logger.error("Corrupt shortcut rules")
            return ShortcutRuleLoadResult(rules: ShortcutRule.defaults, issue: .corruptData)
        }
    }

    func save(_ rules: [ShortcutRule]) throws {
        if let error = Self.validationError(for: rules) {
            throw error
        }
        let data = try encoder.encode(ShortcutRuleDocumentV1(schemaVersion: 1, rules: rules))
        defaults.set(data, forKey: key)
    }

    static func validationError(for rules: [ShortcutRule]) -> ShortcutRuleStoreError? {
        guard rules.allSatisfy({ !$0.binding.modifiers.isEmpty }) else {
            return .emptyModifiers
        }

        var actionIDs = Set<ShortcutActionID>()
        for rule in rules where !actionIDs.insert(rule.id).inserted {
            return .duplicateActionID
        }

        var enabledBindings = Set<ShortcutBinding>()
        for rule in rules where rule.isEnabled {
            guard enabledBindings.insert(rule.binding).inserted else {
                return .duplicateBinding
            }
        }

        guard let protectedRule = rules.first(where: { $0.id == .screenWipeExit }) else {
            return .protectedRuleMissing
        }
        guard protectedRule.isEnabled else {
            return .protectedRuleDisabled
        }
        guard actionIDs == Set(ShortcutActionID.allCases) else {
            return .incompleteActionSet
        }

        return nil
    }
}

private struct ShortcutRuleVersionEnvelope: Decodable {
    let schemaVersion: Int
}

private struct ShortcutRuleDocumentV1: Codable {
    let schemaVersion: Int
    let rules: [ShortcutRule]
}

enum ShortcutRuleStoreIssue: Equatable, Sendable {
    case corruptData
    case unknownSchema(Int)
}

enum ShortcutRuleStoreError: Error, Equatable {
    case emptyModifiers
    case duplicateActionID
    case duplicateBinding
    case protectedRuleMissing
    case protectedRuleDisabled
    case incompleteActionSet
}
