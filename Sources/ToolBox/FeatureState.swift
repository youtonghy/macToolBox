import Foundation
import Combine

/// Single source of truth for the feature toggles, observed by the popover.
/// AppDelegate wires Combine sinks that react to changes and drive the coordinators.
final class FeatureState: ObservableObject {
    @Published var wipeOn = false
    @Published var awakeOn = false
    @Published var clipboardOn: Bool {
        didSet { UserDefaults.standard.set(clipboardOn, forKey: Self.clipboardKey) }
    }
    @Published var duoOn: Bool {
        didSet { UserDefaults.standard.set(duoOn, forKey: Self.duoKey) }
    }

    private static let clipboardKey = "feature.clipboard.enabled"
    private static let duoKey = DuoEffectModel.enabledKey

    init() {
        clipboardOn = UserDefaults.standard.bool(forKey: Self.clipboardKey)
        duoOn = UserDefaults.standard.bool(forKey: Self.duoKey)
    }
}
