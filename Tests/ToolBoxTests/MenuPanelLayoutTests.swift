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
        XCTAssertEqual(frame.maxY, 1_070)
    }

    func testPanelFrameUsesMenuBarLowerEdgeWhenAnchorFrameIsBelowIt() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 875)
        let anchorFrame = NSRect(x: 1_000, y: 760, width: 28, height: 25)

        let frame = MenuPanelLayout.panelFrame(
            preferredSize: NSSize(width: 560, height: 600),
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxY, visibleFrame.maxY - 10)
    }

    func testPanelFrameUsesScreenContainingMenuBarAnchor() throws {
        let screens = [
            MenuPanelScreenGeometry(
                frame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 875)
            ),
            MenuPanelScreenGeometry(
                frame: NSRect(x: 1_440, y: -100, width: 1_560, height: 1_000),
                visibleFrame: NSRect(x: 1_440, y: -100, width: 1_560, height: 975)
            )
        ]

        let frame = try XCTUnwrap(MenuPanelLayout.panelFrame(
            preferredSize: NSSize(width: 560, height: 600),
            anchorFrame: NSRect(x: 2_920, y: 875, width: 28, height: 25),
            screens: screens
        ))

        XCTAssertEqual(frame, NSRect(x: 2_430, y: 265, width: 560, height: 600))
        XCTAssertLessThan(frame.maxY, 875)
        XCTAssertGreaterThanOrEqual(frame.minX, 1_450)
        XCTAssertLessThanOrEqual(frame.maxX, 2_990)
    }

    func testCompactPanelMetricsFitTheApprovedDesign() {
        XCTAssertEqual(MenuPanelLayout.size.width, 560)
        XCTAssertEqual(
            MenuPanelLayout.size.height,
            MenuPanelLayout.panelHeight(
                cableItemCount: HardwareMenuLayout.maxCableItemCount,
                showsDisplayControl: true,
                showsColorPreset: true
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
        XCTAssertEqual(MenuPanelLayout.wifiSectionHeight, 126)
    }

    func testWiFiConnectedContentLeavesBalancedHorizontalSpace() {
        let availableWidth = MenuPanelLayout.size.width
            - MenuPanelLayout.contentInsets.left
            - MenuPanelLayout.contentInsets.right
            - MenuPanelLayout.sectionPadding * 2
        let sideInset = (availableWidth - MenuPanelLayout.wifiConnectedContentWidth) / 2

        XCTAssertEqual(MenuPanelLayout.wifiConnectedContentWidth, 370)
        XCTAssertEqual(sideInset, 71)
        XCTAssertGreaterThan(sideInset, MenuPanelLayout.sectionPadding * 4)
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

    func testAudioSectionHeightGrowsWithRowsInsteadOfScrolling() {
        XCTAssertEqual(
            MenuPanelLayout.audioContentHeight(rowCount: 3),
            MenuPanelLayout.audioSectionContentHeight
        )
        XCTAssertGreaterThan(
            MenuPanelLayout.audioContentHeight(rowCount: 4),
            MenuPanelLayout.audioSectionContentHeight
        )
        XCTAssertEqual(MenuPanelLayout.audioContentHeight(rowCount: 0), 0)
    }

    func testPanelHeightIncludesAllVisibleAudioRows() {
        let threeRowHeight = MenuPanelLayout.panelHeight(
            cableItemCount: 0,
            showsDisplayControl: false,
            showsAudioSection: true,
            audioRowCount: 3
        )
        let fourRowHeight = MenuPanelLayout.panelHeight(
            cableItemCount: 0,
            showsDisplayControl: false,
            showsAudioSection: true,
            audioRowCount: 4
        )

        XCTAssertEqual(
            fourRowHeight - threeRowHeight,
            MenuPanelLayout.audioRowHeight + MenuPanelLayout.audioRowSpacing
        )
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
                showsDisplayControl: true,
                showsColorPreset: true
            )
        )
    }

    func testPanelHeightShrinksWhenOptionalSectionsAreHidden() {
        let fullHeight = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: true,
            showsAudioSection: true,
            showsColorPreset: true
        )
        let withoutDisplay = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: false,
            showsAudioSection: true,
            showsColorPreset: true
        )
        let withoutCables = MenuPanelLayout.panelHeight(
            cableItemCount: 0,
            showsDisplayControl: true,
            showsAudioSection: true,
            showsColorPreset: true
        )
        let withoutAudio = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: true,
            showsAudioSection: false,
            showsColorPreset: true
        )
        let compactHeight = MenuPanelLayout.panelHeight(
            cableItemCount: 0,
            showsDisplayControl: false,
            showsAudioSection: false,
            showsColorPreset: true
        )
        let twoRowCables = MenuPanelLayout.panelHeight(
            cableItemCount: 3,
            showsDisplayControl: true,
            showsAudioSection: true,
            showsColorPreset: true
        )

        XCTAssertLessThan(withoutDisplay, fullHeight)
        XCTAssertLessThan(withoutCables, fullHeight)
        XCTAssertLessThan(withoutAudio, fullHeight)
        XCTAssertLessThan(compactHeight, withoutDisplay)
        XCTAssertLessThan(compactHeight, withoutCables)
        XCTAssertEqual(
            fullHeight - withoutDisplay,
            MenuPanelLayout.contentSpacing
                + MenuPanelLayout.displaySectionHeight(showsColorPreset: true)
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

    func testPanelHeightExpandsOnlyWhenPresetIsVisible() {
        let withoutPreset = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: true,
            showsColorPreset: false
        )
        let withPreset = MenuPanelLayout.panelHeight(
            cableItemCount: 1,
            showsDisplayControl: true,
            showsColorPreset: true
        )

        XCTAssertEqual(
            withPreset - withoutPreset,
            MenuPanelLayout.displayPresetSectionHeight
                - MenuPanelLayout.displaySectionHeight
        )
    }

    func testMenuPopoverUsesSharedContentInsets() {
        let runtimeInsets = MenuBarPanelConfiguration.contentInsets

        XCTAssertEqual(runtimeInsets.top, MenuPanelLayout.contentInsets.top)
        XCTAssertEqual(runtimeInsets.left, MenuPanelLayout.contentInsets.left)
        XCTAssertEqual(runtimeInsets.bottom, MenuPanelLayout.contentInsets.bottom)
        XCTAssertEqual(runtimeInsets.right, MenuPanelLayout.contentInsets.right)
    }

    func testDisplayPresetRowAppearsImmediatelyBelowContrast() {
        XCTAssertEqual(
            DisplayControlPanelLayout.rows(showsPreset: false),
            [.brightness, .contrast, .volume]
        )
        XCTAssertEqual(
            DisplayControlPanelLayout.rows(showsPreset: true),
            [.brightness, .contrast, .preset, .volume]
        )
    }

    func testDisplayPresetRowUsesStableTracks() {
        XCTAssertEqual(DisplayControlPanelLayout.iconWidth, 18)
        XCTAssertEqual(DisplayControlPanelLayout.labelWidth, 66)
        XCTAssertEqual(DisplayControlPanelLayout.rowSpacing, 8)
        XCTAssertEqual(DisplayControlPanelLayout.displayPickerWidth, 210)
        XCTAssertGreaterThanOrEqual(
            DisplayControlPanelLayout.availablePresetControlWidth(
                panelWidth: MenuPanelLayout.size.width
            ),
            DisplayControlPanelLayout.minimumPresetControlWidth
        )
    }

    func testLongestFixturePresetNameFitsControlTrack() {
        let textWidth = ("Verified HDR Preview" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ).width
        let controlWidth = DisplayControlPanelLayout.availablePresetControlWidth(
            panelWidth: MenuPanelLayout.size.width
        )

        XCTAssertLessThan(textWidth, controlWidth)
        XCTAssertLessThan(
            DisplayControlPanelLayout.displayPickerWidth,
            MenuPanelLayout.size.width
        )
    }

    @MainActor
    func testDisplayPanelWithPresetFitsAllocatedSection() {
        let snapshot = DisplayControlSnapshot(
            timestamp: Date(),
            displays: [
                DisplayControlDisplay(
                    id: 42,
                    name: "Preset Display",
                    vendorNumber: 1,
                    modelNumber: 2,
                    serialNumber: 3,
                    isBuiltIn: false,
                    isVirtual: false,
                    supportsHardwareDDC: true,
                    backendName: "Test DDC",
                    unavailableReason: nil,
                    controls: [],
                    colorPreset: DisplayColorPresetCapability(
                        status: .available,
                        currentRawValue: 0x41,
                        options: [
                            DisplayColorPresetOption(
                                rawValue: 0x41,
                                name: "Verified HDR Preview"
                            ),
                        ],
                        advertisedRawValues: [0x41],
                        unavailableReason: nil
                    )
                ),
            ]
        )
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)
        let model = DisplayControlMenuModel(
            service: service,
            colorPresetPOCEnabled: { true }
        )
        model.start()

        let hostingView = NSHostingView(rootView: DisplayControlPanel(model: model))
        let fittingSize = hostingView.fittingSize
        let availableWidth = MenuPanelLayout.size.width
            - MenuPanelLayout.contentInsets.left
            - MenuPanelLayout.contentInsets.right
            - MenuPanelLayout.sectionPadding * 2

        XCTAssertLessThanOrEqual(fittingSize.width, availableWidth)
        XCTAssertLessThanOrEqual(
            fittingSize.height + MenuPanelLayout.sectionChromeHeight,
            MenuPanelLayout.displaySectionHeight(showsColorPreset: true)
        )
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
