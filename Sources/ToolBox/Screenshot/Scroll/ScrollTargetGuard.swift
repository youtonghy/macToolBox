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
        let screenTop = NSScreen.main?.frame.maxY ?? 0
        let appKitFrame = CGRect(
            x: quartzFrame.minX,
            y: screenTop - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: appKitFrame.midX, y: appKitFrame.midY))
        })
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
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
