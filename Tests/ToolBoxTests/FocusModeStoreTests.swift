import XCTest
@testable import ToolBoxCore

final class FocusModeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FocusModeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingConfigurationLoadsDisabledDefault() {
        let store = FocusModeStore(defaults: defaults)

        XCTAssertEqual(
            store.load(),
            FocusModeConfiguration(isEnabled: false, overlayOpacity: 0.55)
        )
    }

    func testConfigurationRoundTrips() {
        let store = FocusModeStore(defaults: defaults)

        store.save(FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.63))

        XCTAssertEqual(
            store.load(),
            FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.63)
        )
    }

    func testOpacityIsFiniteAndClampedWhenSaving() {
        let store = FocusModeStore(defaults: defaults)

        store.save(FocusModeConfiguration(isEnabled: true, overlayOpacity: .nan))
        XCTAssertEqual(store.load().overlayOpacity, 0.55)

        store.save(FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.10))
        XCTAssertEqual(store.load().overlayOpacity, 0.20)

        store.save(FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.95))
        XCTAssertEqual(store.load().overlayOpacity, 0.85)
    }

    func testCorruptStoredOpacityFallsBackToDefault() {
        defaults.set(true, forKey: FocusModeStore.enabledKey)
        defaults.set(Double.nan, forKey: FocusModeStore.opacityKey)

        XCTAssertEqual(
            FocusModeStore(defaults: defaults).load(),
            FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55)
        )
    }
}
