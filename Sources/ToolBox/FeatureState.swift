import Foundation
import Combine

/// Single source of truth for the three feature toggles, observed by the popover.
/// AppDelegate wires Combine sinks that react to changes and drive the coordinators.
final class FeatureState: ObservableObject {
    @Published var wipeOn = false
    @Published var awakeOn = false
    @Published var parkOn = false
}
