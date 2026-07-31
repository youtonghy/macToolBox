import CoreGraphics
import Foundation
import AppKit

struct ScrollTargetObservation: Equatable, Sendable {
    let isProcessRunning: Bool
    let ownerPID: pid_t
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
    let topologyGeneration: UInt64
    let windowGlobalFrame: CGRect
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
        return ScrollTargetObservation(
            isProcessRunning: true,
            ownerPID: target.ownerPID,
            windowID: target.windowID,
            displayID: displayID,
            topologyGeneration: target.topologyGeneration,
            windowGlobalFrame: appKitFrame
        )
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
        guard observation.displayID == target.displayID,
              observation.topologyGeneration == target.topologyGeneration
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
