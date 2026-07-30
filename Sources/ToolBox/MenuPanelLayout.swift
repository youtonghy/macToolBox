import AppKit

struct MenuPanelScreenGeometry {
    let frame: NSRect
    let visibleFrame: NSRect
}

enum MenuPanelLayout {
    static let size = NSSize(
        width: 560,
        height: panelHeight(
            cableItemCount: HardwareMenuLayout.maxCableItemCount,
            showsDisplayControl: true,
            showsAudioSection: true
        )
    )
    static let contentInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    static let cornerRadius: CGFloat = 22

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
    static let displaySectionHeight: CGFloat = 154
    static let audioSectionContentHeight: CGFloat = 112
    static let audioSectionHeight = audioSectionContentHeight + sectionChromeHeight

    static let standardContentHeight = contentHeight(
        cableItemCount: 1,
        showsDisplayControl: true,
        showsAudioSection: true
    )

    static func cableSectionHeight(itemCount: Int) -> CGFloat {
        let listHeight = HardwareMenuLayout.cableListHeight(itemCount: itemCount)
        guard listHeight > 0 else { return 0 }
        return listHeight + sectionChromeHeight
    }

    static func contentHeight(
        cableItemCount: Int,
        showsDisplayControl: Bool,
        showsAudioSection: Bool = true
    ) -> CGFloat {
        var height = headerHeight
            + outerSpacing
            + hardwareSectionHeight
            + outerSpacing
            + controlsHeight

        if showsAudioSection {
            height += contentSpacing + audioSectionHeight
        }

        let visibleCableCount = min(max(0, cableItemCount), HardwareMenuLayout.maxCableItemCount)
        if visibleCableCount > 0 {
            height += contentSpacing + cableSectionHeight(itemCount: visibleCableCount)
        }

        if showsDisplayControl {
            height += contentSpacing + displaySectionHeight
        }

        return height
    }

    static func panelHeight(
        cableItemCount: Int,
        showsDisplayControl: Bool,
        showsAudioSection: Bool = true
    ) -> CGFloat {
        contentHeight(
            cableItemCount: cableItemCount,
            showsDisplayControl: showsDisplayControl,
            showsAudioSection: showsAudioSection
        )
            + contentInsets.top
            + contentInsets.bottom
    }

    static func panelSize(
        cableItemCount: Int,
        showsDisplayControl: Bool,
        showsAudioSection: Bool = true
    ) -> NSSize {
        NSSize(
            width: size.width,
            height: panelHeight(
                cableItemCount: cableItemCount,
                showsDisplayControl: showsDisplayControl,
                showsAudioSection: showsAudioSection
            )
        )
    }

    static func panelFrame(
        preferredSize: NSSize,
        anchorFrame: NSRect,
        screens: [MenuPanelScreenGeometry]
    ) -> NSRect? {
        let anchorPoint = NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(anchorPoint) }) else {
            return nil
        }

        return panelFrame(
            preferredSize: preferredSize,
            anchorFrame: anchorFrame,
            visibleFrame: screen.visibleFrame
        )
    }

    static func panelFrame(
        preferredSize: NSSize,
        anchorFrame: NSRect,
        visibleFrame: NSRect,
        margin: CGFloat = 10,
        verticalOffset: CGFloat = 8
    ) -> NSRect {
        let availableWidth = max(0, visibleFrame.width - margin * 2)
        let availableHeight = max(0, visibleFrame.height - margin * 2)
        let size = NSSize(
            width: min(max(0, preferredSize.width), availableWidth),
            height: min(max(0, preferredSize.height), availableHeight)
        )

        let minimumX = visibleFrame.minX + margin
        let maximumX = max(minimumX, visibleFrame.maxX - size.width - margin)
        let proposedX = anchorFrame.midX - size.width / 2
        let originX = min(max(proposedX, minimumX), maximumX)

        let minimumY = visibleFrame.minY + margin
        let maximumY = max(minimumY, visibleFrame.maxY - size.height - margin)
        let proposedY = anchorFrame.minY - size.height - verticalOffset
        let originY = min(max(proposedY, minimumY), maximumY)

        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }
}
