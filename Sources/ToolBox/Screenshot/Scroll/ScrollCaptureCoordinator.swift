import Foundation

enum ScrollCaptureMode: Equatable, Sendable {
    case automatic
    case manual
}

enum ScrollCaptureIssue: Equatable, Sendable {
    case lowConfidence
    case reverseMovement
}

enum ScrollCaptureCompletion: Equatable, Sendable {
    case bottomReached
    case resourceLimit
    case userFinished
}

enum ScrollCaptureState: Equatable, Sendable {
    case idle
    case acquiringTarget
    case capturingInitialFrame
    case scrolling
    case waitingForStability
    case matchingOverlap
    case appending
    case paused(ScrollCaptureIssue)
    case completed(ScrollCaptureCompletion)
    case cancelled
    case failed
}

struct ScrollCaptureResult {
    let source: ScrollCaptureImageSource
    let sessionDirectory: URL
    let completion: ScrollCaptureCompletion
}

@MainActor
final class ScrollCaptureCoordinator {
    private enum PauseAction { case retry, switchToManual, finish, cancel }

    private let frameProvider: ScrollCaptureFrameProviding
    private let automaticDriver: ScrollDriving
    private let manualDriver: ScrollDriving
    private let rootDirectory: URL
    private let match: (LumaFrame, LumaFrame) throws -> OverlapMatch
    private let validate: (ScrollCaptureTargetSnapshot) throws -> Void
    private var pauseContinuation: CheckedContinuation<PauseAction, Never>?

    var onStateChange: (ScrollCaptureState) -> Void = { _ in }
    private(set) var state: ScrollCaptureState = .idle {
        didSet { onStateChange(state) }
    }
    private(set) var mode: ScrollCaptureMode = .automatic
    private(set) var progressHeight = 0
    private var finishRequested = false

    init(
        frameProvider: ScrollCaptureFrameProviding,
        automaticDriver: ScrollDriving = AutomaticScrollDriver(),
        manualDriver: ScrollDriving = ManualScrollDriver(),
        rootDirectory: URL = ScrollCaptureStripStore.defaultRootDirectory(),
        match: @escaping (LumaFrame, LumaFrame) throws -> OverlapMatch = {
            try OverlapMatcher().match(previous: $0, current: $1)
        },
        validate: @escaping (ScrollCaptureTargetSnapshot) throws -> Void
    ) {
        self.frameProvider = frameProvider
        self.automaticDriver = automaticDriver
        self.manualDriver = manualDriver
        self.rootDirectory = rootDirectory
        self.match = match
        self.validate = validate
    }

    func capture(
        target: ScrollCaptureTargetSnapshot,
        initialMode: ScrollCaptureMode = .automatic
    ) async throws -> ScrollCaptureResult {
        guard state == .idle else { throw ScrollCaptureError.captureFailed }
        mode = initialMode
        finishRequested = false
        var sessionDirectory: URL?
        do {
            state = .acquiringTarget
            try validate(target)
            state = .capturingInitialFrame
            var previous = try await frameProvider.captureInitialFrame(target: target)
            let store = try ScrollCaptureStripStore(
                initialImage: previous.image,
                rootDirectory: rootDirectory
            )
            sessionDirectory = store.sessionDirectory
            progressHeight = store.logicalHeight
            var noMovementCount = 0

            while true {
                try Task.checkCancellation()
                if finishRequested {
                    return try finish(store: store, completion: .userFinished)
                }
                try validate(target)
                state = .scrolling
                let driver = mode == .automatic ? automaticDriver : manualDriver
                let driverResult = try await driver.scroll(target: target) { [validate] in
                    try validate(target)
                }
                if driverResult == .manualRequired {
                    mode = .manual
                    continue
                }

                state = .waitingForStability
                let current = try await frameProvider.captureStableFrame(target: target)
                guard current.image.width == previous.image.width,
                      current.image.height == previous.image.height else {
                    throw ScrollCaptureError.frameDimensionsChanged
                }
                try validate(target)
                state = .matchingOverlap
                let overlap = try match(previous.luma, current.luma)
                switch overlap.classification {
                case .forward:
                    guard overlap.newRowCount > 0 else { throw ScrollCaptureError.invalidStrip }
                    state = .appending
                    do {
                        try store.append(current.copyNewRows(previewRowCount: overlap.newRowCount))
                    } catch ScrollCaptureError.resourceLimitReached {
                        return try finish(store: store, completion: .resourceLimit)
                    }
                    previous = current
                    progressHeight = store.logicalHeight
                    noMovementCount = 0

                case .noMovement:
                    previous = current
                    if mode == .manual { continue }
                    noMovementCount += 1
                    if noMovementCount >= 3 {
                        return try finish(store: store, completion: .bottomReached)
                    }

                case .lowConfidence:
                    switch await pause(for: .lowConfidence) {
                    case .retry: continue
                    case .switchToManual: mode = .manual; continue
                    case .finish: return try finish(store: store, completion: .userFinished)
                    case .cancel: throw CancellationError()
                    }

                case .reverse:
                    switch await pause(for: .reverseMovement) {
                    case .retry: continue
                    case .switchToManual: mode = .manual; continue
                    case .finish: return try finish(store: store, completion: .userFinished)
                    case .cancel: throw CancellationError()
                    }
                }
            }
        } catch is CancellationError {
            if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
            state = .cancelled
            throw ScrollCaptureError.cancelled
        } catch {
            if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
            state = .failed
            throw error
        }
    }

    func retry() { resumePause(with: .retry) }
    func switchToManual() { resumePause(with: .switchToManual) }
    func finishPartial() {
        finishRequested = true
        resumePause(with: .finish)
    }
    func cancel() {
        if pauseContinuation != nil {
            resumePause(with: .cancel)
        } else if state != .idle {
            state = .cancelled
        }
    }

    private func pause(for issue: ScrollCaptureIssue) async -> PauseAction {
        state = .paused(issue)
        return await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    private func resumePause(with action: PauseAction) {
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume(returning: action)
    }

    private func finish(
        store: ScrollCaptureStripStore,
        completion: ScrollCaptureCompletion
    ) throws -> ScrollCaptureResult {
        let source = try store.makeImageSource()
        state = .completed(completion)
        return ScrollCaptureResult(
            source: source,
            sessionDirectory: store.sessionDirectory,
            completion: completion
        )
    }
}
