import CoreGraphics

@MainActor
final class ScreenshotCoordinator {
    private let permission: ScreenCapturePermissionProviding
    private let captureProvider: ScreenCaptureProviding
    private let overlay: ScreenshotSelectionOverlayManaging
    private let compose: (CGRect, [DisplayCaptureFrame]) throws -> CGImage
    private let editorHandoff: (CGImage) -> Void
    private let bringEditorForward: () -> Void
    private let candidateResolver: ScreenshotCandidateResolver?
    private var frames: [DisplayCaptureFrame] = []
    private var selectionState = SelectionSessionState.empty
    private var generation: UInt64 = 0
    private var hoverTask: Task<Void, Never>?

    private(set) var state: ScreenshotWorkflowState = .idle
    private(set) var lastError: ScreenshotCoordinatorError?
    var frozenFrameCount: Int { frames.count }

    init(
        permission: ScreenCapturePermissionProviding,
        captureProvider: ScreenCaptureProviding,
        overlay: ScreenshotSelectionOverlayManaging,
        compose: @escaping (CGRect, [DisplayCaptureFrame]) throws -> CGImage = {
            try ScreenshotImageComposer.compose(selection: $0, frames: $1)
        },
        candidateResolver: ScreenshotCandidateResolver? = nil,
        bringEditorForward: @escaping () -> Void = {},
        editorHandoff: @escaping (CGImage) -> Void = { _ in }
    ) {
        self.permission = permission
        self.captureProvider = captureProvider
        self.overlay = overlay
        self.compose = compose
        self.candidateResolver = candidateResolver
        self.bringEditorForward = bringEditorForward
        self.editorHandoff = editorHandoff
    }

    convenience init() {
        self.init(
            permission: ScreenCapturePermission(),
            captureProvider: ScreenCaptureProvider(),
            overlay: ScreenshotSelectionOverlayManager()
        )
    }

    func startRegionCapture() async {
        guard state == .idle else {
            if let displayID = frames.first?.geometry.displayID {
                overlay.beginInteraction(on: displayID)
            } else if state == .previewing {
                bringEditorForward()
            }
            return
        }

        lastError = nil
        generation &+= 1
        let sessionGeneration = generation
        state = .preparing

        if permission.state == .denied, !permission.requestAccess() {
            fail(.permissionDenied)
            return
        }

        do {
            let captured = try await captureProvider.captureDisplays()
            guard generation == sessionGeneration, state == .preparing else { return }
            frames = captured
            selectionState = .empty
            state = .selecting
            try overlay.show(
                frames: captured,
                state: selectionState,
                onAction: { [weak self] action in self?.handle(action) },
                onHover: { [weak self] point in self?.resolveCandidate(at: point) },
                onCancel: { [weak self] in self?.cancel() }
            )
        } catch let error as ScreenshotCaptureError {
            fail(.capture(error))
        } catch {
            fail(.overlay)
        }
    }

    func cancel() {
        guard state != .idle else { return }
        generation &+= 1
        hoverTask?.cancel()
        hoverTask = nil
        frames.removeAll()
        selectionState = .empty
        if state == .selecting {
            overlay.close(cancelled: true)
        }
        state = .idle
    }

    func previewClosed() {
        guard state == .previewing else { return }
        state = .idle
    }

    private func handle(_ action: SelectionAction) {
        guard state == .selecting else { return }
        do {
            try SelectionReducer.reduce(state: &selectionState, action: action)
            if action == .confirm {
                try confirmSelection()
            } else {
                overlay.update(state: selectionState)
            }
        } catch let error as SelectionError {
            lastError = .selection(error)
        } catch let error as ScreenshotCaptureError {
            frames.removeAll()
            overlay.close(cancelled: false)
            state = .idle
            lastError = .composition(error)
        } catch {
            frames.removeAll()
            overlay.close(cancelled: false)
            state = .idle
            lastError = .overlay
        }
    }

    private func confirmSelection() throws {
        guard let bounds = selectionState.captureBounds else {
            throw SelectionError.emptySelection
        }
        let image = try compose(bounds, frames)
        frames.removeAll()
        hoverTask?.cancel()
        hoverTask = nil
        overlay.close(cancelled: false)
        state = .previewing
        editorHandoff(image)
    }

    private func resolveCandidate(at point: CGPoint) {
        guard state == .selecting else { return }
        let sessionGeneration = generation
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            guard let self else { return }
            var candidate = await self.candidateResolver?(point, sessionGeneration)
            if candidate == nil {
                candidate = self.displayCandidate(at: point, generation: sessionGeneration)
            }
            guard !Task.isCancelled,
                  self.generation == sessionGeneration,
                  self.state == .selecting else { return }
            self.selectionState.hoveredCandidate = candidate
            self.overlay.update(state: self.selectionState)
        }
    }

    private func displayCandidate(at point: CGPoint, generation: UInt64) -> SelectionCandidate? {
        guard let frame = frames.first(where: { $0.geometry.globalFramePoints.contains(point) }) else {
            return nil
        }
        return SelectionCandidate(
            providerIdentity: "display",
            source: .display,
            ownerPID: nil,
            windowID: nil,
            displayID: frame.geometry.displayID,
            topologyGeneration: generation,
            role: nil,
            title: nil,
            hierarchyIndex: 0,
            globalRect: frame.geometry.globalFramePoints
        )
    }

    private func fail(_ error: ScreenshotCoordinatorError) {
        frames.removeAll()
        selectionState = .empty
        state = .idle
        lastError = error
    }
}
