import CoreGraphics
import Foundation

struct FocusModeConfiguration: Equatable {
    var isEnabled: Bool
    var overlayOpacity: Double
}

enum FocusPermissionState: Equatable {
    case granted
    case missing
}

struct FocusScreenGeometry: Identifiable, Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
}

struct FocusSystemSnapshot: Equatable {
    var frontmostApplicationPID: pid_t?
    var accessibilityTrusted: Bool
    /// Accessibility coordinates use the primary display's top-left as origin.
    var axFocusedWindowFrame: CGRect?
    /// AppKit global coordinates use the primary display's bottom-left as origin.
    var mouseLocation: CGPoint?
    var isSleeping: Bool

    init(
        frontmostApplicationPID: pid_t?,
        accessibilityTrusted: Bool,
        axFocusedWindowFrame: CGRect?,
        mouseLocation: CGPoint?,
        isSleeping: Bool = false
    ) {
        self.frontmostApplicationPID = frontmostApplicationPID
        self.accessibilityTrusted = accessibilityTrusted
        self.axFocusedWindowFrame = axFocusedWindowFrame
        self.mouseLocation = mouseLocation
        self.isSleeping = isSleeping
    }
}

enum FocusTargetResolver {
    static func appKitRect(fromAXRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func resolve(
        screens: [FocusScreenGeometry],
        snapshot: FocusSystemSnapshot,
        ownProcessID: pid_t,
        lastExternalDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        guard let primary = screens.first else { return nil }

        let availableIDs = Set(screens.map(\.id))
        if snapshot.frontmostApplicationPID == ownProcessID,
           let lastExternalDisplayID,
           availableIDs.contains(lastExternalDisplayID) {
            return lastExternalDisplayID
        }

        if snapshot.accessibilityTrusted,
           snapshot.frontmostApplicationPID != ownProcessID,
           let axFrame = snapshot.axFocusedWindowFrame,
           isValid(rect: axFrame) {
            let appKitFrame = appKitRect(
                fromAXRect: axFrame,
                primaryScreenHeight: primary.frame.height
            )
            if let matched = displayContainingMost(
                of: appKitFrame,
                screens: screens,
                lastExternalDisplayID: lastExternalDisplayID
            ) {
                return matched
            }
        }

        if let mouseLocation = snapshot.mouseLocation,
           isFinite(point: mouseLocation),
           let mouseScreen = screens.first(where: { contains($0.frame, point: mouseLocation) }) {
            return mouseScreen.id
        }

        if let lastExternalDisplayID, availableIDs.contains(lastExternalDisplayID) {
            return lastExternalDisplayID
        }

        return primary.id
    }

    private static func displayContainingMost(
        of windowFrame: CGRect,
        screens: [FocusScreenGeometry],
        lastExternalDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        let intersections = screens.compactMap { screen -> (screen: FocusScreenGeometry, area: CGFloat)? in
            let intersection = screen.frame.intersection(windowFrame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (screen, intersection.width * intersection.height)
        }
        guard let maximumArea = intersections.map(\.area).max(), maximumArea > 0 else {
            return nil
        }

        let candidates = intersections
            .filter { $0.area == maximumArea }
            .map(\.screen)
        if candidates.count == 1 {
            return candidates[0].id
        }

        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let centerScreen = candidates.first(where: { contains($0.frame, point: center) }) {
            return centerScreen.id
        }
        if let lastExternalDisplayID,
           candidates.contains(where: { $0.id == lastExternalDisplayID }) {
            return lastExternalDisplayID
        }
        return candidates.map(\.id).min()
    }

    private static func contains(_ rect: CGRect, point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX
            && point.y >= rect.minY && point.y < rect.maxY
    }

    private static func isValid(rect: CGRect) -> Bool {
        rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }

    private static func isFinite(point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
