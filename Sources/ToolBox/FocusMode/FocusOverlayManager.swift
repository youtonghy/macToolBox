import AppKit
import CoreGraphics

@MainActor
final class FocusOverlayManager: FocusOverlayManaging {
    var dimmedDisplayIDs: Set<CGDirectDisplayID> {
        Set(records.compactMap { id, record in record.isDesired ? id : nil })
    }

    private let animationDuration: TimeInterval
    private var generation = 0
    private var records: [CGDirectDisplayID: WindowRecord] = [:]

    init(animationDuration: TimeInterval = 0.18) {
        self.animationDuration = max(animationDuration, 0)
    }

    func apply(
        screens: [FocusScreenGeometry],
        focusedDisplayID: CGDirectDisplayID?,
        opacity: Double
    ) {
        guard let focusedDisplayID else {
            clear()
            return
        }
        generation &+= 1
        let desiredScreens = screens.filter { $0.id != focusedDisplayID }
        let desiredIDs = Set(desiredScreens.map(\.id))
        let normalizedOpacity = FocusModeStore.normalizedOpacity(opacity)

        for screen in desiredScreens {
            let record = records[screen.id] ?? makeRecord(for: screen)
            records[screen.id] = record
            record.generation = generation
            record.isDesired = true
            record.window.setFrame(screen.frame, display: true)
            record.window.orderFrontRegardless()
            animate(record.window, alphaValue: normalizedOpacity)
        }

        for (displayID, record) in records where !desiredIDs.contains(displayID) {
            retire(record, displayID: displayID)
        }
    }

    func clear() {
        generation &+= 1
        for (displayID, record) in records {
            retire(record, displayID: displayID)
        }
    }

    private func makeRecord(for screen: FocusScreenGeometry) -> WindowRecord {
        let window = FocusOverlayWindow(frame: screen.frame)
        window.alphaValue = 0
        return WindowRecord(window: window, generation: generation)
    }

    private func retire(_ record: WindowRecord, displayID: CGDirectDisplayID) {
        guard record.isDesired || record.window.alphaValue > 0 else { return }
        record.generation = generation
        record.isDesired = false
        let retirementGeneration = generation

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            record.window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak record] in
            MainActor.assumeIsolated {
                guard let self, let record,
                      !record.isDesired,
                      record.generation == retirementGeneration else { return }
                record.window.orderOut(nil)
                record.window.close()
                if self.records[displayID] === record {
                    self.records.removeValue(forKey: displayID)
                }
            }
        }
    }

    private func animate(_ window: NSWindow, alphaValue: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            window.animator().alphaValue = alphaValue
        }
    }
}

@MainActor
private final class WindowRecord {
    let window: FocusOverlayWindow
    var generation: Int
    var isDesired = true

    init(window: FocusOverlayWindow, generation: Int) {
        self.window = window
        self.generation = generation
    }
}

private final class FocusOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }
}
