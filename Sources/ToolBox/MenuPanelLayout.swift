import AppKit

struct MenuPanelScreenGeometry {
    let frame: NSRect
    let visibleFrame: NSRect
}

struct MenuPanelPlacement: Equatable {
    var frame: NSRect
    var scale: CGFloat
    var designSize: NSSize
}

enum MenuPanelLayout {
    static let size = NSSize(
        width: 560,
        height: panelHeight(
            cableItemCount: HardwareMenuLayout.maxCableItemCount,
            showsDisplayControl: true,
            showsAudioSection: true,
            showsColorPreset: true
        )
    )
    static let contentInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    static let cornerRadius: CGFloat = 22
    /// Keeps the original compact design, then shrinks it proportionally.
    static let designScale: CGFloat = 0.86
    static let minimumScale: CGFloat = 0.62
    static let screenMargin: CGFloat = 10
    static let verticalGap: CGFloat = 8

    static let outerSpacing: CGFloat = 12
    static let contentSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let sectionPadding: CGFloat = 10
    static let chartHeight: CGFloat = 96
    static let cableRowHeight: CGFloat = 90
    static let cableGridSpacing: CGFloat = 6
    static let controlButtonSize: CGFloat = 40
    static let controlsHeight = controlButtonSize
    static let controlRowSpacing: CGFloat = 6

    static let headerHeight: CGFloat = 28
    /// Title row + section spacing + vertical padding around section content.
    static let sectionChromeHeight: CGFloat = 44
    static let hardwareSectionHeight = chartHeight + sectionChromeHeight
    static let cableSectionHeight = cableRowHeight + sectionChromeHeight
    static let displaySectionHeight: CGFloat = 186
    static let displayPresetSectionHeight: CGFloat = 232
    static let audioRowHeight: CGFloat = 30
    static let audioRowSpacing: CGFloat = 6
    static let defaultAudioRowCount = 3
    static let audioSectionContentHeight = audioContentHeight(rowCount: defaultAudioRowCount)
    static let audioSectionHeight = audioSectionContentHeight + sectionChromeHeight
    static let wifiSectionContentHeight: CGFloat = 82
    static let wifiConnectedContentWidth: CGFloat = 370
    static let wifiSectionHeight = wifiSectionContentHeight + sectionChromeHeight

    static let standardContentHeight = contentHeight(
        cableItemCount: 1,
        showsDisplayControl: true,
        showsAudioSection: true,
        showsColorPreset: true
    )

    static func displaySectionHeight(showsColorPreset: Bool) -> CGFloat {
        showsColorPreset ? displayPresetSectionHeight : displaySectionHeight
    }

    static func cableSectionHeight(itemCount: Int) -> CGFloat {
        let listHeight = HardwareMenuLayout.cableListHeight(itemCount: itemCount)
        guard listHeight > 0 else { return 0 }
        return listHeight + sectionChromeHeight
    }

    static func audioContentHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return 116
    }

    static func contentHeight(
        cableItemCount: Int,
        showsDisplayControl: Bool,
        showsAudioSection: Bool = true,
        showsColorPreset: Bool = false,
        audioRowCount: Int = defaultAudioRowCount
    ) -> CGFloat {
        var height = headerHeight
            + outerSpacing
            + hardwareSectionHeight
            + contentSpacing
            + wifiSectionHeight
            + outerSpacing
            + controlsHeight

        let audioHeight = audioContentHeight(rowCount: audioRowCount)
        if showsAudioSection, audioHeight > 0 {
            height += contentSpacing + audioHeight + sectionChromeHeight
        }

        let visibleCableCount = min(max(0, cableItemCount), HardwareMenuLayout.maxCableItemCount)
        if visibleCableCount > 0 {
            height += contentSpacing + cableSectionHeight(itemCount: visibleCableCount)
        }

        if showsDisplayControl {
            height += contentSpacing + displaySectionHeight(
                showsColorPreset: showsColorPreset
            )
        }

        return height
    }

    static func panelHeight(
        cableItemCount: Int,
        showsDisplayControl: Bool,
        showsAudioSection: Bool = true,
        showsColorPreset: Bool = false,
        audioRowCount: Int = defaultAudioRowCount
    ) -> CGFloat {
        contentHeight(
            cableItemCount: cableItemCount,
            showsDisplayControl: showsDisplayControl,
            showsAudioSection: showsAudioSection,
            showsColorPreset: showsColorPreset,
            audioRowCount: audioRowCount
        )
            + contentInsets.top
            + contentInsets.bottom
    }

    static func panelSize(
        cableItemCount: Int,
        showsDisplayControl: Bool,
        showsAudioSection: Bool = true,
        showsColorPreset: Bool = false,
        audioRowCount: Int = defaultAudioRowCount
    ) -> NSSize {
        NSSize(
            width: size.width,
            height: panelHeight(
                cableItemCount: cableItemCount,
                showsDisplayControl: showsDisplayControl,
                showsAudioSection: showsAudioSection,
                showsColorPreset: showsColorPreset,
                audioRowCount: audioRowCount
            )
        )
    }

    static func panelFrame(
        preferredSize: NSSize,
        anchorFrame: NSRect,
        screens: [MenuPanelScreenGeometry]
    ) -> NSRect? {
        placement(
            preferredSize: preferredSize,
            anchorFrame: anchorFrame,
            screens: screens
        )?.frame
    }

    static func placement(
        preferredSize: NSSize,
        anchorFrame: NSRect,
        screens: [MenuPanelScreenGeometry]
    ) -> MenuPanelPlacement? {
        let anchorPoint = NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(anchorPoint) }) else {
            return nil
        }

        return placement(
            preferredSize: preferredSize,
            anchorFrame: anchorFrame,
            visibleFrame: screen.visibleFrame
        )
    }

    static func panelFrame(
        preferredSize: NSSize,
        anchorFrame: NSRect,
        visibleFrame: NSRect,
        margin: CGFloat = screenMargin,
        verticalOffset: CGFloat = verticalGap
    ) -> NSRect {
        placement(
            preferredSize: preferredSize,
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            margin: margin,
            verticalOffset: verticalOffset
        ).frame
    }

    static func placement(
        preferredSize: NSSize,
        anchorFrame: NSRect,
        visibleFrame: NSRect,
        margin: CGFloat = screenMargin,
        verticalOffset: CGFloat = verticalGap
    ) -> MenuPanelPlacement {
        let scale = presentationScale(
            preferredSize: preferredSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
        let size = scaledSize(preferredSize, scale: scale)

        let minimumX = visibleFrame.minX + margin
        let maximumX = max(minimumX, visibleFrame.maxX - size.width - margin)
        let proposedX = anchorFrame.midX - size.width / 2
        let originX = min(max(proposedX, minimumX), maximumX)

        let minimumY = visibleFrame.minY + margin
        // Pin the top edge to the menu-bar lower edge. Status-item frames can
        // report a stale Y on the first open, which previously shifted the panel
        // down into the desktop.
        let proposedY = visibleFrame.maxY - size.height - verticalOffset
        let originY = max(proposedY, minimumY)

        return MenuPanelPlacement(
            frame: NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            scale: scale,
            designSize: preferredSize
        )
    }

    static func presentationScale(
        preferredSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = screenMargin
    ) -> CGFloat {
        let availableWidth = max(1, visibleFrame.width - margin * 2)
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let widthScale = availableWidth / max(preferredSize.width, 1)
        let heightScale = availableHeight / max(preferredSize.height, 1)
        return min(max(min(designScale, widthScale, heightScale), minimumScale), designScale)
    }

    static func scaledSize(_ preferredSize: NSSize, scale: CGFloat) -> NSSize {
        NSSize(
            width: preferredSize.width * scale,
            height: preferredSize.height * scale
        )
    }

    static func scaledInsets(_ insets: NSEdgeInsets, scale: CGFloat) -> NSEdgeInsets {
        NSEdgeInsets(
            top: insets.top * scale,
            left: insets.left * scale,
            bottom: insets.bottom * scale,
            right: insets.right * scale
        )
    }

    static func isStableMenuBarAnchor(
        _ anchorFrame: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> Bool {
        guard anchorFrame.width >= 8, anchorFrame.height >= 8 else { return false }
        guard screenFrame.intersects(anchorFrame) else { return false }

        let menuBarHeight = max(22, screenFrame.maxY - visibleFrame.maxY)
        let strip = NSRect(
            x: screenFrame.minX,
            y: visibleFrame.maxY - 4,
            width: screenFrame.width,
            height: menuBarHeight + 8
        )
        return strip.intersects(anchorFrame)
    }
}
