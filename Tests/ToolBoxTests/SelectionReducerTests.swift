import CoreGraphics
import XCTest
@testable import ToolBoxCore

final class SelectionReducerTests: XCTestCase {
    func testCaptureModeDefaultsToStaticAndCanSwitchToScroll() throws {
        var state = SelectionSessionState.empty
        XCTAssertEqual(state.captureMode, .staticCapture)

        try SelectionReducer.reduce(state: &state, action: .setCaptureMode(.scrollCapture))

        XCTAssertEqual(state.captureMode, .scrollCapture)
        XCTAssertNil(state.captureBounds)
    }

    func testShiftClickAddsConnectedRegionAndExpandsBounds() throws {
        var state = SelectionSessionState.empty
        let left = candidate(id: "left", rect: CGRect(x: 10, y: 10, width: 40, height: 20))
        let right = candidate(id: "right", rect: CGRect(x: 50, y: 20, width: 30, height: 20))

        try SelectionReducer.reduce(state: &state, action: .click(left, additive: false))
        try SelectionReducer.reduce(state: &state, action: .click(right, additive: true))

        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [left.candidateKey, right.candidateKey])
        XCTAssertEqual(state.captureBounds, CGRect(x: 10, y: 10, width: 70, height: 30))
    }

    func testShiftClickSelectedCandidateRemovesIt() throws {
        var state = SelectionSessionState.empty
        let left = candidate(id: "left")
        let right = candidate(id: "right", rect: CGRect(x: 20, y: 0, width: 20, height: 20))
        try SelectionReducer.reduce(state: &state, action: .click(left, additive: false))
        try SelectionReducer.reduce(state: &state, action: .click(right, additive: true))

        try SelectionReducer.reduce(state: &state, action: .click(left, additive: true))

        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [right.candidateKey])
        XCTAssertEqual(state.captureBounds, right.globalRect)
    }

    func testShiftClickAllowsCandidateTouchingExistingSelectionEdge() throws {
        var state = SelectionSessionState.empty
        let left = candidate(id: "left", rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let touching = candidate(id: "touching", rect: CGRect(x: 20, y: 4, width: 10, height: 12))
        try SelectionReducer.reduce(state: &state, action: .click(left, additive: false))

        try SelectionReducer.reduce(state: &state, action: .click(touching, additive: true))

        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [left.candidateKey, touching.candidateKey])
    }

    func testShiftClickRejectsCandidateDisconnectedFromExistingSelection() throws {
        var state = SelectionSessionState.empty
        let left = candidate(id: "left", rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let disconnected = candidate(id: "disconnected", rect: CGRect(x: 21, y: 0, width: 10, height: 10))
        try SelectionReducer.reduce(state: &state, action: .click(left, additive: false))

        XCTAssertThrowsError(
            try SelectionReducer.reduce(state: &state, action: .click(disconnected, additive: true))
        )
        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [left.candidateKey])
    }

    func testNormalClickReplacesSelection() throws {
        var state = SelectionSessionState.empty
        let first = candidate(id: "first")
        let second = candidate(id: "second")
        try SelectionReducer.reduce(state: &state, action: .click(first, additive: false))
        try SelectionReducer.reduce(state: &state, action: .click(second, additive: false))
        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [second.candidateKey])
    }

    func testDeleteLastAndUndoRestoreCompleteValueState() throws {
        var state = SelectionSessionState.empty
        let first = candidate(id: "first")
        let second = candidate(id: "second", rect: CGRect(x: 20, y: 0, width: 20, height: 20))
        try SelectionReducer.reduce(state: &state, action: .click(first, additive: false))
        try SelectionReducer.reduce(state: &state, action: .click(second, additive: true))
        let bounds = state.captureBounds
        try SelectionReducer.reduce(state: &state, action: .deleteLast)
        try SelectionReducer.reduce(state: &state, action: .undo)
        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [first.candidateKey, second.candidateKey])
        XCTAssertEqual(state.captureBounds, bounds)
    }

    func testManualDragClearsElementSelectionAndUndoRestoresIt() throws {
        var state = SelectionSessionState.empty
        let element = candidate(id: "element")
        try SelectionReducer.reduce(state: &state, action: .click(element, additive: false))
        try SelectionReducer.reduce(
            state: &state,
            action: .manualDrag(CGRect(x: 100, y: 100, width: 30, height: 40))
        )
        XCTAssertTrue(state.selectedRegions.isEmpty)
        XCTAssertEqual(state.captureBounds, CGRect(x: 100, y: 100, width: 30, height: 40))
        try SelectionReducer.reduce(state: &state, action: .undo)
        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), [element.candidateKey])
    }

    func testRegionAdjustmentPreservesManualSelection() throws {
        var state = SelectionSessionState.empty
        try SelectionReducer.reduce(
            state: &state,
            action: .manualDrag(CGRect(x: 10, y: 10, width: 30, height: 40))
        )

        try SelectionReducer.reduce(
            state: &state,
            action: .adjustRegion(CGRect(x: 12, y: 14, width: 35, height: 45))
        )

        XCTAssertEqual(state.manualRegion, CGRect(x: 12, y: 14, width: 35, height: 45))
    }

    func testEmptyConfirmationAndInvalidRectsAreRejected() {
        var state = SelectionSessionState.empty
        XCTAssertThrowsError(try SelectionReducer.reduce(state: &state, action: .confirm)) {
            XCTAssertEqual($0 as? SelectionError, .emptySelection)
        }
        XCTAssertThrowsError(try SelectionReducer.reduce(
            state: &state,
            action: .manualDrag(CGRect(x: 0, y: 0, width: 0, height: 10))
        )) {
            XCTAssertEqual($0 as? SelectionError, .invalidRegion)
        }
    }

    func testCandidateKeyQuantizesRectToQuarterPoints() {
        let first = candidate(id: "same", rect: CGRect(x: 1.01, y: 2.01, width: 10.01, height: 20.01))
        let second = candidate(id: "same", rect: CGRect(x: 1.10, y: 2.10, width: 10.10, height: 20.10))
        XCTAssertEqual(first.candidateKey, second.candidateKey)
    }

    private func candidate(
        id: String,
        rect: CGRect = CGRect(x: 0, y: 0, width: 20, height: 20)
    ) -> SelectionCandidate {
        SelectionCandidate(
            providerIdentity: id,
            source: .accessibility,
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 3,
            role: "AXButton",
            title: id,
            hierarchyIndex: 0,
            globalRect: rect
        )
    }
}
