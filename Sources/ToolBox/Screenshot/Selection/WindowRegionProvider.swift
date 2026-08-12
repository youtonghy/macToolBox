import AppKit

struct WindowRegionRecord: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let title: String?
    let bounds: CGRect
    /// `kCGWindowLayer`. Ordinary application windows are layer 0. Shell elements
    /// live above: Dock is 20, the menu bar strip 24, menu bar extras 25.
    let layer: Int

    init(
        ownerPID: pid_t,
        windowID: CGWindowID,
        title: String?,
        bounds: CGRect,
        layer: Int = 0
    ) {
        self.ownerPID = ownerPID
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.layer = layer
    }
}

enum WindowRegionError: Error, Equatable {
    case shareableContentUnavailable
}

/// Window layers that may be picked as a selection target.
///
/// The Dock publishes a window that spans the whole screen at layer 20. Because
/// hit testing walks CGWindowList front-to-back and returns the first window
/// containing the point, an unfiltered scan resolves EVERY point on screen to the
/// Dock. That poisons the entire pipeline: the bogus window becomes `targetWindow`,
/// so the accessibility query gets scoped to the Dock's process and can never find
/// the element under the cursor.
///
/// Ordinary application windows are layer 0. Genuine floating panels and dialogs
/// sit slightly above but stay well below the shell, so a small positive band is
/// accepted while Dock (20) and the menu bar (24/25) are excluded.
enum WindowRegionLayerPolicy {
    /// Highest layer still considered application content rather than system shell.
    static let maximumSelectableLayer = 3

    static func isSelectable(layer: Int) -> Bool {
        layer >= 0 && layer <= maximumSelectableLayer
    }
}

@MainActor
final class WindowRegionProvider {
    typealias WindowList = () -> [WindowRegionRecord]?

    private let ownPID: pid_t
    private let primaryScreenTop: () -> CGFloat
    private let windowList: WindowList

    init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        primaryScreenTop: @escaping () -> CGFloat = {
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
                ?? NSScreen.screens.first?.frame.maxY
                ?? 0
        },
        windowList: WindowList? = nil
    ) {
        self.ownPID = ownPID
        self.primaryScreenTop = primaryScreenTop
        self.windowList = windowList ?? WindowRegionProvider.systemWindowList
    }

    func region(at point: CGPoint, generation: UInt64) async throws -> SelectionCandidate? {
        guard let windows = windowList() else {
            throw WindowRegionError.shareableContentUnavailable
        }
        let screenTop = primaryScreenTop()
        for window in windows {
            guard window.ownerPID != ownPID,
                  WindowRegionLayerPolicy.isSelectable(layer: window.layer),
                  window.bounds.width > 0,
                  window.bounds.height > 0 else { continue }
            let rect = CGRect(
                x: window.bounds.minX,
                y: screenTop - window.bounds.maxY,
                width: window.bounds.width,
                height: window.bounds.height
            )
            guard rect.contains(point) else { continue }
            return SelectionCandidate(
                providerIdentity: "window",
                source: .window,
                ownerPID: window.ownerPID,
                windowID: window.windowID,
                displayID: displayID(containing: rect),
                topologyGeneration: generation,
                role: "AXWindow",
                title: window.title,
                hierarchyIndex: 0,
                globalRect: rect
            )
        }
        return nil
    }

    nonisolated private static func systemWindowList() -> [WindowRegionRecord]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        return windows.compactMap { window in
            guard let ownerPID = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  let windowID = (window[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            return WindowRegionRecord(
                ownerPID: ownerPID,
                windowID: windowID,
                title: window[kCGWindowName] as? String,
                bounds: bounds,
                layer: (window[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
