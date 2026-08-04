import AppKit

struct WindowRegionRecord: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let title: String?
    let bounds: CGRect
}

enum WindowRegionError: Error, Equatable {
    case shareableContentUnavailable
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
                bounds: bounds
            )
        }
    }

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
