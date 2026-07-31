import Combine
import Foundation

enum ShortcutSettingsIssue: Equatable {
    case duplicateBinding
    case invalidShortcut
    case protectedShortcut
    case systemConflict
    case registryUnavailable
    case cleanupRequired
    case persistenceFailure
    case rollbackFailure
}

@MainActor
final class ShortcutSettingsModel: ObservableObject {
    typealias Load = () -> ShortcutRuleLoadResult
    typealias Save = ([ShortcutRule]) throws -> Void
    typealias ApplyRules = ([ShortcutRule]) throws -> Void

    @Published private(set) var rules: [ShortcutRule]
    @Published private(set) var loadIssue: ShortcutRuleStoreIssue?
    @Published private(set) var issue: ShortcutSettingsIssue?
    @Published private(set) var issueAction: ShortcutActionID?

    private let save: Save
    private let applyRules: ApplyRules

    init(
        load: Load,
        save: @escaping Save,
        applyRules: @escaping ApplyRules
    ) {
        let result = load()
        rules = result.rules
        loadIssue = result.issue
        self.save = save
        self.applyRules = applyRules
    }

    convenience init(
        store: ShortcutRuleStore = ShortcutRuleStore(),
        registry: ShortcutRegistry
    ) {
        self.init(
            load: { store.load() },
            save: { try store.save($0) },
            applyRules: { try registry.apply(rules: $0) }
        )
    }

    func rule(for action: ShortcutActionID) -> ShortcutRule? {
        rules.first { $0.id == action }
    }

    func setBinding(_ binding: ShortcutBinding, for action: ShortcutActionID) {
        guard let current = rule(for: action) else {
            issue = .invalidShortcut
            issueAction = action
            return
        }
        replace(
            ShortcutRule(
                id: action,
                binding: binding,
                isEnabled: current.isEnabled
            )
        )
    }

    func setEnabled(_ isEnabled: Bool, for action: ShortcutActionID) {
        guard var replacement = rule(for: action) else {
            issue = .invalidShortcut
            issueAction = action
            return
        }
        replacement.isEnabled = isEnabled
        replace(replacement)
    }

    func restoreDefaults() {
        commit(
            ShortcutRule.defaults,
            forcePersistence: loadIssue != nil
        )
    }

    func restoreDefault(for action: ShortcutActionID) {
        guard let defaultRule = ShortcutRule.defaults.first(where: { $0.id == action }) else {
            issue = .invalidShortcut
            return
        }
        replace(defaultRule)
    }

    func clearIssue() {
        issue = nil
        issueAction = nil
    }

    private func replace(_ replacement: ShortcutRule) {
        guard let index = rules.firstIndex(where: { $0.id == replacement.id }) else {
            issue = .invalidShortcut
            issueAction = replacement.id
            return
        }
        var proposed = rules
        proposed[index] = replacement
        commit(proposed, relatedAction: replacement.id)
    }

    private func commit(
        _ proposed: [ShortcutRule],
        relatedAction: ShortcutActionID? = nil,
        forcePersistence: Bool = false
    ) {
        let rulesChanged = proposed != rules
        guard rulesChanged || forcePersistence else {
            issue = nil
            issueAction = nil
            return
        }
        if let validationError = ShortcutRuleStore.validationError(for: proposed) {
            issue = settingsIssue(for: validationError)
            issueAction = relatedAction
            return
        }

        let previous = rules
        if rulesChanged {
            do {
                try applyRules(proposed)
            } catch {
                issue = settingsIssue(for: error)
                issueAction = relatedAction
                return
            }
        }

        do {
            try save(proposed)
        } catch {
            issue = !rulesChanged || rollback(to: previous)
                ? .persistenceFailure
                : .rollbackFailure
            issueAction = relatedAction
            return
        }

        rules = proposed
        issue = nil
        issueAction = nil
        loadIssue = nil
    }

    private func rollback(to oldRules: [ShortcutRule]) -> Bool {
        do {
            try applyRules(oldRules)
            return true
        } catch {
            return false
        }
    }

    private func settingsIssue(for error: Error) -> ShortcutSettingsIssue {
        if let storeError = error as? ShortcutRuleStoreError {
            return settingsIssue(for: storeError)
        }
        guard let registryError = error as? ShortcutRegistryError else {
            return .systemConflict
        }
        switch registryError {
        case .notStarted:
            return .registryUnavailable
        case .cleanupRequired, .rollbackFailed:
            return .cleanupRequired
        case .duplicateBinding:
            return .duplicateBinding
        case .protectedRuleMissing, .protectedRuleDisabled:
            return .protectedShortcut
        case .emptyModifiers, .duplicateActionID, .incompleteActionSet:
            return .invalidShortcut
        case .handlerInstallFailed, .registrationFailed, .unregistrationFailed:
            return .systemConflict
        }
    }

    private func settingsIssue(
        for error: ShortcutRuleStoreError
    ) -> ShortcutSettingsIssue {
        switch error {
        case .duplicateBinding:
            return .duplicateBinding
        case .protectedRuleMissing, .protectedRuleDisabled:
            return .protectedShortcut
        case .emptyModifiers, .duplicateActionID, .incompleteActionSet:
            return .invalidShortcut
        }
    }
}
