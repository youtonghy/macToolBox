import AppKit
import ScreenCaptureKit

enum WindowRegionError: Error, Equatable {
    case shareableContentUnavailable
}

@MainActor
final class WindowRegionProvider {
    private let ownPID: pid_t

    init(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
    }

    func region(at point: CGPoint, generation: UInt64) async throws -> SelectionCandidate? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WindowRegionError.shareableContentUnavailable
        }
        let screenTop = NSScreen.main?.frame.maxY ?? 0
        for window in content.windows {
            guard window.isOnScreen,
                  let application = window.owningApplication,
                  application.processID != ownPID,
                  window.frame.width > 0,
                  window.frame.height > 0 else { continue }
            let rect = CGRect(
                x: window.frame.minX,
                y: screenTop - window.frame.maxY,
                width: window.frame.width,
                height: window.frame.height
            )
            guard rect.contains(point) else { continue }
            return SelectionCandidate(
                providerIdentity: "window",
                source: .window,
                ownerPID: application.processID,
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

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
