import CoreGraphics
import Foundation

enum ScrollCaptureTargetError: Error, Equatable {
    case ineligibleSelection
    case containingWindowUnavailable
    case targetUnavailable
    case targetChanged
    case displayChanged
    case roiOutsideWindow
    case activationFailed
}

struct ScrollCaptureTargetSnapshot: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
    let topologyGeneration: UInt64
    let roiGlobal: CGRect
    let windowGlobalFrame: CGRect

    var scrollLocation: CGPoint {
        CGPoint(x: roiGlobal.midX, y: roiGlobal.midY)
    }

    static func make(
        selection: SelectionSessionState,
        containingWindow: SelectionCandidate?
    ) throws -> Self {
        guard let roi = selection.captureBounds,
              roi.isFinite,
              roi.width > 0,
              roi.height > 0,
              let window = containingWindow,
              window.source == .window,
              let ownerPID = window.ownerPID,
              let windowID = window.windowID
        else {
            throw selection.manualRegion == nil
                ? ScrollCaptureTargetError.ineligibleSelection
                : ScrollCaptureTargetError.containingWindowUnavailable
        }
        guard window.globalRect.contains(roi) else {
            throw ScrollCaptureTargetError.roiOutsideWindow
        }

        if !selection.selectedRegions.isEmpty {
            let matchesWindow = selection.selectedRegions.allSatisfy {
                $0.ownerPID == ownerPID
                    && $0.windowID == windowID
                    && $0.displayID == window.displayID
                    && $0.topologyGeneration == window.topologyGeneration
            }
            guard matchesWindow else { throw ScrollCaptureTargetError.ineligibleSelection }
        }

        return Self(
            ownerPID: ownerPID,
            windowID: windowID,
            displayID: window.displayID,
            topologyGeneration: window.topologyGeneration,
            roiGlobal: roi,
            windowGlobalFrame: window.globalRect
        )
    }
}

private extension CGRect {
    var isFinite: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
    }
}
