import CoreGraphics
import XCTest
@testable import ToolBox

final class ScrollCaptureTargetTests: XCTestCase {
    func testBuildsTargetForElementsInSameWindow() throws {
        var state = SelectionSessionState.empty
        let first = candidate(rect: CGRect(x: 20, y: 30, width: 100, height: 80))
        let second = candidate(rect: CGRect(x: 100, y: 80, width: 120, height: 100))
        try SelectionReducer.reduce(state: &state, action: .click(first, additive: false))
        try SelectionReducer.reduce(state: &state, action: .click(second, additive: true))

        let target = try ScrollCaptureTargetSnapshot.make(
            selection: state,
            containingWindow: candidate(source: .window, rect: CGRect(x: 0, y: 0, width: 400, height: 500))
        )

        XCTAssertEqual(target.ownerPID, 42)
        XCTAssertEqual(target.windowID, 7)
        XCTAssertEqual(target.roiGlobal, first.globalRect.union(second.globalRect))
    }

    func testRejectsCrossWindowAndCrossDisplayUnions() throws {
        for invalid in [
            candidate(windowID: 8, rect: CGRect(x: 80, y: 80, width: 20, height: 20)),
            candidate(displayID: 2, rect: CGRect(x: 80, y: 80, width: 20, height: 20)),
        ] {
            var state = SelectionSessionState.empty
            try SelectionReducer.reduce(state: &state, action: .click(candidate(), additive: false))
            try SelectionReducer.reduce(state: &state, action: .click(invalid, additive: true))
            XCTAssertThrowsError(
                try ScrollCaptureTargetSnapshot.make(
                    selection: state,
                    containingWindow: candidate(source: .window, rect: CGRect(x: 0, y: 0, width: 400, height: 500))
                )
            ) { XCTAssertEqual($0 as? ScrollCaptureTargetError, .ineligibleSelection) }
        }
    }

    func testManualRegionRequiresOneContainingWindow() throws {
        var state = SelectionSessionState.empty
        try SelectionReducer.reduce(
            state: &state,
            action: .manualDrag(CGRect(x: 30, y: 40, width: 100, height: 120))
        )
        XCTAssertThrowsError(try ScrollCaptureTargetSnapshot.make(selection: state, containingWindow: nil)) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .containingWindowUnavailable)
        }
        XCTAssertNoThrow(
            try ScrollCaptureTargetSnapshot.make(
                selection: state,
                containingWindow: candidate(source: .window, rect: CGRect(x: 0, y: 0, width: 400, height: 500))
            )
        )
    }

    private func candidate(
        source: SelectionSource = .accessibility,
        pid: pid_t = 42,
        windowID: CGWindowID = 7,
        displayID: CGDirectDisplayID = 1,
        rect: CGRect = CGRect(x: 20, y: 30, width: 100, height: 80)
    ) -> SelectionCandidate {
        SelectionCandidate(
            providerIdentity: "test",
            source: source,
            ownerPID: pid,
            windowID: windowID,
            displayID: displayID,
            topologyGeneration: 9,
            role: nil,
            title: nil,
            hierarchyIndex: 0,
            globalRect: rect
        )
    }
}
