import Carbon.HIToolbox
import XCTest
@testable import ToolBoxCore

private struct ShortcutRuleDocumentV1: Codable {
    let schemaVersion: Int
    let rules: [ShortcutRule]
}

final class ShortcutRuleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ShortcutRuleStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.shortcutRules.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = ShortcutRuleStore(defaults: defaults, key: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingDataReturnsApprovedDefaults() {
        let result = store.load()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.rules, approvedDefaults)
    }

    func testRuleDefaultsExposeApprovedBindingsForRegistryStartup() {
        XCTAssertEqual(ShortcutRule.defaults, [
            .init(
                id: .captureRegion,
                binding: .init(
                    keyCode: UInt32(kVK_ANSI_S),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
            .init(
                id: .screenWipeExit,
                binding: .init(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: [.control, .option, .command]
                ),
                isEnabled: true
            ),
            .init(
                id: .clipboardHistory,
                binding: .init(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
        ])
    }

    func testSaveRejectsDisabledProtectedRule() {
        var rules = store.load().rules
        rules[rules.firstIndex(where: { $0.id == .screenWipeExit })!].isEnabled = false

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .protectedRuleDisabled)
        }
    }

    func testMigrationBackfillsMissingActions() throws {
        // Save old rules missing clipboardHistory
        let oldRules = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_S),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: [.control, .option, .command]
                ),
                isEnabled: true
            ),
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(ShortcutRuleDocumentV1(schemaVersion: 1, rules: oldRules))
        defaults.set(data, forKey: suiteName)

        // Load should backfill missing clipboardHistory
        let result = store.load()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.rules.count, 3)
        XCTAssertTrue(result.rules.contains(where: { $0.id == .clipboardHistory }))
    }

    func testMigrationDisablesConflictingBinding() throws {
        // Save old rules with captureRegion using the default clipboardHistory binding
        let oldRules = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: [.control, .option, .command]
                ),
                isEnabled: true
            ),
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(ShortcutRuleDocumentV1(schemaVersion: 1, rules: oldRules))
        defaults.set(data, forKey: suiteName)

        // Load should add clipboardHistory but disabled due to conflict
        let result = store.load()

        XCTAssertNil(result.issue)
        let clipboardRule = result.rules.first(where: { $0.id == .clipboardHistory })
        XCTAssertNotNil(clipboardRule)
        XCTAssertFalse(clipboardRule?.isEnabled ?? true, "Conflicting rule should be disabled")
    }

    func testRoundTripPreservesRules() throws {
        let rules = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_A),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: [.control, .option, .command]
                ),
                isEnabled: true
            ),
            ShortcutRule(
                id: .clipboardHistory,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
        ]

        try store.save(rules)

        XCTAssertEqual(store.load(), ShortcutRuleLoadResult(rules: rules, issue: nil))
    }

    func testSaveRejectsEmptyModifiers() {
        var rules = store.load().rules
        rules[0] = ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: []),
            isEnabled: true
        )

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .emptyModifiers)
        }
    }

    func testSaveRejectsDuplicateActionIDs() {
        let rules = store.load().rules + [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_A),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
        ]

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .duplicateActionID)
        }
    }

    func testSaveRejectsEnabledDuplicateBindings() {
        var rules = store.load().rules
        rules[0] = ShortcutRule(
            id: .captureRegion,
            binding: rules[1].binding,
            isEnabled: true
        )

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .duplicateBinding)
        }
    }

    func testSaveRejectsMissingProtectedRule() {
        let rules = store.load().rules.filter { $0.id != .screenWipeExit }

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .protectedRuleMissing)
        }
    }

    func testSaveRejectsMissingCaptureRule() {
        let rules = store.load().rules.filter { $0.id != .captureRegion }

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .incompleteActionSet)
        }
    }

    func testUnknownSchemaReturnsDefaultsWithoutOverwriting() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "rules": [],
        ])
        defaults.set(data, forKey: suiteName)

        XCTAssertEqual(
            store.load(),
            ShortcutRuleLoadResult(
                rules: approvedDefaults,
                issue: .unknownSchema(99)
            )
        )
        XCTAssertEqual(defaults.data(forKey: suiteName), data)
    }

    func testUnknownSchemaIsDetectedBeforeDecodingVersionSpecificFields() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "futureRules": ["format": "different"],
        ])
        defaults.set(data, forKey: suiteName)

        XCTAssertEqual(
            store.load(),
            ShortcutRuleLoadResult(
                rules: approvedDefaults,
                issue: .unknownSchema(2)
            )
        )
        XCTAssertEqual(defaults.data(forKey: suiteName), data)
    }

    func testCorruptDataReturnsDefaultsWithoutOverwriting() {
        let data = Data("broken".utf8)
        defaults.set(data, forKey: suiteName)

        XCTAssertEqual(
            store.load(),
            ShortcutRuleLoadResult(rules: approvedDefaults, issue: .corruptData)
        )
        XCTAssertEqual(defaults.data(forKey: suiteName), data)
    }

    func testLoadRejectsStoredDisabledProtectedRule() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "rules": [
                [
                    "id": ShortcutActionID.captureRegion.rawValue,
                    "binding": [
                        "keyCode": UInt32(kVK_ANSI_S),
                        "modifiers": ShortcutModifiers.control.union(.option).rawValue,
                    ],
                    "isEnabled": true,
                ],
                [
                    "id": ShortcutActionID.screenWipeExit.rawValue,
                    "binding": [
                        "keyCode": UInt32(kVK_Escape),
                        "modifiers": ShortcutModifiers.control.union(.option).union(.command).rawValue,
                    ],
                    "isEnabled": false,
                ],
            ],
        ])
        defaults.set(data, forKey: suiteName)

        XCTAssertEqual(
            store.load(),
            ShortcutRuleLoadResult(rules: approvedDefaults, issue: .corruptData)
        )
    }

    private var approvedDefaults: [ShortcutRule] {
        [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_S),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: [.control, .option, .command]
                ),
                isEnabled: true
            ),
            ShortcutRule(
                id: .clipboardHistory,
                binding: ShortcutBinding(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
        ]
    }
}
