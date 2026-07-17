import AppKit

enum MenuPanelLayout {
    static let size = NSSize(
        width: 560,
        height: panelHeight(
            cableItemCount: HardwareMenuLayout.maxCableItemCount,
            showsDisplayControl: true
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

    static let standardContentHeight = contentHeight(
        cableItemCount: 1,
        showsDisplayControl: true
    )

    static func cableSectionHeight(itemCount: Int) -> CGFloat {
        let listHeight = HardwareMenuLayout.cableListHeight(itemCount: itemCount)
        guard listHeight > 0 else { return 0 }
        return listHeight + sectionChromeHeight
    }

    static func contentHeight(
        cableItemCount: Int,
        showsDisplayControl: Bool
    ) -> CGFloat {
        var height = headerHeight
            + outerSpacing
            + hardwareSectionHeight
            + outerSpacing
            + controlsHeight

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
        showsDisplayControl: Bool
    ) -> CGFloat {
        contentHeight(
            cableItemCount: cableItemCount,
            showsDisplayControl: showsDisplayControl
        )
            + contentInsets.top
            + contentInsets.bottom
    }

    static func panelSize(
        cableItemCount: Int,
        showsDisplayControl: Bool
    ) -> NSSize {
        NSSize(
            width: size.width,
            height: panelHeight(
                cableItemCount: cableItemCount,
                showsDisplayControl: showsDisplayControl
            )
        )
    }
}
