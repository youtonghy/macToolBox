import AppKit
import XCTest
@testable import ToolBox

final class GlassContainerViewTests: XCTestCase {
    func testRootLayerOwnsClippingButNotExteriorShadow() throws {
        let view = GlassContainerView(frame: NSRect(origin: .zero, size: MenuPanelLayout.size))
        let layer = try XCTUnwrap(view.layer)

        XCTAssertEqual(layer.cornerRadius, MenuPanelLayout.cornerRadius)
        XCTAssertEqual(layer.cornerCurve, .continuous)
        XCTAssertTrue(layer.masksToBounds)
        XCTAssertEqual(layer.shadowOpacity, 0)
    }
}
