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
        XCTAssertEqual(result.settings.executionProvider, .cpu)
        XCTAssertTrue(result.settings.localOnly)
        XCTAssertNil(result.issue)
    }

    func testPersistsProfileAndNormalizesLegacyExecutionProvider() throws {
        let store = makeStore()
        var settings = OCRSettings.defaults
        settings.profile = .small
        settings.executionProvider = .coreML

        XCTAssertNoThrow(try store.save(settings))
        let loaded = store.load()
        XCTAssertEqual(loaded.settings.profile, .small)
        XCTAssertEqual(loaded.settings.executionProvider, .cpu)
        XCTAssertNil(loaded.issue)
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

    func testMigratesV1SettingsToPipelineAwareSelectionWithoutWritingBack() throws {
        let store = makeStore()
        let legacy = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "settings": [
                    "pipeline": "ppOCRv6",
                    "profile": "small",
                    "executionProvider": "cpu",
                    "localOnly": true,
                ],
            ]
        )
        defaults.set(legacy, forKey: suiteName)

        let result = store.load()

        XCTAssertNil(result.issue)
        XCTAssertEqual(
            result.settings.selection,
            OCRModelSelection(pipeline: .ppOCRv6, variantID: "small")
        )
        XCTAssertEqual(defaults.data(forKey: suiteName), legacy)
    }

    func testPersistsAdvancedPipelineVariantWithInjectedAvailability() throws {
        let store = makeStore(availability: OCRRuntimeAvailability(gates: [
            .init(
                pipeline: .ppOCRv6,
                architectures: [.arm64],
                deviceClasses: [.appleSiliconM1OrNewer]
            ),
            .init(
                pipeline: .ppStructureV3,
                architectures: [.arm64],
                deviceClasses: [.appleSiliconM1OrNewer]
            ),
            .init(
                pipeline: .paddleOCRVL,
                architectures: [.arm64],
                deviceClasses: [.appleSiliconM1OrNewer]
            ),
        ]))
        var settings = OCRSettings.defaults
        settings.selection = OCRModelSelection(
            pipeline: .paddleOCRVL,
            variantID: "v1.6"
        )

        XCTAssertNoThrow(try store.save(settings))
        XCTAssertEqual(store.load().settings.selection, settings.selection)
    }

    func testRejectsVariantThatDoesNotBelongToPipeline() {
        var settings = OCRSettings.defaults
        settings.selection = OCRModelSelection(
            pipeline: .ppOCRv6,
            variantID: "v1.6"
        )

        XCTAssertThrowsError(try makeStore().save(settings)) {
            XCTAssertEqual($0 as? OCRSettingsError, .unavailableVariant)
        }
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

        XCTAssertEqual(arm, [.ppOCRv6, .ppStructureV3, .paddleOCRVL])
        XCTAssertTrue(intel.isEmpty)
        XCTAssertTrue(arm.contains(.ppStructureV3))
        XCTAssertTrue(arm.contains(.paddleOCRVL))
    }

    private func makeStore(
        availability: OCRRuntimeAvailability = .shipped
    ) -> OCRSettingsStore {
        OCRSettingsStore(
            defaults: defaults,
            key: suiteName,
            availability: availability
        )
    }
}
