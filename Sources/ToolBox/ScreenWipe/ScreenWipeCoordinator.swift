import AppKit
import Carbon.HIToolbox

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

        // Rebuild overlays when displays are attached/detached.
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
        for w in blackWindows { w.orderOut(nil) }
        blackWindows.removeAll()
        countdownViews.removeAll()
        let cb = onDone; onDone = nil
        cb?()
    }

    private func createBlackWindows() {
        NSLog("[ToolBox] screen-wipe: \(NSScreen.screens.count) display(s)")
        // Activate so this accessory app can raise .screenSaver-level overlays on every display
        // (otherwise windows on secondary displays may fail to come forward).
        NSApp.activate()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false,
                             screen: screen)
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]
            w.ignoresMouseEvents = true
            w.isMovable = false
            w.hidesOnDeactivate = false
            w.animationBehavior = .none
            w.orderFrontRegardless()

            // Every display shows the countdown, so the number is visible on whichever
            // screen the user looks at. All views share one timer -> they tick in lockstep.
            let view = CountdownView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            w.contentView = view
            countdownViews.append(view)
            blackWindows.append(w)
        }
    }

    private func rebuildWindows() {
        for w in blackWindows { w.orderOut(nil) }
        blackWindows.removeAll()
        countdownViews.removeAll()
        createBlackWindows()
        countdownViews.forEach { $0.setNumber(remaining) }
    }
}
