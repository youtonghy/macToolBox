import AppKit
import Combine
import CoreGraphics
import Foundation

struct DisplayControlPickerItem: Identifiable, Equatable {
    var id: CGDirectDisplayID
    var name: String
    var subtitle: String
    var isControllable: Bool
}

struct DisplayControlSliderItem: Identifiable, Equatable {
    var id: DisplayControlKind { kind }
    var kind: DisplayControlKind
    var title: String
    var symbolName: String
    var value: Double
    var percentText: String
    var step: Double
    var isEnabled: Bool
    var unavailableReason: String?
}

@MainActor
final class DisplayControlMenuModel: ObservableObject {
    @Published private(set) var displayItems: [DisplayControlPickerItem] = []
    @Published private(set) var sliderItems: [DisplayControlSliderItem] = []
    @Published private(set) var selectedDisplayName = "No external display"
    @Published private(set) var statusText = "No controllable external display"
    @Published private(set) var selectedMuted = false
    @Published private(set) var muteAvailable = false
    @Published var selectedDisplayID: CGDirectDisplayID?

    private let service: DisplayControlService
    private let pendingValueLifetimeNanos: UInt64
    private var cancellables = Set<AnyCancellable>()
    private var pendingValues: [DisplayControlPendingKey: Double] = [:]
    private var pendingClearTasks: [DisplayControlPendingKey: Task<Void, Never>] = [:]
    private var pendingClearIDs: [DisplayControlPendingKey: UUID] = [:]

    convenience init() {
        self.init(service: .shared)
    }

    init(
        service: DisplayControlService,
        pendingValueLifetimeNanos: UInt64 = 750_000_000
    ) {
        self.service = service
        self.pendingValueLifetimeNanos = pendingValueLifetimeNanos
    }

    var hasExternalDisplay: Bool {
        !displayItems.isEmpty
    }

    func start() {
        guard cancellables.isEmpty else { return }

        service.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.ingest(snapshot)
            }
            .store(in: &cancellables)
        ingest(service.snapshot)
    }

    func stop() {
        cancellables.removeAll()
        pendingClearTasks.values.forEach { $0.cancel() }
        pendingClearTasks.removeAll()
        pendingClearIDs.removeAll()
        pendingValues.removeAll()
    }

    func select(displayID: CGDirectDisplayID) {
        selectedDisplayID = displayID
        ingest(service.snapshot)
    }

    func setValue(kind: DisplayControlKind, value: Double) {
        guard let displayID = selectedDisplayID else { return }
        let value = service.quantizedValue(
            displayID: displayID,
            kind: kind,
            normalizedValue: value
        )
        setPendingValue(displayID: displayID, kind: kind, value: value)

        if kind == .volume {
            service.setVolume(displayID: displayID, normalizedValue: value)
            return
        }

        service.writeControl(displayID: displayID, kind: kind, normalizedValue: value)
    }

    func toggleMute() {
        guard let displayID = selectedDisplayID else { return }
        service.toggleMute(displayID: displayID)
    }

    func stepSelected(kind: DisplayControlKind, delta: Double) {
        guard let displayID = selectedDisplayID else { return }
        service.stepValue(displayID: displayID, kind: kind, delta: delta)
    }

    private func ingest(_ snapshot: DisplayControlSnapshot) {
        let externalDisplays = snapshot.displays.filter { !$0.isBuiltIn && !$0.isVirtual }
        displayItems = externalDisplays.map { display in
            DisplayControlPickerItem(
                id: display.id,
                name: display.name,
                subtitle: display.supportsHardwareDDC ? (display.backendName ?? "Hardware DDC") : (display.unavailableReason ?? "DDC unavailable"),
                isControllable: display.supportsHardwareDDC
            )
        }

        let availableIDs = Set(externalDisplays.map(\.id))
        if let selectedDisplayID, availableIDs.contains(selectedDisplayID) {
            self.selectedDisplayID = selectedDisplayID
        } else {
            self.selectedDisplayID = preferredDisplayID(from: externalDisplays)
        }

        guard let selected = externalDisplays.first(where: { $0.id == self.selectedDisplayID }) else {
            selectedDisplayName = "No external display"
            statusText = "No controllable external display"
            selectedMuted = false
            muteAvailable = false
            sliderItems = Self.makeEmptySliderItems()
            return
        }

        selectedDisplayName = selected.name
        if selected.controls.contains(where: { $0.status == .writeOnly }) {
            statusText = "DDC write-only - current values estimated"
        } else {
            statusText = selected.supportsHardwareDDC
                ? (selected.backendName ?? "Hardware DDC")
                : (selected.unavailableReason ?? "Hardware DDC unavailable")
        }
        let muteCapability = selected.controls.first(where: { $0.kind == .mute })
        selectedMuted = (muteCapability?.value?.normalized ?? 0) >= 0.5
        muteAvailable = muteCapability?.status.isWritable == true
        sliderItems = Self.controlKinds.map { makeSliderItem(kind: $0, display: selected) }
    }

    private func preferredDisplayID(from displays: [DisplayControlDisplay]) -> CGDirectDisplayID? {
        if let mouseDisplayID = Self.mouseDisplayID(),
           displays.contains(where: { $0.id == mouseDisplayID && $0.supportsHardwareDDC }) {
            return mouseDisplayID
        }
        return displays.first(where: \.supportsHardwareDDC)?.id ?? displays.first?.id
    }

    private func makeSliderItem(kind: DisplayControlKind, display: DisplayControlDisplay) -> DisplayControlSliderItem {
        guard let capability = display.controls.first(where: { $0.kind == kind }) else {
            return Self.emptySliderItem(kind: kind, reason: "Control was not reported by this display.")
        }

        let pending = pendingValues[DisplayControlPendingKey(displayID: display.id, kind: kind)]
        let value = pending
            ?? service.presentedValue(displayID: display.id, kind: kind)
            ?? capability.value?.normalized
            ?? 0
        return DisplayControlSliderItem(
            kind: kind,
            title: kind.title,
            symbolName: Self.symbolName(for: kind, value: value),
            value: value,
            percentText: Self.percentText(kind: kind, value: value),
            step: service.normalizedStep(displayID: display.id, kind: kind),
            isEnabled: capability.status.isWritable && kind.isContinuous,
            unavailableReason: capability.unavailableReason
        )
    }

    private func setPendingValue(displayID: CGDirectDisplayID, kind: DisplayControlKind, value: Double) {
        let key = DisplayControlPendingKey(displayID: displayID, kind: kind)
        pendingValues[key] = value
        pendingClearTasks[key]?.cancel()
        let taskID = UUID()
        pendingClearIDs[key] = taskID
        pendingClearTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: pendingValueLifetimeNanos)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled, pendingClearIDs[key] == taskID else { return }
            pendingValues[key] = nil
            pendingClearTasks[key] = nil
            pendingClearIDs[key] = nil
            ingest(service.snapshot)
        }
        ingest(service.snapshot)
    }

    private static let controlKinds: [DisplayControlKind] = [.brightness, .contrast, .volume]

    private static func makeEmptySliderItems() -> [DisplayControlSliderItem] {
        controlKinds.map { emptySliderItem(kind: $0, reason: nil) }
    }

    private static func emptySliderItem(kind: DisplayControlKind, reason: String?) -> DisplayControlSliderItem {
        DisplayControlSliderItem(
            kind: kind,
            title: kind.title,
            symbolName: symbolName(for: kind, value: 0),
            value: 0,
            percentText: "--",
            step: 0.01,
            isEnabled: false,
            unavailableReason: reason
        )
    }

    private static func mouseDisplayID() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
    }

    private static func percentText(kind: DisplayControlKind, value: Double) -> String {
        if kind == .mute {
            return value >= 0.5 ? "Muted" : "On"
        }
        return "\(Int((clamp(value) * 100).rounded()))%"
    }

    private static func symbolName(for kind: DisplayControlKind, value: Double) -> String {
        switch kind {
        case .brightness:
            return "sun.max.fill"
        case .contrast:
            return "circle.lefthalf.filled"
        case .volume:
            if value <= 0 {
                return "speaker.slash.fill"
            }
            return value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
        case .mute:
            return value >= 0.5 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private struct DisplayControlPendingKey: Hashable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}
