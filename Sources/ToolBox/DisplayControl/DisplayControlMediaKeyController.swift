import Combine
import CoreGraphics

/// Resolves the active external display and executes semantic media-key actions.
/// The shared ShortcutRegistry owns the underlying CGEventTap and its permissions.
@MainActor
final class DisplayControlMediaKeyController {
    private let service: DisplayControlService
    private let menuModel: DisplayControlMenuModel
    private let shortcutRegistry: ShortcutRegistry
    private var cancellables = Set<AnyCancellable>()
    private var targetDisplayID: CGDirectDisplayID?
    private var isStarted = false
    private var isRoutingEnabled = false

    init(
        service: DisplayControlService,
        menuModel: DisplayControlMenuModel,
        shortcutRegistry: ShortcutRegistry
    ) {
        self.service = service
        self.menuModel = menuModel
        self.shortcutRegistry = shortcutRegistry
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Publishers.CombineLatest(menuModel.$selectedDisplayID, menuModel.$displayItems)
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedDisplayID, items in
                self?.updateTarget(selectedDisplayID: selectedDisplayID, displayItems: items)
            }
            .store(in: &cancellables)
        updateTarget(
            selectedDisplayID: menuModel.selectedDisplayID,
            displayItems: menuModel.displayItems
        )
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancellables.removeAll()
        targetDisplayID = nil
        shortcutRegistry.setMediaKeyRoutingEnabled(false)
    }

    /// Media-key interception is opt-in. Merely connecting a controllable display
    /// must not take brightness, volume, or mute keys away from macOS.
    func setRoutingEnabled(_ enabled: Bool) {
        guard isRoutingEnabled != enabled else { return }
        isRoutingEnabled = enabled
        updateRoutingState()
    }

    func handle(event: ShortcutMediaKeyEvent) -> Bool {
        guard let targetDisplayID else { return false }
        guard event.isPressed else { return true }

        switch event.key {
        case .brightnessUp:
            service.stepValue(displayID: targetDisplayID, kind: .brightness, delta: 0.05)
        case .brightnessDown:
            service.stepValue(displayID: targetDisplayID, kind: .brightness, delta: -0.05)
        case .soundUp:
            service.stepValue(displayID: targetDisplayID, kind: .volume, delta: 0.05)
        case .soundDown:
            service.stepValue(displayID: targetDisplayID, kind: .volume, delta: -0.05)
        case .mute:
            service.toggleMute(displayID: targetDisplayID)
        case .contrastUp:
            service.stepValue(displayID: targetDisplayID, kind: .contrast, delta: 0.05)
        case .contrastDown:
            service.stepValue(displayID: targetDisplayID, kind: .contrast, delta: -0.05)
        }
        return true
    }

    private func updateTarget(
        selectedDisplayID: CGDirectDisplayID?,
        displayItems: [DisplayControlPickerItem]
    ) {
        if let selectedDisplayID,
           let selected = displayItems.first(where: { $0.id == selectedDisplayID }),
           selected.isControllable {
            targetDisplayID = selectedDisplayID
        } else {
            targetDisplayID = displayItems.first(where: { $0.isControllable })?.id
        }
        updateRoutingState()
    }

    private func updateRoutingState() {
        shortcutRegistry.setMediaKeyRoutingEnabled(
            isStarted && isRoutingEnabled && targetDisplayID != nil
        )
    }
}
