import AppKit
import SwiftUI
import XCTest
@testable import ToolBoxCore

final class MenuPanelLayoutTests: XCTestCase {
    func testPanelFrameScalesProportionallyInsteadOfClipping() {
        let preferred = NSSize(width: 560, height: 830)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 800)
        let placement = MenuPanelLayout.placement(
            preferredSize: preferred,
            anchorFrame: NSRect(x: 1_380, y: 780, width: 28, height: 20),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(placement.scale, MenuPanelLayout.designScale)
        XCTAssertEqual(placement.frame.width, preferred.width * MenuPanelLayout.designScale)
        XCTAssertEqual(placement.frame.height, preferred.height * MenuPanelLayout.designScale)
        XCTAssertEqual(
            placement.frame.width / placement.frame.height,
            preferred.width / preferred.height,
            accuracy: 0.000_1
        )
        XCTAssertGreaterThanOrEqual(placement.frame.minX, visibleFrame.minX + 10)
        XCTAssertLessThanOrEqual(placement.frame.maxX, visibleFrame.maxX - 10)
        XCTAssertGreaterThanOrEqual(placement.frame.minY, visibleFrame.minY + 10)
        XCTAssertEqual(placement.frame.maxY, visibleFrame.maxY - MenuPanelLayout.verticalGap)
    }

    func testPanelFrameShrinksFurtherOnVeryShortScreen() {
        let preferred = NSSize(width: 560, height: 830)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_280, height: 600)
        let scale = MenuPanelLayout.presentationScale(
            preferredSize: preferred,
            visibleFrame: visibleFrame
        )
        let placement = MenuPanelLayout.placement(
            preferredSize: preferred,
            anchorFrame: NSRect(x: 640, y: 575, width: 28, height: 22),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(scale, (600 - MenuPanelLayout.screenMargin * 2) / 830, accuracy: 0.000_1)
        XCTAssertLessThan(scale, MenuPanelLayout.designScale)
        XCTAssertEqual(placement.scale, scale)
        XCTAssertEqual(
            placement.frame.width / placement.frame.height,
            preferred.width / preferred.height,
            accuracy: 0.000_1
        )
        XCTAssertEqual(placement.frame.maxY, visibleFrame.maxY - MenuPanelLayout.verticalGap)
    }

    func testPanelFramePreservesDesignScaleWhenItFits() {
        let preferred = NSSize(width: 560, height: 600)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let frame = MenuPanelLayout.panelFrame(
            preferredSize: preferred,
            anchorFrame: NSRect(x: 900, y: 1_000, width: 28, height: 20),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.size, MenuPanelLayout.scaledSize(preferred, scale: MenuPanelLayout.designScale))
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - MenuPanelLayout.verticalGap)
    }

    func testPanelFrameUsesMenuBarLowerEdgeWhenAnchorFrameIsBelowIt() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 875)
        let anchorFrame = NSRect(x: 1_000, y: 760, width: 28, height: 25)

        let frame = MenuPanelLayout.panelFrame(
            preferredSize: NSSize(width: 560, height: 600),
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxY, visibleFrame.maxY - MenuPanelLayout.verticalGap)
    }

    func testPanelTopEdgeStaysFixedAcrossResolutions() {
        let preferred = NSSize(width: 560, height: 600)
        let screens: [(anchor: NSRect, visible: NSRect)] = [
            (
                NSRect(x: 700, y: 875, width: 28, height: 22),
                NSRect(x: 0, y: 0, width: 1_440, height: 875)
            ),
            (
                NSRect(x: 960, y: 1_050, width: 28, height: 22),
                NSRect(x: 0, y: 0, width: 1_920, height: 1_050)
            ),
            (
                NSRect(x: 1_200, y: 1_570, width: 28, height: 22),
                NSRect(x: 0, y: 0, width: 2_560, height: 1_570)
            ),
        ]

        for screen in screens {
            let frame = MenuPanelLayout.panelFrame(
                preferredSize: preferred,
                anchorFrame: screen.anchor,
                visibleFrame: screen.visible
            )
            XCTAssertEqual(frame.maxY, screen.visible.maxY - MenuPanelLayout.verticalGap)
            XCTAssertEqual(frame.midX, screen.anchor.midX, accuracy: 0.001)
        }
    }

    func testUnstableZeroAnchorIsRejected() {
        XCTAssertFalse(
            MenuPanelLayout.isStableMenuBarAnchor(
                .zero,
                screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 875)
            )
        )
    }

    func testDesktopOriginAnchorIsRejected() {
        XCTAssertFalse(
            MenuPanelLayout.isStableMenuBarAnchor(
                NSRect(x: 0, y: 0, width: 28, height: 22),
                screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 875)
            )
        )
    }

    func testMenuBarAnchorOnPrimaryDisplayIsStable() {
        XCTAssertTrue(
            MenuPanelLayout.isStableMenuBarAnchor(
                NSRect(x: 1_380, y: 875, width: 28, height: 22),
                screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 875)
            )
        )
    }

    func testMenuBarAnchorOnSecondaryDisplayWithNegativeOriginIsStable() {
        let screen = NSRect(x: 1_440, y: -100, width: 1_920, height: 1_080)
        let visible = NSRect(x: 1_440, y: -100, width: 1_920, height: 1_055)
        let anchor = NSRect(x: 3_200, y: 955, width: 28, height: 22)

        XCTAssertTrue(
            MenuPanelLayout.isStableMenuBarAnchor(
                anchor,
                screenFrame: screen,
                visibleFrame: visible
            )
        )
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

        let preferred = NSSize(width: 560, height: 600)
        let frame = try XCTUnwrap(MenuPanelLayout.panelFrame(
            preferredSize: preferred,
            anchorFrame: NSRect(x: 2_920, y: 875, width: 28, height: 25),
            screens: screens
        ))
        let placement = try XCTUnwrap(MenuPanelLayout.placement(
            preferredSize: preferred,
            anchorFrame: NSRect(x: 2_920, y: 875, width: 28, height: 25),
            screens: screens
        ))

        XCTAssertEqual(placement.scale, MenuPanelLayout.designScale)
        XCTAssertEqual(frame, placement.frame)
        XCTAssertEqual(frame.maxY, 875 - MenuPanelLayout.verticalGap)
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

    func testAudioSectionHeightStaysFixedWhileRowsScrollHorizontally() {
        XCTAssertEqual(MenuPanelLayout.audioSectionContentHeight, 160)
        XCTAssertEqual(
            MenuPanelLayout.audioContentHeight(rowCount: 3, isLiteMode: true),
            MenuPanelLayout.liteAudioSectionContentHeight
        )
        XCTAssertEqual(
            MenuPanelLayout.audioContentHeight(rowCount: 3),
            MenuPanelLayout.audioSectionContentHeight
        )
        XCTAssertEqual(MenuPanelLayout.audioContentHeight(rowCount: 4), MenuPanelLayout.audioSectionContentHeight)
        XCTAssertEqual(MenuPanelLayout.audioContentHeight(rowCount: 0), 0)
    }

    func testPanelHeightUsesFixedAudioViewport() {
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

        XCTAssertEqual(fourRowHeight, threeRowHeight)
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

    // MARK: - Configurable element layout

    func testConfigurableLayoutMatchesLegacyFlagsAcrossSectionCombinations() {
        let combinations: [(cables: Int, display: Bool, audio: Bool, preset: Bool, lite: Bool)] = [
            (3, true, true, true, false),
            (1, true, true, false, false),
            (0, false, true, false, false),
            (2, true, false, true, false),
            (1, false, false, false, false),
            (3, true, true, true, true),
        ]

        for combination in combinations {
            let legacy = MenuPanelLayout.contentHeight(
                cableItemCount: combination.cables,
                showsDisplayControl: combination.display,
                showsAudioSection: combination.audio,
                showsColorPreset: combination.preset,
                audioRowCount: combination.audio ? 3 : 0,
                isAudioLiteMode: combination.lite
            )
            let context = MenuBarElementRuntimeContext(
                cableItemCount: combination.cables,
                audioRowCount: combination.audio ? 3 : 0,
                isAudioLiteMode: combination.lite,
                hasExternalDisplay: combination.display,
                showsColorPreset: combination.preset
            )
            let configurable = MenuPanelLayout.contentHeight(
                elements: MenuBarElementProjection.visibleElements(
                    from: MenuBarLayoutConfiguration.default().entries,
                    context: context
                ),
                context: context
            )

            XCTAssertEqual(legacy, configurable, "combination: \(combination)")
        }
    }

    func testContentHeightFollowsConfiguredElementOrder() {
        let context = MenuBarElementRuntimeContext(
            cableItemCount: 1,
            audioRowCount: 3,
            isAudioLiteMode: false,
            hasExternalDisplay: true,
            showsColorPreset: true
        )
        let reversed = MenuBarElementID.defaultOrder.reversed()

        let defaultHeight = MenuPanelLayout.contentHeight(
            elements: Array(MenuBarElementID.defaultOrder),
            context: context
        )
        let reversedHeight = MenuPanelLayout.contentHeight(
            elements: Array(reversed),
            context: context
        )

        // Reordering never changes the total height: spacing depends only on
        // quick-controls adjacency, and every element stays adjacent to a
        // regular section in both orders.
        XCTAssertEqual(defaultHeight, reversedHeight)
    }

    func testQuickControlsKeepsOuterSpacingWhereverPlaced() {
        let context = MenuBarElementRuntimeContext(
            cableItemCount: 1,
            audioRowCount: 3,
            isAudioLiteMode: false,
            hasExternalDisplay: true,
            showsColorPreset: true
        )
        let withQuickControlsFirst = MenuBarLayoutConfiguration(entries: [
            MenuBarElementEntry(id: .quickControls),
            MenuBarElementEntry(id: .chipPower),
            MenuBarElementEntry(id: .appAudio),
            MenuBarElementEntry(id: .cableStatus),
            MenuBarElementEntry(id: .wifiSignal),
            MenuBarElementEntry(id: .displayControl),
        ])
        let visible = MenuBarElementProjection.visibleElements(
            from: withQuickControlsFirst.entries,
            context: context
        )

        XCTAssertEqual(visible.first, .quickControls)
        XCTAssertEqual(
            MenuPanelLayout.spacing(after: nil, element: .quickControls),
            MenuPanelLayout.outerSpacing
        )
        XCTAssertEqual(
            MenuPanelLayout.spacing(after: .quickControls, element: .chipPower),
            MenuPanelLayout.outerSpacing
        )
        XCTAssertEqual(
            MenuPanelLayout.spacing(after: .chipPower, element: .appAudio),
            MenuPanelLayout.contentSpacing
        )

        // The legacy default order has the same total height because swapping
        // the quick-controls position swaps two outer spacings symmetrically.
        XCTAssertEqual(
            MenuPanelLayout.contentHeight(elements: visible, context: context),
            MenuPanelLayout.contentHeight(
                elements: MenuBarElementProjection.visibleElements(
                    from: MenuBarLayoutConfiguration.default().entries,
                    context: context
                ),
                context: context
            )
        )
    }

    func testPanelHeightIgnoresHiddenAndUnavailableElements() {
        let context = MenuBarElementRuntimeContext(
            cableItemCount: 0,
            audioRowCount: 0,
            isAudioLiteMode: false,
            hasExternalDisplay: false,
            showsColorPreset: false
        )
        let compactExpected = MenuPanelLayout.panelHeight(
            elements: [.chipPower, .wifiSignal, .quickControls],
            context: context
        )

        // Runtime-unavailable elements drop out of the shared projection even
        // when the user keeps them enabled, so the panel never reserves space
        // for them.
        let projected = MenuBarElementProjection.visibleElements(
            from: MenuBarLayoutConfiguration.default().entries,
            context: context
        )
        XCTAssertEqual(projected, [.chipPower, .wifiSignal, .quickControls])
        XCTAssertEqual(
            MenuPanelLayout.panelHeight(elements: projected, context: context),
            compactExpected
        )
    }

    func testPanelWithEverythingHiddenKeepsOnlyHeaderArea() {
        let context = MenuBarElementRuntimeContext()

        XCTAssertEqual(
            MenuPanelLayout.panelHeight(elements: [], context: context),
            MenuPanelLayout.headerHeight
                + MenuPanelLayout.contentInsets.top
                + MenuPanelLayout.contentInsets.bottom
        )
        XCTAssertLessThan(
            MenuPanelLayout.panelHeight(elements: [], context: context),
            80
        )
    }

    func testDynamicElementReturnsToConfiguredPositionAfterRecovery() {
        var configuration = MenuBarLayoutConfiguration.default()
        configuration.entries.swapAt(4, 0) // chipPower <-> displayControl
        let entries = configuration.entries

        let offline = MenuBarElementRuntimeContext()
        let online = MenuBarElementRuntimeContext(
            cableItemCount: 2,
            audioRowCount: 3,
            isAudioLiteMode: false,
            hasExternalDisplay: true,
            showsColorPreset: true
        )

        // Offline only the always-available elements stay, in configured order.
        XCTAssertEqual(
            MenuBarElementProjection.visibleElements(from: entries, context: offline),
            [.wifiSignal, .chipPower, .quickControls]
        )
        // Online every element is back — chipPower stays at its configured
        // slot after displayControl.
        XCTAssertEqual(
            MenuBarElementProjection.visibleElements(from: entries, context: online),
            [.displayControl, .appAudio, .cableStatus, .wifiSignal, .chipPower, .quickControls]
        )

        // The panel grows back by exactly the three data-driven sections.
        let offlineHeight = MenuPanelLayout.panelHeight(
            elements: MenuBarElementProjection.visibleElements(from: entries, context: offline),
            context: offline
        )
        let onlineHeight = MenuPanelLayout.panelHeight(
            elements: MenuBarElementProjection.visibleElements(from: entries, context: online),
            context: online
        )
        XCTAssertEqual(
            onlineHeight - offlineHeight,
            MenuPanelLayout.contentSpacing * 3
                + MenuPanelLayout.audioSectionHeight
                + MenuPanelLayout.cableSectionHeight(itemCount: 2)
                + MenuPanelLayout.displaySectionHeight(showsColorPreset: true)
        )
    }

    func testPanelContentWidthMatchesSectionDesignWidth() {
        XCTAssertEqual(
            MenuPanelLayout.panelContentWidth,
            MenuPanelLayout.size.width
                - MenuPanelLayout.contentInsets.left
                - MenuPanelLayout.contentInsets.right
        )
        XCTAssertEqual(MenuPanelLayout.panelContentWidth, 532)
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
