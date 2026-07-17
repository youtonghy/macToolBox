import AppKit

enum MenuPanelLayout {
    static let size = NSSize(width: 560, height: 718)
    static let contentInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    static let cornerRadius: CGFloat = 22

    static let outerSpacing: CGFloat = 12
    static let contentSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let sectionPadding: CGFloat = 10
    static let chartHeight: CGFloat = 96
    static let cableRowHeight: CGFloat = 90
    static let cableGridSpacing: CGFloat = 6
    static let controlsHeight: CGFloat = 50
    static let controlRowSpacing: CGFloat = 6

    static let headerHeight: CGFloat = 52
    static let headerBadgesWidth: CGFloat = 260
    static let hardwareSectionHeight = chartHeight + 44
    static let cableSectionHeight = cableRowHeight + 44
    static let displaySectionHeight: CGFloat = 154

    static let standardContentHeight = headerHeight
        + outerSpacing
        + hardwareSectionHeight
        + contentSpacing
        + cableSectionHeight
        + contentSpacing
        + displaySectionHeight
        + outerSpacing
        + controlsHeight
}
