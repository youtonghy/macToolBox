import XCTest
@testable import ToolBox

final class OCRSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.ocr.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingSettingsUseTinyLocalOnlyDefaults() {
        let result = makeStore().load()

        XCTAssertEqual(result.settings.pipeline, .ppOCRv6)
        XCTAssertEqual(result.settings.profile, .tiny)
        XCTAssertEqual(result.settings.language, .automatic)
        XCTAssertEqual(result.settings.executionProvider, .cpu)
        XCTAssertTrue(result.settings.localOnly)
        XCTAssertNil(result.issue)
    }

    func testJapaneseRequiresSmallOrMedium() throws {
        let store = makeStore()
        var settings = OCRSettings.defaults
        settings.language = .japanese

        XCTAssertThrowsError(try store.save(settings)) {
            XCTAssertEqual($0 as? OCRSettingsError, .japaneseUnsupportedByTiny)
        }

        settings.profile = .small
        XCTAssertNoThrow(try store.save(settings))
        XCTAssertEqual(store.load().settings, settings)
    }

    func testCannotDisableLocalOnlyInvariant() {
        var settings = OCRSettings.defaults
        settings.localOnly = false

        XCTAssertThrowsError(try makeStore().save(settings)) {
            XCTAssertEqual($0 as? OCRSettingsError, .cloudFallbackForbidden)
        }
    }

    func testCorruptAndUnknownSchemaFallBackWithoutOverwriting() throws {
        let store = makeStore()
        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: suiteName)
        XCTAssertEqual(store.load().issue, .corruptData)
        XCTAssertEqual(defaults.data(forKey: suiteName), corrupt)

        let future = try JSONSerialization.data(withJSONObject: ["schemaVersion": 9])
        defaults.set(future, forKey: suiteName)
        XCTAssertEqual(store.load().issue, .unknownSchema(9))
        XCTAssertEqual(defaults.data(forKey: suiteName), future)
    }

    func testAvailabilityFiltersUngatedAdvancedPipelinesAndIntelRuntime() {
        let arm = OCRRuntimeAvailability.shipped.availablePipelines(
            architecture: .arm64,
            deviceClass: .appleSiliconM1OrNewer
        )
        let intel = OCRRuntimeAvailability.shipped.availablePipelines(
            architecture: .x86_64,
            deviceClass: .intel
        )

        XCTAssertEqual(arm, [.ppOCRv6])
        XCTAssertTrue(intel.isEmpty)
        XCTAssertFalse(arm.contains(.ppStructureV3))
        XCTAssertFalse(arm.contains(.paddleOCRVL))
    }

    private func makeStore() -> OCRSettingsStore {
        OCRSettingsStore(defaults: defaults, key: suiteName)
    }
}
