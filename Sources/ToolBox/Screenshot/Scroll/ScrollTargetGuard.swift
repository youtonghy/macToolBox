import CoreGraphics
import Foundation

struct ScrollTargetObservation: Equatable, Sendable {
    let isProcessRunning: Bool
    let ownerPID: pid_t
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
    let topologyGeneration: UInt64
    let windowGlobalFrame: CGRect
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
