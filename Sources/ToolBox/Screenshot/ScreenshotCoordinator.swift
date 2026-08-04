import CoreGraphics

@MainActor
final class ScreenshotCoordinator {
    private let permission: ScreenCapturePermissionProviding
    private let captureProvider: ScreenCaptureProviding
    private let overlay: ScreenshotSelectionOverlayManaging
    private let compose: (CGRect, [DisplayCaptureFrame]) throws -> CGImage
    private let editorHandoff: (CGImage) -> Void
    private let documentHandoff: (ScreenshotDocument, @escaping () -> Void) -> Void
    private let bringEditorForward: () -> Void
    private let candidateResolver: ScreenshotCandidateResolver?
    private let windowCandidateResolver: ScreenshotWindowCandidateResolver?
    private let targetActivator: ScrollTargetActivating
    private let scrollControls: ScrollCaptureControlController
    private var frames: [DisplayCaptureFrame] = []
    private var selectionState = SelectionSessionState.empty
    private var hoveredCandidates: [SelectionCandidate] = []
    private var hoveredCandidateIndex = 0
    private var generation: UInt64 = 0
    private var hoverTask: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?
    private var scrollCoordinator: ScrollCaptureCoordinator?
    private var targetRestoration: ScrollTargetRestoration?

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
        windowCandidateResolver: ScreenshotWindowCandidateResolver? = nil,
        targetActivator: ScrollTargetActivating? = nil,
        scrollControls: ScrollCaptureControlController? = nil,
        bringEditorForward: @escaping () -> Void = {},
        editorHandoff: @escaping (CGImage) -> Void = { _ in },
        documentHandoff: @escaping (ScreenshotDocument, @escaping () -> Void) -> Void = { _, _ in }
    ) {
        self.permission = permission
        self.captureProvider = captureProvider
        self.overlay = overlay
        self.compose = compose
        self.candidateResolver = candidateResolver
        self.windowCandidateResolver = windowCandidateResolver
        self.targetActivator = targetActivator ?? WorkspaceScrollTargetActivation()
        self.scrollControls = scrollControls ?? ScrollCaptureControlController()
        self.bringEditorForward = bringEditorForward
        self.editorHandoff = editorHandoff
        self.documentHandoff = documentHandoff
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
        scrollTask?.cancel()
        scrollTask = nil
        scrollCoordinator?.cancel()
        scrollCoordinator = nil
        scrollControls.close()
        targetRestoration?.restore()
        targetRestoration = nil
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
            hoveredCandidates = []
            hoveredCandidateIndex = 0
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
        scrollCoordinator?.cancel()
        scrollTask?.cancel()
        scrollTask = nil
        scrollCoordinator = nil
        scrollControls.close()
        targetRestoration?.restore()
        targetRestoration = nil
        frames.removeAll()
        selectionState = .empty
        hoveredCandidates = []
        hoveredCandidateIndex = 0
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
        if case let .cycleCandidate(offset) = action {
            cycleCandidate(by: offset)
            return
        }
        do {
            try SelectionReducer.reduce(state: &selectionState, action: action)
            if let completionMode = completionMode(after: action) {
                if completionMode == .staticCapture {
                    scheduleStaticSelectionCompletion()
                    return
                }
                let snapshot = selectionState
                let sessionGeneration = generation
                scrollTask = Task { [weak self] in
                    await self?.beginLongCapture(selection: snapshot, generation: sessionGeneration)
                }
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

    private func scheduleStaticSelectionCompletion() {
        let sessionGeneration = generation
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.generation == sessionGeneration,
                  self.state == .selecting
            else { return }
            do {
                try self.confirmSelection()
            } catch let error as SelectionError {
                self.lastError = .selection(error)
            } catch let error as ScreenshotCaptureError {
                self.frames.removeAll()
                self.overlay.close(cancelled: false)
                self.state = .idle
                self.lastError = .composition(error)
            } catch {
                self.frames.removeAll()
                self.overlay.close(cancelled: false)
                self.state = .idle
                self.lastError = .overlay
            }
        }
    }

    private func completionMode(after action: SelectionAction) -> SelectionCaptureMode? {
        switch action {
        case .click(_, additive: false), .manualDrag, .confirm:
            return selectionState.captureMode
        case .click(_, additive: true), .cycleCandidate, .setCaptureMode, .deleteLast, .undo, .adjustRegion:
            return nil
        }
    }

    private func beginLongCapture(
        selection: SelectionSessionState,
        generation sessionGeneration: UInt64
    ) async {
        guard state == .selecting,
              generation == sessionGeneration,
              let bounds = selection.captureBounds
        else { return }
        do {
            let containingWindow = await windowCandidateResolver?(bounds.center, sessionGeneration)
            guard generation == sessionGeneration, state == .selecting else { return }
            let target = try ScrollCaptureTargetSnapshot.make(
                selection: selection,
                containingWindow: containingWindow
            )
            frames.removeAll()
            hoverTask?.cancel()
            hoverTask = nil
            overlay.close(cancelled: false)
            state = .longCapturing

            let restoration = try targetActivator.activate(target)
            targetRestoration = restoration
            let observer = SystemScrollTargetObserver()
            let guarder = ScrollTargetGuard()
            let defaults = UserDefaults.standard
            let automatic = defaults.object(forKey: "screenshot.scrollCapture.automatic") as? Bool ?? true
            let configuredStep = defaults.object(forKey: "screenshot.scrollCapture.stepPixels") as? Double ?? 160
            let safeConfiguredStep = configuredStep.isFinite ? configuredStep : 160
            let step = Int32(max(40, min(400, safeConfiguredStep)))
            let matchingConfiguration = ScrollMatchingConfiguration.automaticScroll(
                stepPixels: step,
                roiWidth: target.roiGlobal.width
            )
            let child = ScrollCaptureCoordinator(
                frameProvider: DefaultScrollCaptureFrameProvider(captureProvider: captureProvider),
                automaticDriver: AutomaticScrollDriver(stepPixels: step),
                matchingConfiguration: matchingConfiguration,
                validate: { snapshot in
                    try guarder.validate(snapshot, against: try observer.observe(snapshot))
                }
            )
            scrollCoordinator = child
            scrollControls.onRetry = { [weak child] in child?.retry() }
            scrollControls.onManual = { [weak child] in child?.switchToManual() }
            scrollControls.onFinish = { [weak child] in child?.finishPartial() }
            scrollControls.onCancel = { [weak self] in self?.cancel() }
            child.onStateChange = { [weak self, weak child] childState in
                guard let self, let child else { return }
                self.scrollControls.update(
                    state: childState,
                    mode: child.mode,
                    height: child.progressHeight
                )
            }
            scrollControls.show()
            let result = try await child.capture(
                target: target,
                initialMode: automatic ? .automatic : .manual
            )
            guard generation == sessionGeneration, state == .longCapturing else {
                try? FileManager.default.removeItem(at: result.sessionDirectory)
                restoration.restore()
                return
            }
            scrollControls.close()
            scrollCoordinator = nil
            scrollTask = nil
            targetRestoration = nil
            restoration.restore()
            state = .previewing
            let directory = result.sessionDirectory
            documentHandoff(
                ScreenshotDocument(baseImage: result.source),
                { try? FileManager.default.removeItem(at: directory) }
            )
        } catch is CancellationError {
            finishLongCaptureFailure(generation: sessionGeneration, reportError: false)
        } catch ScrollCaptureError.cancelled {
            finishLongCaptureFailure(generation: sessionGeneration, reportError: false)
        } catch {
            finishLongCaptureFailure(generation: sessionGeneration, reportError: true)
        }
    }

    private func finishLongCaptureFailure(generation sessionGeneration: UInt64, reportError: Bool) {
        guard generation == sessionGeneration else { return }
        scrollControls.close()
        scrollCoordinator = nil
        scrollTask = nil
        targetRestoration?.restore()
        targetRestoration = nil
        state = .idle
        if reportError { lastError = .longCaptureFailed }
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
            var candidates = await self.candidateResolver?(point, sessionGeneration) ?? []
            if candidates.isEmpty,
               let display = self.displayCandidate(at: point, generation: sessionGeneration) {
                candidates = [display]
            }
            guard !Task.isCancelled,
                  self.generation == sessionGeneration,
                  self.state == .selecting else { return }
            self.hoveredCandidates = candidates
            self.hoveredCandidateIndex = 0
            self.selectionState.hoveredCandidate = candidates.first
            self.overlay.update(state: self.selectionState)
        }
    }

    private func cycleCandidate(by offset: Int) {
        guard !hoveredCandidates.isEmpty, offset != 0 else { return }
        let count = hoveredCandidates.count
        hoveredCandidateIndex = ((hoveredCandidateIndex + offset) % count + count) % count
        selectionState.hoveredCandidate = hoveredCandidates[hoveredCandidateIndex]
        overlay.update(state: selectionState)
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
