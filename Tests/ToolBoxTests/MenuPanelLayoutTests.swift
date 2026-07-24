import AppKit
import SwiftUI
import XCTest
@testable import ToolBox

final class MenuPanelLayoutTests: XCTestCase {
    func testPanelFrameFitsWithinShortVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 800)
        let anchorFrame = NSRect(x: 1_380, y: 780, width: 28, height: 20)

        let frame = MenuPanelLayout.panelFrame(
            preferredSize: NSSize(width: 560, height: 830),
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.height, 780)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + 10)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - 10)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + 10)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - 10)
    }

    func testPanelFramePreservesPreferredSizeWhenItFits() {
        let frame = MenuPanelLayout.panelFrame(
            preferredSize: NSSize(width: 560, height: 600),
            anchorFrame: NSRect(x: 900, y: 1_000, width: 28, height: 20),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )

        XCTAssertEqual(frame.size, NSSize(width: 560, height: 600))
        XCTAssertEqual(frame.maxY, 992)
    }

    func testCompactPanelMetricsFitTheApprovedDesign() {
        XCTAssertEqual(MenuPanelLayout.size.width, 560)
        XCTAssertEqual(
            MenuPanelLayout.size.height,
            MenuPanelLayout.panelHeight(
                cableItemCount: HardwareMenuLayout.maxCableItemCount,
                showsDisplayControl: true
            )
        )
        XCTAssertEqual(MenuPanelLayout.contentInsets.top, 14)
        XCTAssertEqual(MenuPanelLayout.headerHeight, 28)
        XCTAssertEqual(MenuPanelLayout.chartHeight, 96)
        XCTAssertEqual(MenuPanelLayout.cableRowHeight, 90)
        XCTAssertEqual(MenuPanelLayout.controlButtonSize, 40)
        XCTAssertEqual(MenuPanelLayout.controlsHeight, MenuPanelLayout.controlButtonSize)
        XCTAssertEqual(MenuPanelLayout.cornerRadius, 22)
        XCTAssertEqual(MenuPanelLayout.sectionChromeHeight, 44)
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
        XCTAssertEqual(
            maximumContentHeight,
            MenuPanelLayout.contentHeight(
                cableItemCount: HardwareMenuLayout.maxCableItemCount,
                showsDisplayControl: true
            )
        )
    }

    func testPanelHeightShrinksWhenOptionalSectionsAreHidden() {
        let fullHeight = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: true,
            showsAudioSection: true
        )
        let withoutDisplay = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: false,
            showsAudioSection: true
        )
        let withoutCables = MenuPanelLayout.panelHeight(
            cableItemCount: 0,
            showsDisplayControl: true,
            showsAudioSection: true
        )
        let withoutAudio = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: true,
            showsAudioSection: false
        )
        let compactHeight = MenuPanelLayout.panelHeight(
            cableItemCount: 0,
            showsDisplayControl: false,
            showsAudioSection: false
        )
        let twoRowCables = MenuPanelLayout.panelHeight(
            cableItemCount: 3,
            showsDisplayControl: true,
            showsAudioSection: true
        )

        XCTAssertLessThan(withoutDisplay, fullHeight)
        XCTAssertLessThan(withoutCables, fullHeight)
        XCTAssertLessThan(withoutAudio, fullHeight)
        XCTAssertLessThan(compactHeight, withoutDisplay)
        XCTAssertLessThan(compactHeight, withoutCables)
        XCTAssertEqual(
            fullHeight - withoutDisplay,
            MenuPanelLayout.contentSpacing + MenuPanelLayout.displaySectionHeight
        )
        XCTAssertEqual(
            fullHeight - withoutCables,
            MenuPanelLayout.contentSpacing + MenuPanelLayout.cableSectionHeight(itemCount: 1)
        )
        XCTAssertEqual(
            fullHeight - withoutAudio,
            MenuPanelLayout.contentSpacing + MenuPanelLayout.audioSectionHeight
        )
        XCTAssertEqual(
            twoRowCables - fullHeight,
            MenuPanelLayout.cableRowHeight + MenuPanelLayout.cableGridSpacing
        )
        XCTAssertEqual(MenuPanelLayout.size.height, twoRowCables)
        XCTAssertEqual(
            MenuPanelLayout.panelSize(
                cableItemCount: 0,
                showsDisplayControl: false,
                showsAudioSection: false
            ).width,
            560
        )
    }

    func testMenuPopoverUsesSharedContentInsets() {
        let runtimeInsets = MenuBarPanelConfiguration.contentInsets

        XCTAssertEqual(runtimeInsets.top, MenuPanelLayout.contentInsets.top)
        XCTAssertEqual(runtimeInsets.left, MenuPanelLayout.contentInsets.left)
        XCTAssertEqual(runtimeInsets.bottom, MenuPanelLayout.contentInsets.bottom)
        XCTAssertEqual(runtimeInsets.right, MenuPanelLayout.contentInsets.right)
    }

    @MainActor
    func testTitleOnlyHeaderFitsWithinHeaderHeight() {
        let title = Text("ToolBox")
            .font(.system(size: 22, weight: .semibold))
        let hostingView = NSHostingView(rootView: title)
        let fittingSize = hostingView.fittingSize

        XCTAssertGreaterThan(fittingSize.height, 0)
        XCTAssertLessThanOrEqual(fittingSize.height, MenuPanelLayout.headerHeight)
    }
}
