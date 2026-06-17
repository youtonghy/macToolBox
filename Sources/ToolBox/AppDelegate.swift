import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = FeatureState()
    private var cancellables = Set<AnyCancellable>()

    // Feature coordinators.
    let screenWipe = ScreenWipeCoordinator()
    let awake = AwakeCoordinator()
    let keyboardPark = KeyboardParkCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist LSUIElement.
        NSApp.setActivationPolicy(.accessory)

        // Menu-bar status item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "ToolBox")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // Popup (NSPopover) with SwiftUI content.
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 250, height: 210)
        popover.contentViewController = NSHostingController(rootView: PopoverContent(state: state))

        // Wire toggles -> coordinators.
        state.$wipeOn
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyWipe(on) }
            .store(in: &cancellables)
        state.$awakeOn
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyAwake(on) }
            .store(in: &cancellables)
        state.$parkOn
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyPark(on) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenWipe.stop()
        awake.stop()
        keyboardPark.unpark()
    }

    // MARK: - Status item / popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate()
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Feature wiring

    private func applyWipe(_ on: Bool) {
        if on {
            screenWipe.start { [weak self] in
                // Auto-dismissed (timeout or long-press) -> reflect in UI.
                DispatchQueue.main.async { self?.state.wipeOn = false }
            }
        } else {
            screenWipe.stop()
        }
    }

    private func applyAwake(_ on: Bool) {
        if on { awake.start() } else { awake.stop() }
    }

    private func applyPark(_ on: Bool) {
        if on {
            let result = keyboardPark.park { [weak self] in
                DispatchQueue.main.async { self?.state.parkOn = false }
            }
            if case .failure(let reason) = result {
                // Refused -> reset toggle and tell the user why (don't fail silently).
                state.parkOn = false
                presentParkError(reason)
            }
        } else {
            keyboardPark.unpark()
        }
    }

    private func presentParkError(_ reason: KeyboardParkCoordinator.ParkError) {
        switch reason {
        case .inputMonitoringDenied:
            AppAlert.show(
                title: "无法锁定键盘",
                message: "需要「输入监控」权限才能禁用内置键盘。请在 系统设置 → 隐私与安全性 → 输入监控 中授权 ToolBox，然后重新打开开关。",
                primaryButton: ("打开系统设置", { Permissions.openInputMonitoringSettings() })
            )
        case .noExternalKeyboard:
            AppAlert.show(
                title: "无法锁定键盘",
                message: "未检测到外接键盘。为避免锁定后无法解锁，请先连接一个外接键盘（解锁组合键 ⌃⌥⌘+K 需在外接键盘上按下）。"
            )
        case .seizeFailed:
            AppAlert.show(
                title: "无法锁定键盘",
                message: "独占内置键盘失败（返回码已记录到控制台）。可能是其它进程占用或该机型不兼容。"
            )
        }
    }
}
