import AppKit

@MainActor
protocol ScrollTargetActivating: AnyObject {
    func activate(_ target: ScrollCaptureTargetSnapshot) throws -> ScrollTargetRestoration
}

@MainActor
final class ScrollTargetRestoration {
    private var restoreAction: (() -> Void)?

    init(_ restoreAction: @escaping () -> Void) {
        self.restoreAction = restoreAction
    }

    func restore() {
        let action = restoreAction
        restoreAction = nil
        action?()
    }
}

@MainActor
final class WorkspaceScrollTargetActivation: ScrollTargetActivating {
    func activate(_ target: ScrollCaptureTargetSnapshot) throws -> ScrollTargetRestoration {
        let previous = NSWorkspace.shared.frontmostApplication
        guard let application = NSRunningApplication(processIdentifier: target.ownerPID),
              !application.isTerminated,
              application.activate()
        else {
            throw ScrollCaptureTargetError.activationFailed
        }
        return ScrollTargetRestoration {
            guard let previous, !previous.isTerminated else { return }
            previous.activate()
        }
    }
}
