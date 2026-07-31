import CoreGraphics
import Foundation

enum ScrollDriverResult: Equatable, Sendable {
    case movementRequested
    case manualRequired
    case waitingForManualMovement
}

protocol ScrollDriving: AnyObject {
    func scroll(
        target: ScrollCaptureTargetSnapshot,
        validate: () throws -> Void
    ) async throws -> ScrollDriverResult
}

final class AutomaticScrollDriver: ScrollDriving {
    private let access: ScrollEventAccessProviding
    private let poster: ScrollEventPosting
    private let stepPixels: Int32
    private let cadence: Duration

    init(
        access: ScrollEventAccessProviding = CoreGraphicsScrollEventAccess(),
        poster: ScrollEventPosting = CoreGraphicsScrollEventPoster(),
        stepPixels: Int32 = 160,
        cadence: Duration = .milliseconds(180)
    ) {
        self.access = access
        self.poster = poster
        self.stepPixels = max(1, abs(stepPixels))
        self.cadence = cadence
    }

    func scroll(
        target: ScrollCaptureTargetSnapshot,
        validate: () throws -> Void
    ) async throws -> ScrollDriverResult {
        try Task.checkCancellation()
        guard access.preflight() else { return .manualRequired }
        try validate()
        try poster.postPixelScroll(at: target.scrollLocation, deltaY: -stepPixels)
        if cadence > .zero {
            try await Task.sleep(for: cadence)
        }
        try Task.checkCancellation()
        return .movementRequested
    }
}

final class ManualScrollDriver: ScrollDriving {
    func scroll(
        target: ScrollCaptureTargetSnapshot,
        validate: () throws -> Void
    ) async throws -> ScrollDriverResult {
        try Task.checkCancellation()
        try validate()
        return .waitingForManualMovement
    }
}
