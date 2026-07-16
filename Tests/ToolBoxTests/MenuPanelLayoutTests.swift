import AppKit
import SwiftUI
import XCTest
@testable import ToolBox

final class MenuPanelLayoutTests: XCTestCase {
    func testCompactPanelMetricsFitTheApprovedDesign() {
        XCTAssertEqual(MenuPanelLayout.size.width, 560)
        XCTAssertEqual(MenuPanelLayout.size.height, 718)
        XCTAssertEqual(MenuPanelLayout.contentInsets.top, 14)
        XCTAssertEqual(MenuPanelLayout.headerHeight, 52)
        XCTAssertEqual(MenuPanelLayout.headerBadgesWidth, 260)
        XCTAssertEqual(MenuPanelLayout.chartHeight, 96)
        XCTAssertEqual(MenuPanelLayout.cableRowHeight, 90)
        XCTAssertEqual(MenuPanelLayout.controlsHeight, 50)
        XCTAssertEqual(MenuPanelLayout.cornerRadius, 22)
    }

    func testStandardCompleteConfigurationFitsWithoutScrolling() {
        let availableHeight = MenuPanelLayout.size.height
            - MenuPanelLayout.contentInsets.top
            - MenuPanelLayout.contentInsets.bottom

        XCTAssertLessThanOrEqual(MenuPanelLayout.standardContentHeight, availableHeight)
        XCTAssertLessThan(MenuPanelLayout.chartHeight, 126)
        XCTAssertLessThanOrEqual(MenuPanelLayout.cableRowHeight, 96)
        XCTAssertLessThan(MenuPanelLayout.controlsHeight, 64)
        XCTAssertLessThan(MenuPanelLayout.sectionPadding, 14)
        XCTAssertLessThan(MenuPanelLayout.outerSpacing, 18)
    }

    func testCableGridGeometryForUpToThreeItems() {
        XCTAssertEqual(HardwareMenuLayout.cableColumnCount(itemCount: 0), 1)
        XCTAssertEqual(HardwareMenuLayout.cableColumnCount(itemCount: 1), 1)
        XCTAssertEqual(HardwareMenuLayout.cableColumnCount(itemCount: 2), 2)
        XCTAssertEqual(HardwareMenuLayout.cableColumnCount(itemCount: 3), 2)

        XCTAssertEqual(HardwareMenuLayout.cableRowCount(itemCount: 0), 0)
        XCTAssertEqual(HardwareMenuLayout.cableRowCount(itemCount: 1), 1)
        XCTAssertEqual(HardwareMenuLayout.cableRowCount(itemCount: 2), 1)
        XCTAssertEqual(HardwareMenuLayout.cableRowCount(itemCount: 3), 2)

        XCTAssertEqual(HardwareMenuLayout.cableListHeight(itemCount: 0), 0)
        XCTAssertEqual(HardwareMenuLayout.cableListHeight(itemCount: 1), MenuPanelLayout.cableRowHeight)
        XCTAssertEqual(HardwareMenuLayout.cableListHeight(itemCount: 2), MenuPanelLayout.cableRowHeight)
        XCTAssertEqual(
            HardwareMenuLayout.cableListHeight(itemCount: 3),
            MenuPanelLayout.cableRowHeight * 2 + MenuPanelLayout.cableGridSpacing
        )
    }

    func testMaximumCableConfigurationFitsWithoutScrolling() {
        let availableHeight = MenuPanelLayout.size.height
            - MenuPanelLayout.contentInsets.top
            - MenuPanelLayout.contentInsets.bottom
        let maximumContentHeight = MenuPanelLayout.standardContentHeight
            + MenuPanelLayout.cableRowHeight
            + MenuPanelLayout.cableGridSpacing

        XCTAssertLessThanOrEqual(maximumContentHeight, availableHeight)
    }

    func testMenuPopoverUsesSharedContentInsets() {
        let runtimeInsets = MenuBarPanelConfiguration.contentInsets

        XCTAssertEqual(runtimeInsets.top, MenuPanelLayout.contentInsets.top)
        XCTAssertEqual(runtimeInsets.left, MenuPanelLayout.contentInsets.left)
        XCTAssertEqual(runtimeInsets.bottom, MenuPanelLayout.contentInsets.bottom)
        XCTAssertEqual(runtimeInsets.right, MenuPanelLayout.contentInsets.right)
    }

    @MainActor
    func testLongHeaderBadgesFitWithinHeaderHeightAtSharedWidth() {
        let powerSummary = "CPU 123.45 W  GPU 67.89 W"
        let displaySummary = "DELL UltraSharp U3225QE (3840 x 2160)"
        let badgeStack = HeaderBadgeStack(
            powerSummary: powerSummary,
            displaySummary: displaySummary
        )
        let hostingView = NSHostingView(
            rootView: badgeStack.frame(width: MenuPanelLayout.headerBadgesWidth)
        )
        let fittingSize = hostingView.fittingSize

        XCTAssertEqual(badgeStack.powerSummary, powerSummary)
        XCTAssertEqual(badgeStack.displaySummary, displaySummary)
        XCTAssertEqual(fittingSize.width, MenuPanelLayout.headerBadgesWidth, accuracy: 0.5)
        XCTAssertGreaterThan(fittingSize.height, 0)
        XCTAssertLessThanOrEqual(fittingSize.height, MenuPanelLayout.headerHeight)
    }
}
