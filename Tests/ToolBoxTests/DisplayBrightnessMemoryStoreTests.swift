import XCTest
@testable import ToolBoxCore

final class DisplayBrightnessMemoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var key: String!
    private let identity = DisplayBrightnessMemoryIdentity(
        vendorNumber: 0x10AC,
        modelNumber: 0xA419,
        serialNumber: 123_456
    )

    override func setUp() {
        super.setUp()
        suiteName = "test.displayBrightnessMemory.\(UUID().uuidString)"
        key = "display.brightnessMemory.test"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        key = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingMemoryReturnsNil() {
        let store = makeStore()

        XCTAssertNil(store.load(for: identity))
    }

    func testSavedBrightnessSurvivesStoreRecreation() throws {
        makeStore().save(0.42, for: identity)

        let restored = try XCTUnwrap(makeStore().load(for: identity))

        XCTAssertEqual(restored, 0.42, accuracy: 0.0001)
    }

    func testMalformedPayloadIsIgnoredWithoutOverwrite() {
        let payload = Data("not-json".utf8)
        defaults.set(payload, forKey: key)

        XCTAssertNil(makeStore().load(for: identity))
        XCTAssertEqual(defaults.data(forKey: key), payload)
    }

    func testUnknownSchemaIsIgnoredWithoutOverwrite() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "entries": []
        ])
        defaults.set(payload, forKey: key)

        XCTAssertNil(makeStore().load(for: identity))
        XCTAssertEqual(defaults.data(forKey: key), payload)
    }

    func testOutOfRangeStoredBrightnessIsIgnored() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "entries": [[
                "identity": [
                    "vendorNumber": identity.vendorNumber,
                    "modelNumber": identity.modelNumber,
                    "serialNumber": identity.serialNumber
                ],
                "normalizedValue": 1.5
            ]]
        ])
        defaults.set(payload, forKey: key)

        XCTAssertNil(makeStore().load(for: identity))
    }

    func testOutOfRangeSaveDoesNotReplaceValidMemory() throws {
        let store = makeStore()
        store.save(0.35, for: identity)

        store.save(.infinity, for: identity)

        XCTAssertEqual(try XCTUnwrap(store.load(for: identity)), 0.35, accuracy: 0.0001)
    }

    private func makeStore() -> DisplayBrightnessMemoryStore {
        DisplayBrightnessMemoryStore(defaults: defaults, key: key)
    }
}
