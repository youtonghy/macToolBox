import Foundation

struct FocusModeStore {
    static let enabledKey = "focusMode.enabled"
    static let opacityKey = "focusMode.overlayOpacity"
    static let defaultOpacity = 0.55
    static let opacityRange = 0.20...0.85

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FocusModeConfiguration {
        let storedOpacity: Double
        if defaults.object(forKey: Self.opacityKey) == nil {
            storedOpacity = Self.defaultOpacity
        } else {
            storedOpacity = defaults.double(forKey: Self.opacityKey)
        }
        return FocusModeConfiguration(
            isEnabled: defaults.bool(forKey: Self.enabledKey),
            overlayOpacity: Self.normalizedOpacity(storedOpacity)
        )
    }

    func save(_ configuration: FocusModeConfiguration) {
        defaults.set(configuration.isEnabled, forKey: Self.enabledKey)
        defaults.set(
            Self.normalizedOpacity(configuration.overlayOpacity),
            forKey: Self.opacityKey
        )
    }

    static func normalizedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }
}
