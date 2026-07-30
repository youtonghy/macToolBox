import XCTest
@testable import ToolBox

final class DisplayControlExperimentalFeaturesTests: XCTestCase {
    func testExperimentalColorPresetFlagDefaultsOff() {
        let suiteName = "test.displayControl.experimental.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let features = DisplayControlExperimentalFeatures(defaults: defaults)

        XCTAssertFalse(features.colorPresetPOCEnabled)
        XCTAssertNil(defaults.object(forKey: DisplayControlExperimentalFeatures.colorPresetPOCKey))
    }

    func testExperimentalColorPresetFlagRoundTrips() {
        let suiteName = "test.displayControl.experimental.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let features = DisplayControlExperimentalFeatures(defaults: defaults)

        features.colorPresetPOCEnabled = true

        XCTAssertTrue(features.colorPresetPOCEnabled)
        XCTAssertTrue(defaults.bool(forKey: DisplayControlExperimentalFeatures.colorPresetPOCKey))
    }
}
