import XCTest
@testable import ToolBox

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
