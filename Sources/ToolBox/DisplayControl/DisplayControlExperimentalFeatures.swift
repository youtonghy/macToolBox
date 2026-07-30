import Foundation

final class DisplayControlExperimentalFeatures {
    static let colorPresetPOCKey = "displayControl.experimental.colorPresetPOC"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var colorPresetPOCEnabled: Bool {
        get { defaults.bool(forKey: Self.colorPresetPOCKey) }
        set { defaults.set(newValue, forKey: Self.colorPresetPOCKey) }
    }
}
