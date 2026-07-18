import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// F1 — 擦屏幕: turns every display fully black for 60s with a centered countdown.
/// Exit by pressing ⌃⌥⌘ + Esc (a Carbon global hotkey — needs NO TCC permission, so the exit
/// always works even before Input Monitoring is granted). Auto-dismisses at 0.
final class ScreenWipeCoordinator {

    private let totalSeconds = 60

    /// Exit combo: ⌃⌥⌘ + Esc, registered as a Carbon global hotkey (no TCC permission needed).
    private let exitKeyCode = UInt32(kVK_Escape)
    private let exitMods: HotKeyController.Modifiers = [.control, .option, .command]

    private var blackWindows: [NSWindow] = []
    private var countdownViews: [CountdownView] = []
    private var timer: Timer?
    private var remaining = 0
    private var onDone: (() -> Void)?

    private let hotKey = HotKeyController()
    private var screenObserver: NSObjectProtocol?
    /// Accessory apps often fail to raise secondary-display overlays; bump to `.regular` while active.
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    func start(onDone: @escaping () -> Void) {
        guard blackWindows.isEmpty else { return } // already running
        self.onDone = onDone
        remaining = totalSeconds

        createBlackWindows()

        // Exit detection via a Carbon global hotkey (no TCC permission needed -> always works).
        hotKey.install()
        hotKey.onTrigger = { [weak self] in self?.finish() }
        hotKey.register(keyCode: exitKeyCode, modifiers: exitMods)
        NSLog("[ToolBox] screen-wipe exit hotkey registered (⌃⌥⌘+Esc, no permission needed)")

        // Rebuild overlays when displays are attached/detached / rearranged.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildWindows() }

        countdownViews.forEach { $0.setNumber(remaining) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.remaining -= 1
            self.countdownViews.forEach { $0.setNumber(self.remaining) }
            if self.remaining <= 0 { self.finish() }
        }
    }

    /// Idempotent teardown.
    func stop() { finish() }

    private func finish() {
        timer?.invalidate(); timer = nil
        hotKey.unregister()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        for w in blackWindows {
            w.orderOut(nil)
            w.close()
        }
        blackWindows.removeAll()
        countdownViews.removeAll()
        restoreActivationPolicy()
        let cb = onDone; onDone = nil
        cb?()
    }

    private func createBlackWindows() {
        let screens = NSScreen.screens
        NSLog("[ToolBox] screen-wipe: \(screens.count) display(s), separateSpaces=\(NSScreen.screensHaveSeparateSpaces)")

        // Menu-bar accessory apps can fail to bring secondary-display windows forward.
        // Temporarily become a regular app and force activation so every screen overlay shows.
        promoteForOverlay()

        for (index, screen) in screens.enumerated() {
            NSLog(
                "[ToolBox] screen-wipe display[\(index)]: name=\(screen.localizedName), frame=\(NSStringFromRect(screen.frame)), visibleFrame=\(NSStringFromRect(screen.visibleFrame)), scale=\(screen.backingScaleFactor)"
            )

            // Create with a local-to-screen content rect, then pin the frame to the
            // absolute screen frame. Passing `screen.frame` (global origin) together with
            // `screen:` can double-offset secondary displays so the window never appears.
            let localRect = NSRect(origin: .zero, size: screen.frame.size)
            let w = NSWindow(
                contentRect: localRect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            // Above screensaver / full-screen chrome so every panel is actually covered.
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle,
            ]
            w.ignoresMouseEvents = false
            w.isMovable = false
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.animationBehavior = .none
            // Avoid title-bar / traffic-light reserved areas on some macOS versions.
            w.styleMask = .borderless
            w.sharingType = .none

            // Force absolute placement onto this display (covers menu bar + dock).
            w.setFrame(screen.frame, display: true)

            // Every display shows the countdown so the number is visible on whichever
            // screen the user looks at. All views share one timer -> they tick in lockstep.
            let view = CountdownView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.setNumber(remaining)
            w.contentView = view
            // Ensure the content view fills the window after setFrame.
            view.frame = w.contentView?.bounds ?? localRect

            countdownViews.append(view)
            blackWindows.append(w)

            NSLog(
                "[ToolBox] screen-wipe window[\(index)]: frame=\(NSStringFromRect(w.frame)), screen=\(w.screen?.localizedName ?? "nil"), level=\(w.level.rawValue), collectionBehavior=\(w.collectionBehavior.rawValue)"
            )
            w.orderFrontRegardless()
        }

        // Re-assert after all windows exist (helps multi-display with separate Spaces).
        for w in blackWindows {
            w.orderFrontRegardless()
        }
    }

    private func rebuildWindows() {
        for w in blackWindows {
            w.orderOut(nil)
            w.close()
        }
        blackWindows.removeAll()
        countdownViews.removeAll()
        createBlackWindows()
        countdownViews.forEach { $0.setNumber(remaining) }
    }

    private func promoteForOverlay() {
        if previousActivationPolicy == nil {
            previousActivationPolicy = NSApp.activationPolicy()
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreActivationPolicy() {
        guard let previous = previousActivationPolicy else { return }
        previousActivationPolicy = nil
        if NSApp.activationPolicy() != previous {
            NSApp.setActivationPolicy(previous)
        }
    }
}
