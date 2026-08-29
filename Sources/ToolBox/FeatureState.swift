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

    private static let clipboardKey = "feature.clipboard.enabled"

    init() {
        clipboardOn = UserDefaults.standard.bool(forKey: Self.clipboardKey)
    }
}
