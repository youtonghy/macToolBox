import CoreGraphics
import XCTest
@testable import ToolBox

@MainActor
final class ScreenshotSelectionOverlayTests: XCTestCase {
    func testFrozenImageKeepsTopToBottomOrientation() throws {
        let view = selectionView(image: try verticallySplitImage(width: 100, height: 100))

        let rendered = try render(view)

        let top = try pixel(in: rendered, xFraction: 0.98, yFractionFromTop: 0.25)
        let bottom = try pixel(in: rendered, xFraction: 0.98, yFractionFromTop: 0.75)
        XCTAssertGreaterThan(top[0], 220)
        XCTAssertLessThan(top[2], 40)
        XCTAssertLessThan(bottom[0], 40)
        XCTAssertGreaterThan(bottom[2], 220)
    }

    func testFrozenImageIsNotDimmedBeforeSelection() throws {
        let view = selectionView(image: try solidImage(width: 100, height: 100, green: 255))

        let rendered = try render(view)

        let pixel = try pixel(in: rendered, xFraction: 0.98, yFractionFromTop: 0.25)
        XCTAssertLessThan(pixel[0], 50)
        XCTAssertGreaterThan(pixel[1], 240)
        XCTAssertLessThan(pixel[2], 50)
        XCTAssertEqual(pixel[3], 255)
    }

    func testSelectionKeepsChosenAreaOpaqueAndDimsOutside() throws {
        var state = SelectionSessionState.empty
        try SelectionReducer.reduce(
            state: &state,
            action: .manualDrag(CGRect(x: 25, y: 25, width: 50, height: 50))
        )
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state
        )

        let rendered = try render(view)

        let selectedPixel = try pixel(in: rendered, xFraction: 0.5, yFractionFromTop: 0.5)
        let outsidePixel = try pixel(in: rendered, xFraction: 0.1, yFractionFromTop: 0.5)
        XCTAssertGreaterThan(selectedPixel[1], 240)
        XCTAssertEqual(outsidePixel[3], 255)
        XCTAssertLessThan(outsidePixel[1], selectedPixel[1])
    }

    func testHoveredCandidateUsesThinBlueBorder() throws {
        var state = SelectionSessionState.empty
        state.hoveredCandidate = candidate(rect: CGRect(x: 60, y: 60, width: 30, height: 30))
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state
        )

        let rendered = try render(view)

        // Sample the left edge of the border (x=60) — should be blue.
        let borderPixel = try pixel(
            in: rendered,
            xFraction: 0.60,
            yFractionFromTop: 0.25
        )
        XCTAssertLessThan(borderPixel[0], 100, "red channel should be low")
        XCTAssertLessThan(borderPixel[1], 190, "green channel should be low")
        XCTAssertGreaterThan(borderPixel[2], 200, "blue channel should be high")
    }

    func testHoveredCandidateBorderIsHairlineNotThick() throws {
        var state = SelectionSessionState.empty
        state.hoveredCandidate = candidate(rect: CGRect(x: 60, y: 60, width: 30, height: 30))
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state
        )

        let rendered = try render(view)

        // The border is 1pt. The candidate interior (x=70) should remain bright
        // green (undimmed), proving there's no thick black outline eating into it.
        let interiorPixel = try pixel(in: rendered, xFraction: 0.70, yFractionFromTop: 0.25)
        XCTAssertLessThan(interiorPixel[0], 50, "red channel should be low")
        XCTAssertGreaterThan(interiorPixel[1], 220, "green should stay bright (not dimmed)")
        XCTAssertLessThan(interiorPixel[2], 50, "blue channel should be low")
    }

    func testWheelRequestsNextHierarchyCandidate() throws {
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            onAction: { actions.append($0) }
        )
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -1,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        view.scrollWheel(with: event)

        XCTAssertEqual(actions, [.cycleCandidate(1)])
    }

    func testPreciseWheelAccumulatesBeforeCyclingHierarchy() throws {
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            onAction: { actions.append($0) }
        )

        view.scrollWheel(with: try preciseScrollEvent(delta: -9))
        XCTAssertTrue(actions.isEmpty)
        view.scrollWheel(with: try preciseScrollEvent(delta: -1))
        XCTAssertEqual(actions, [.cycleCandidate(1)])
        view.scrollWheel(with: try preciseScrollEvent(delta: -1))
        XCTAssertEqual(actions, [.cycleCandidate(1)])
    }

    func testShiftDragDoesNotCreateManualSelection() throws {
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            onAction: { actions.append($0) }
        )

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, point: CGPoint(x: 10, y: 10), flags: .shift))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, point: CGPoint(x: 80, y: 80), flags: .shift))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, point: CGPoint(x: 80, y: 80), flags: .shift))

        XCTAssertFalse(actions.contains { action in
            if case .manualDrag = action { return true }
            return false
        })
    }

    func testAXCandidateClickCommitsOnlyAfterMouseUp() throws {
        var state = SelectionSessionState.empty
        state.hoveredCandidate = candidate(rect: CGRect(x: 10, y: 10, width: 80, height: 80))
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state,
            onAction: { actions.append($0) }
        )

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, point: CGPoint(x: 20, y: 70)))
        XCTAssertTrue(actions.isEmpty)

        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, point: CGPoint(x: 20, y: 70)))
        XCTAssertEqual(actions, [.click(try XCTUnwrap(state.hoveredCandidate), additive: false)])
    }

    func testDraggingInsideAXCandidateCreatesManualSelectionInsteadOfClickingCandidate() throws {
        var state = SelectionSessionState.empty
        state.hoveredCandidate = candidate(rect: CGRect(x: 10, y: 10, width: 80, height: 80))
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state,
            onAction: { actions.append($0) }
        )

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, point: CGPoint(x: 20, y: 70)))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, point: CGPoint(x: 70, y: 90)))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, point: CGPoint(x: 70, y: 90)))

        XCTAssertEqual(actions, [.manualDrag(CGRect(x: 20, y: 70, width: 50, height: 20))])
    }

    func testReleasingShiftConfirmsExistingMultiSelection() throws {
        var state = SelectionSessionState.empty
        try SelectionReducer.reduce(state: &state, action: .click(candidate(), additive: false))
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state,
            onAction: { actions.append($0) }
        )

        view.flagsChanged(with: try flagsEvent(.shift))
        view.flagsChanged(with: try flagsEvent([]))

        XCTAssertEqual(actions, [.confirm])
    }

    func testScrollControlSwitchesModeWithoutConfirmingSelection() throws {
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            onAction: { actions.append($0) }
        )

        view.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            point: CGPoint(x: view.bounds.midX + 20, y: 30)
        ))

        XCTAssertEqual(actions, [.setCaptureMode(.scrollCapture)])
    }

    func testOptionReturnCannotBypassCurrentCaptureMode() throws {
        var state = SelectionSessionState.empty
        try SelectionReducer.reduce(state: &state, action: .click(candidate(), additive: false))
        var actions: [SelectionAction] = []
        let view = selectionView(
            image: try solidImage(width: 100, height: 100, green: 255),
            state: state,
            onAction: { actions.append($0) }
        )

        view.keyDown(with: try keyEvent(keyCode: 36, flags: .option))

        XCTAssertEqual(actions, [.confirm])
    }

    func testCreatesOneFixedPanelPerDisplayAndTransfersKeyCapability() throws {
        let manager = ScreenshotSelectionOverlayManager(activateApplication: false)
        try manager.show(frames: [try frame(id: 1, x: 0), try frame(id: 2, x: 100)], state: .empty)

        XCTAssertEqual(manager.panelCount, 2)
        XCTAssertFalse(manager.panel(for: 1)!.canBecomeMain)
        XCTAssertFalse(manager.panel(for: 1)!.canBecomeKey)
        XCTAssertFalse(manager.panel(for: 2)!.canBecomeKey)
        XCTAssertEqual(manager.panel(for: 1)!.animationBehavior, .none)
        XCTAssertFalse(manager.panel(for: 1)!.isReleasedWhenClosed)

        manager.beginInteraction(on: 2)
        XCTAssertFalse(manager.panel(for: 1)!.canBecomeKey)
        XCTAssertTrue(manager.panel(for: 2)!.canBecomeKey)

        let framesBefore = [manager.panel(for: 1)!.frame, manager.panel(for: 2)!.frame]
        manager.update(state: .empty)
        XCTAssertEqual([manager.panel(for: 1)!.frame, manager.panel(for: 2)!.frame], framesBefore)
        manager.close(cancelled: false)
    }

    func testCancelRestoresPreviousApplicationOnceAndCloseIsIdempotent() throws {
        var restoreCount = 0
        let manager = ScreenshotSelectionOverlayManager(
            activateApplication: false,
            restorePreviousApplication: { restoreCount += 1 }
        )
        try manager.show(frames: [try frame(id: 1, x: 0)], state: .empty)
        manager.close(cancelled: true)
        manager.close(cancelled: true)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(manager.panelCount, 0)
    }

    func testClosingOverlayClosesVisibleMagnifierWindow() throws {
        let existingWindowNumbers = Set(NSApp.windows.map(\.windowNumber))
        let manager = ScreenshotSelectionOverlayManager(activateApplication: false)
        try manager.show(frames: [try frame(id: 1, x: 0)], state: .empty)
        let panel = try XCTUnwrap(manager.panel(for: 1))
        let view = try XCTUnwrap(panel.contentView as? ScreenshotSelectionView)

        view.mouseMoved(with: try mouseEvent(type: .mouseMoved, point: CGPoint(x: 80, y: 80)))

        let magnifierWindow = try XCTUnwrap(NSApp.windows.first { window in
            !existingWindowNumbers.contains(window.windowNumber)
                && window.contentView is MagnifierView
        })
        defer { magnifierWindow.close() }
        XCTAssertTrue(magnifierWindow.isVisible)

        manager.close(cancelled: false)

        XCTAssertFalse(magnifierWindow.isVisible)
    }

    private func frame(id: CGDirectDisplayID, x: CGFloat) throws -> DisplayCaptureFrame {
        guard let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw OverlayTestError.imageCreation
        }
        return DisplayCaptureFrame(
            geometry: DisplayCaptureGeometry(
                displayID: id,
                globalFramePoints: CGRect(x: x, y: 0, width: 100, height: 100),
                pixelSize: CGSize(width: 100, height: 100)
            ),
            image: image
        )
    }

    private func selectionView(
        image: CGImage,
        state: SelectionSessionState = .empty,
        onAction: @escaping (SelectionAction) -> Void = { _ in }
    ) -> ScreenshotSelectionView {
        ScreenshotSelectionView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            image: image,
            state: state,
            onAction: onAction,
            onHover: { _ in },
            onInteraction: {},
            onCancel: {}
        )
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        point: CGPoint,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { throw OverlayTestError.eventCreation }
        return event
    }

    private func flagsEvent(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        ) else { throw OverlayTestError.eventCreation }
        return event
    }

    private func keyEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: keyCode
        ) else { throw OverlayTestError.eventCreation }
        return event
    }

    private func preciseScrollEvent(delta: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        return event
    }

    private func candidate(
        rect: CGRect = CGRect(x: 10, y: 10, width: 30, height: 30)
    ) -> SelectionCandidate {
        SelectionCandidate(
            providerIdentity: "test",
            source: .accessibility,
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 1,
            role: "AXButton",
            title: "test",
            hierarchyIndex: 0,
            globalRect: rect
        )
    }

    private func render(_ view: NSView) throws -> CGImage {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw OverlayTestError.imageCreation
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let image = representation.cgImage else { throw OverlayTestError.imageCreation }
        return image
    }

    private func solidImage(width: Int, height: Int, green: UInt8) throws -> CGImage {
        try image(width: width, height: height) { _, _ in [0, green, 0, 255] }
    }

    private func verticallySplitImage(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { _, row in
            row < height / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
    }

    private func image(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> [UInt8]
    ) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                bytes.append(contentsOf: pixel(column, row))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { throw OverlayTestError.imageCreation }
        return image
    }

    private func pixel(
        in image: CGImage,
        xFraction: CGFloat,
        yFractionFromTop: CGFloat
    ) throws -> [UInt8] {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { throw OverlayTestError.imageCreation }
        let x = min(image.width - 1, Int(CGFloat(image.width) * xFraction))
        let y = min(image.height - 1, Int(CGFloat(image.height) * yFractionFromTop))
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    private enum OverlayTestError: Error { case imageCreation, eventCreation }
}
