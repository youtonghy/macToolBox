import XCTest
@testable import ToolBoxCore

@MainActor
final class ScreenWipeCoordinatorTests: XCTestCase {
    func testScreenWipeFailsClosedWithoutRegisteredExitShortcut() {
        let coordinator = ScreenWipeCoordinator()
        var didFinish = false

        XCTAssertFalse(coordinator.start(
            exitShortcutAvailable: false,
            onDone: { didFinish = true }
        ))
        XCTAssertFalse(didFinish)
    }
}
