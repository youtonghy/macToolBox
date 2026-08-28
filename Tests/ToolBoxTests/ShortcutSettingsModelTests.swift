import Carbon.HIToolbox
import XCTest
@testable import ToolBoxCore

@MainActor
final class ShortcutSettingsModelTests: XCTestCase {
    func testCorruptStoreIssueIsExposedWithoutChangingFallbackRules() {
        let harness = ShortcutSettingsHarness(
            loadResult: ShortcutRuleLoadResult(
                rules: ShortcutRule.defaults,
                issue: .corruptData
            )
        )

        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
        XCTAssertEqual(harness.model.loadIssue, .corruptData)
    }

    func testDuplicateBindingIsRejectedBeforeCarbonOrPersistence() {
        let harness = ShortcutSettingsHarness()
        let wipeBinding = ShortcutRule.defaults[1].binding

        harness.model.setBinding(wipeBinding, for: .captureRegion)

        XCTAssertEqual(harness.model.issue, .duplicateBinding)
        XCTAssertTrue(harness.appliedRuleSets.isEmpty)
        XCTAssertTrue(harness.savedRuleSets.isEmpty)
        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
    }

    func testSystemConflictKeepsDisplayedAndPersistedRuleUnchanged() {
        let harness = ShortcutSettingsHarness()
        harness.applyError = ShortcutRegistryError.registrationFailed(
            OSStatus(eventHotKeyExistsErr)
        )
        let replacement = ShortcutBinding(keyCode: 1, modifiers: [.command])

        harness.model.setBinding(replacement, for: .captureRegion)

        XCTAssertEqual(harness.model.issue, .systemConflict)
        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
        XCTAssertTrue(harness.savedRuleSets.isEmpty)
    }

    func testSuccessfulBindingChangeAppliesThenSavesExactlyOnce() {
        let harness = ShortcutSettingsHarness()
        let replacement = ShortcutBinding(keyCode: 1, modifiers: [.command])

        harness.model.setBinding(replacement, for: .captureRegion)

        XCTAssertEqual(harness.appliedRuleSets, [[
            ShortcutRule(
                id: .captureRegion,
                binding: replacement,
                isEnabled: true
            ),
            ShortcutRule.defaults[1],
            ShortcutRule.defaults[2],
        ]])
        XCTAssertEqual(harness.savedRuleSets.count, 1)
        XCTAssertEqual(harness.model.rule(for: .captureRegion)?.binding, replacement)
        XCTAssertNil(harness.model.issue)
    }

    func testPersistenceFailureRollsCarbonBackToDisplayedRule() {
        let harness = ShortcutSettingsHarness()
        harness.saveError = NSError(domain: "ShortcutSettingsModelTests", code: 1)
        let replacement = ShortcutBinding(keyCode: 1, modifiers: [.command])

        harness.model.setBinding(replacement, for: .captureRegion)

        XCTAssertEqual(harness.model.issue, .persistenceFailure)
        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
        XCTAssertEqual(harness.appliedRuleSets.count, 2)
        XCTAssertEqual(harness.appliedRuleSets[0][0].binding, replacement)
        XCTAssertEqual(harness.appliedRuleSets[1], ShortcutRule.defaults)
    }

    func testCaptureCanBeDisabled() {
        let harness = ShortcutSettingsHarness()

        harness.model.setEnabled(false, for: .captureRegion)

        XCTAssertEqual(harness.model.rule(for: .captureRegion)?.isEnabled, false)
        XCTAssertEqual(harness.appliedRuleSets.last?.first?.isEnabled, false)
        XCTAssertEqual(harness.savedRuleSets.count, 1)
    }

    func testProtectedWipeExitCannotBeDisabled() {
        let harness = ShortcutSettingsHarness()

        harness.model.setEnabled(false, for: .screenWipeExit)

        XCTAssertEqual(harness.model.issue, .protectedShortcut)
        XCTAssertEqual(harness.model.rule(for: .screenWipeExit)?.isEnabled, true)
        XCTAssertTrue(harness.appliedRuleSets.isEmpty)
        XCTAssertTrue(harness.savedRuleSets.isEmpty)
    }

    func testRestoreDefaultsAppliesChangedRulesAndSavesOnce() {
        var customRules = ShortcutRule.defaults
        customRules[0] = ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
            isEnabled: false
        )
        let harness = ShortcutSettingsHarness(
            loadResult: ShortcutRuleLoadResult(rules: customRules, issue: nil)
        )

        harness.model.restoreDefaults()

        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
        XCTAssertEqual(harness.appliedRuleSets, [ShortcutRule.defaults])
        XCTAssertEqual(harness.savedRuleSets, [ShortcutRule.defaults])
    }

    func testRestoreSingleDefaultAppliesAndSavesOnce() {
        var customRules = ShortcutRule.defaults
        customRules[0] = ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
            isEnabled: false
        )
        let harness = ShortcutSettingsHarness(
            loadResult: ShortcutRuleLoadResult(rules: customRules, issue: nil)
        )

        harness.model.restoreDefault(for: .captureRegion)

        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
        XCTAssertEqual(harness.appliedRuleSets, [ShortcutRule.defaults])
        XCTAssertEqual(harness.savedRuleSets, [ShortcutRule.defaults])
    }

    func testRestoreDefaultsRepairsCorruptPersistedConfiguration() {
        let harness = ShortcutSettingsHarness(
            loadResult: ShortcutRuleLoadResult(
                rules: ShortcutRule.defaults,
                issue: .corruptData
            )
        )

        harness.model.restoreDefaults()

        XCTAssertEqual(harness.savedRuleSets, [ShortcutRule.defaults])
        XCTAssertTrue(harness.appliedRuleSets.isEmpty)
        XCTAssertNil(harness.model.loadIssue)
        XCTAssertNil(harness.model.issue)
    }

    func testRestoreDefaultsKeepsLoadIssueWhenRepairCannotBePersisted() {
        let harness = ShortcutSettingsHarness(
            loadResult: ShortcutRuleLoadResult(
                rules: ShortcutRule.defaults,
                issue: .unknownSchema(2)
            )
        )
        harness.saveError = NSError(domain: "ShortcutSettingsModelTests", code: 2)

        harness.model.restoreDefaults()

        XCTAssertEqual(harness.model.issue, .persistenceFailure)
        XCTAssertEqual(harness.model.loadIssue, .unknownSchema(2))
        XCTAssertTrue(harness.appliedRuleSets.isEmpty)
    }

    func testRestoreDefaultsAppliesSwappedBindingsAsOneRuleSet() {
        let swapped = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutRule.defaults[1].binding,
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutRule.defaults[0].binding,
                isEnabled: true
            ),
        ]
        let harness = ShortcutSettingsHarness(
            loadResult: ShortcutRuleLoadResult(rules: swapped, issue: nil)
        )

        harness.model.restoreDefaults()

        XCTAssertEqual(harness.appliedRuleSets, [ShortcutRule.defaults])
        XCTAssertEqual(harness.savedRuleSets, [ShortcutRule.defaults])
        XCTAssertEqual(harness.model.rules, ShortcutRule.defaults)
    }
}

@MainActor
private final class ShortcutSettingsHarness {
    var appliedRuleSets: [[ShortcutRule]] = []
    var savedRuleSets: [[ShortcutRule]] = []
    var applyError: Error?
    var saveError: Error?
    private(set) lazy var model = ShortcutSettingsModel(
        load: { [loadResult] in loadResult },
        save: { [unowned self] rules in
            if let saveError { throw saveError }
            savedRuleSets.append(rules)
        },
        applyRules: { [unowned self] rules in
            if let applyError { throw applyError }
            appliedRuleSets.append(rules)
        }
    )

    private let loadResult: ShortcutRuleLoadResult

    init(
        loadResult: ShortcutRuleLoadResult = ShortcutRuleLoadResult(
            rules: ShortcutRule.defaults,
            issue: nil
        )
    ) {
        self.loadResult = loadResult
    }
}
