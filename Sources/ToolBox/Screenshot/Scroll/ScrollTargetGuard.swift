import CoreGraphics
import Foundation
import AppKit

struct ScrollTargetObservation: Equatable, Sendable {
    let isProcessRunning: Bool
    /// Whether the target's owning process is the frontmost application.
    /// Scroll events posted at the HID tap are delivered to the frontmost app,
    /// so a capture must abort once the user switches away — otherwise the
    /// wrong window scrolls while we keep stitching frames of the old ROI.
    let isFrontmost: Bool
    /// Whether the target window is still the topmost window of its own
    /// application at the scroll location. Switching to another window of the
    /// same app (Cmd+`) can redirect scroll events within one process.
    let isTargetTopmostAtScrollLocation: Bool
    let ownerPID: pid_t
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
    /// Live display-topology signature. Unlike a session generation counter,
    /// this changes when displays are added/removed, moved, or re-scaled.
    let topologySignature: UInt64
    let windowGlobalFrame: CGRect
}

/// One display's contribution to the topology signature.
struct DisplayTopologyEntry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScaleFactor: Double
}

/// FNV-1a hash over the sorted display topology. A pure function of the current
/// screen layout; two captures of the same layout hash identically, and any
/// display add/remove/move/rescale changes the result.
enum ScrollTopologySignature {
    static func make(_ entries: [DisplayTopologyEntry]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for entry in entries.sorted(by: { $0.displayID < $1.displayID }) {
            let values: [UInt64] = [
                UInt64(entry.displayID),
                Double(entry.frame.minX).bitPattern,
                Double(entry.frame.minY).bitPattern,
                Double(entry.frame.width).bitPattern,
                Double(entry.frame.height).bitPattern,
                entry.backingScaleFactor.bitPattern,
            ]
            for value in values {
                hash ^= value
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    /// Current system topology. Must be called on the main actor (NSScreen).
    @MainActor
    static func current() -> UInt64 {
        make(NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DisplayTopologyEntry(
                displayID: number.uint32Value,
                frame: screen.frame,
                backingScaleFactor: Double(screen.backingScaleFactor)
            )
        })
    }
}

@MainActor
struct SystemScrollTargetObserver {
    func observe(_ target: ScrollCaptureTargetSnapshot) throws -> ScrollTargetObservation {
        guard let application = NSRunningApplication(processIdentifier: target.ownerPID),
              !application.isTerminated,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == target.windowID
                      && ($0[kCGWindowOwnerPID] as? NSNumber)?.int32Value == target.ownerPID
              }),
              let bounds = window[kCGWindowBounds] as? [String: Any]
        else {
            throw ScrollCaptureTargetError.targetUnavailable
        }
        let boundsDictionary = bounds as CFDictionary
        var quartzFrame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &quartzFrame) else {
            throw ScrollCaptureTargetError.targetUnavailable
        }
        let screens = NSScreen.screens.compactMap { screen -> QuartzWindowCoordinateConverter.Screen? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return .init(displayID: number.uint32Value, appKitFrame: screen.frame)
        }
        let converter = QuartzWindowCoordinateConverter(
            primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
            screens: screens
        )
        let appKitFrame = converter.appKitFrame(fromQuartzFrame: quartzFrame)
        let displayID = converter.displayID(containing: appKitFrame)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.ownerPID
        let isTargetTopmost = Self.isTargetTopmost(
            windows: windows,
            targetWindowID: target.windowID,
            ownerPID: target.ownerPID,
            scrollLocation: target.scrollLocation,
            converter: converter
        )
        return ScrollTargetObservation(
            isProcessRunning: true,
            isFrontmost: isFrontmost,
            isTargetTopmostAtScrollLocation: isTargetTopmost,
            ownerPID: target.ownerPID,
            windowID: target.windowID,
            displayID: displayID,
            topologySignature: ScrollTopologySignature.current(),
            windowGlobalFrame: appKitFrame
        )
    }

    /// CGWindowList returns windows front-to-back. If another window of the
    /// SAME application sits above the target and covers the scroll location,
    /// posted scroll events would act on that window instead of the target.
    /// (Other apps' windows are covered by the frontmost-application check.)
    /// Pure over its inputs for unit testing.
    nonisolated static func isTargetTopmost(
        windows: [[CFString: Any]],
        targetWindowID: CGWindowID,
        ownerPID: pid_t,
        scrollLocation: CGPoint,
        converter: QuartzWindowCoordinateConverter
    ) -> Bool {
        var sawTarget = false
        for window in windows {
            let windowID = (window[kCGWindowNumber] as? NSNumber)?.uint32Value
            let windowOwnerPID = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value
            guard let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { continue }
            if windowID == targetWindowID, windowOwnerPID == ownerPID {
                sawTarget = true
                break
            }
            // A same-app window above the target that covers the scroll point
            // would steal the scroll events.
            if windowOwnerPID == ownerPID,
               converter.appKitFrame(fromQuartzFrame: bounds).contains(scrollLocation) {
                return false
            }
        }
        return sawTarget
    }
}

struct QuartzWindowCoordinateConverter: Sendable {
    struct Screen: Equatable, Sendable {
        let displayID: CGDirectDisplayID
        let appKitFrame: CGRect
    }

    let primaryDisplayHeight: CGFloat
    let screens: [Screen]

    func appKitFrame(fromQuartzFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryDisplayHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    func displayID(containing frame: CGRect) -> CGDirectDisplayID {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first(where: { $0.appKitFrame.contains(center) })?.displayID ?? 0
    }
}

struct ScrollTargetGuard {
    let geometryTolerance: CGFloat

    init(geometryTolerance: CGFloat = 0.5) {
        self.geometryTolerance = max(0, geometryTolerance)
    }

    func validate(
        _ target: ScrollCaptureTargetSnapshot,
        against observation: ScrollTargetObservation
    ) throws {
        guard observation.isProcessRunning else {
            throw ScrollCaptureTargetError.targetUnavailable
        }
        guard observation.ownerPID == target.ownerPID,
              observation.windowID == target.windowID
        else {
            throw ScrollCaptureTargetError.targetChanged
        }
        guard observation.isFrontmost else {
            // The target is no longer the frontmost app: posted scroll events
            // would act on a different window while we keep capturing the old ROI.
            throw ScrollCaptureTargetError.targetChanged
        }
        guard observation.isTargetTopmostAtScrollLocation else {
            // Another window of the same app now covers the scroll location:
            // scroll events would act on that sibling window instead.
            throw ScrollCaptureTargetError.targetChanged
        }
        guard observation.displayID == target.displayID,
              observation.topologySignature == target.topologySignature
        else {
            throw ScrollCaptureTargetError.displayChanged
        }
        guard observation.windowGlobalFrame.contains(target.roiGlobal) else {
            throw ScrollCaptureTargetError.roiOutsideWindow
        }
        guard approximatelyEqual(observation.windowGlobalFrame, target.windowGlobalFrame) else {
            throw ScrollCaptureTargetError.targetChanged
        }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= geometryTolerance
            && abs(lhs.minY - rhs.minY) <= geometryTolerance
            && abs(lhs.width - rhs.width) <= geometryTolerance
            && abs(lhs.height - rhs.height) <= geometryTolerance
    }
}
