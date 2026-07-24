import XCTest
@testable import ToolBox

final class AudioRuleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: AudioRuleStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.audioRules.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = AudioRuleStore(defaults: defaults, key: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRuleDefaultsToNativeVolumeAndSystemOutput() {
        let rule = AppAudioRule(bundleID: "us.zoom.xos")

        XCTAssertEqual(rule.volumePercent, 100)
        XCTAssertNil(rule.outputDeviceUID)
    }

    func testRuleClampsVolumeToSupportedRange() {
        XCTAssertEqual(AppAudioRule(bundleID: "low", volumePercent: -10).volumePercent, 0)
        XCTAssertEqual(AppAudioRule(bundleID: "high", volumePercent: 450).volumePercent, 300)
    }

    func testRoundTripPreservesRules() throws {
        let rules = [
            AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 300, outputDeviceUID: "headset")
        ]

        try store.save(rules)
        let loaded = store.load()

        XCTAssertNil(loaded.issue)
        XCTAssertEqual(loaded.rules, rules)
    }

    func testCorruptDataFailsClosedWithoutOverwriting() {
        let data = Data("broken".utf8)
        defaults.set(data, forKey: suiteName)

        let loaded = store.load()

        XCTAssertEqual(loaded.rules, [])
        XCTAssertEqual(loaded.issue, .corruptData)
        XCTAssertEqual(defaults.data(forKey: suiteName), data)
    }

    func testUnknownSchemaFailsClosedWithoutOverwriting() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "rules": []
        ])
        defaults.set(data, forKey: suiteName)

        let loaded = store.load()

        XCTAssertEqual(loaded.rules, [])
        XCTAssertEqual(loaded.issue, .unknownSchema(99))
        XCTAssertEqual(defaults.data(forKey: suiteName), data)
    }

    func testDuplicateBundleIDsKeepLatestDocumentEntry() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "rules": [
                [
                    "bundleID": "us.zoom.xos",
                    "volumePercent": 125
                ],
                [
                    "bundleID": "us.zoom.xos",
                    "volumePercent": 250,
                    "outputDeviceUID": "headset"
                ]
            ]
        ])
        defaults.set(data, forKey: suiteName)

        let loaded = store.load()

        XCTAssertNil(loaded.issue)
        XCTAssertEqual(
            loaded.rules,
            [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 250, outputDeviceUID: "headset")]
        )
    }

    func testSaveRejectsEmptyBundleID() {
        XCTAssertThrowsError(try store.save([AppAudioRule(bundleID: "")])) { error in
            guard case AudioRuleStoreError.invalidBundleID = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(defaults.data(forKey: suiteName))
    }

    func testLoadRejectsStoredEmptyBundleID() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "rules": [["bundleID": "", "volumePercent": 100]]
        ])
        defaults.set(data, forKey: suiteName)

        XCTAssertEqual(
            store.load(),
            AudioRuleLoadResult(rules: [], issue: .corruptData)
        )
    }
}
