import CoreGraphics

enum ScreenshotWorkflowState: Equatable {
    case idle
    case preparing
    case selecting
    case previewing
}

enum ScreenshotCoordinatorError: Error, Equatable {
    case permissionDenied
    case capture(ScreenshotCaptureError)
    case overlay
    case selection(SelectionError)
    case composition(ScreenshotCaptureError)
}

typealias ScreenshotCandidateResolver = @MainActor (CGPoint, UInt64) async -> SelectionCandidate?
