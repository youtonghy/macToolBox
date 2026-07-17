import AppKit
import SwiftUI

private func usesDarkAppearance(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

private func glassFillColor(for appearance: NSAppearance) -> NSColor {
    usesDarkAppearance(appearance)
        ? NSColor.black.withAlphaComponent(0.18)
        : NSColor.white.withAlphaComponent(0.34)
}

private func glassStrokeColor(for appearance: NSAppearance) -> NSColor {
    usesDarkAppearance(appearance)
        ? NSColor.white.withAlphaComponent(0.16)
        : NSColor.white.withAlphaComponent(0.58)
}

private func glassSeparatorColor(for appearance: NSAppearance) -> NSColor {
    usesDarkAppearance(appearance)
        ? NSColor.white.withAlphaComponent(0.12)
        : NSColor.black.withAlphaComponent(0.10)
}

private func drawGlassPanel(in rect: NSRect, cornerRadius: CGFloat, appearance: NSAppearance) {
    let panel = NSBezierPath(
        roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    glassFillColor(for: appearance).setFill()
    panel.fill()

    glassStrokeColor(for: appearance).setStroke()
    panel.lineWidth = 1
    panel.stroke()
}

struct PowerChartRepresentable: NSViewRepresentable {
    var title: String
    var samples: [PowerHistoryPoint]
    var displayText: String
    var isAverageMode: Bool
    var accentColor: NSColor
    var onToggle: () -> Void

    func makeNSView(context: Context) -> PowerChartNSView {
        let view = PowerChartNSView()
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ nsView: PowerChartNSView, context: Context) {
        nsView.title = title
        nsView.samples = samples
        nsView.displayText = displayText
        nsView.isAverageMode = isAverageMode
        nsView.accentColor = accentColor
        nsView.onToggle = onToggle
        nsView.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PowerChartNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: MenuPanelLayout.chartHeight)
    }
}

final class PowerChartNSView: NSView {
    var title: String = ""
    var samples: [PowerHistoryPoint] = [] {
        didSet { needsDisplay = true }
    }
    var displayText: String = "N/A" {
        didSet { needsDisplay = true }
    }
    var isAverageMode: Bool = false {
        didSet { needsDisplay = true }
    }
    var accentColor: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }
    var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        drawGlassPanel(in: bounds, cornerRadius: 10, appearance: effectiveAppearance)

        let titleRect = NSRect(x: 12, y: 10, width: max(0, bounds.width - 120), height: 18)
        drawText(
            title,
            in: titleRect,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor,
            alignment: .left
        )

        let valueRect = NSRect(x: max(12, bounds.width - 102), y: 8, width: 90, height: 22)
        drawText(
            displayText,
            in: valueRect,
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            color: accentColor,
            alignment: .right
        )

        if isAverageMode {
            let badgeRect = NSRect(x: valueRect.minX, y: valueRect.maxY + 2, width: valueRect.width, height: 2)
            accentColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 1, yRadius: 1).fill()
        }

        let chartRect = NSRect(
            x: 12,
            y: 40,
            width: max(0, bounds.width - 24),
            height: max(0, bounds.height - 50)
        )
        drawChart(in: chartRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if valueHitRect(in: bounds).contains(point) {
            onToggle?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(valueHitRect(in: bounds), cursor: .pointingHand)
    }

    private func valueHitRect(in bounds: NSRect) -> NSRect {
        NSRect(x: max(12, bounds.width - 106), y: 6, width: 94, height: 28)
    }

    private func drawChart(in rect: NSRect) {
        let valid = samples.compactMap { sample -> (Date, Double)? in
            guard let watts = sample.watts else { return nil }
            return (sample.timestamp, watts)
        }

        let gridColor = glassSeparatorColor(for: effectiveAppearance)
        let maxValue = max(1.0, valid.map(\.1).max() ?? 1.0)
        let averageValue = valid.isEmpty ? nil : valid.map(\.1).reduce(0, +) / Double(valid.count)

        let insetRect = rect.insetBy(dx: 0, dy: 0)
        gridColor.setStroke()
        for fraction in [0.25, 0.5, 0.75] {
            let y = insetRect.maxY - insetRect.height * fraction
            let line = NSBezierPath()
            line.move(to: NSPoint(x: insetRect.minX, y: y))
            line.line(to: NSPoint(x: insetRect.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
        }

        guard !valid.isEmpty else {
            return
        }

        let start = valid.first!.0
        let end = valid.last!.0
        let span = max(end.timeIntervalSince(start), 1)

        let path = NSBezierPath()
        path.lineWidth = 2.2
        accentColor.setStroke()

        for (index, sample) in valid.enumerated() {
            let xProgress = CGFloat(sample.0.timeIntervalSince(start) / span)
            let normalized = CGFloat(sample.1 / maxValue)
            let point = NSPoint(
                x: insetRect.minX + insetRect.width * xProgress,
                y: insetRect.maxY - insetRect.height * normalized
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.stroke()

        if let latest = valid.last?.1 {
            let x = insetRect.maxX
            let y = insetRect.maxY - insetRect.height * CGFloat(latest / maxValue)
            let dot = NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
            accentColor.setFill()
            dot.fill()
        }

        if isAverageMode, let averageValue {
            let normalized = CGFloat(averageValue / maxValue)
            let y = insetRect.maxY - insetRect.height * normalized
            let dash = NSBezierPath()
            dash.lineWidth = 1
            dash.setLineDash([3, 3], count: 2, phase: 0)
            accentColor.withAlphaComponent(0.65).setStroke()
            dash.move(to: NSPoint(x: insetRect.minX, y: y))
            dash.line(to: NSPoint(x: insetRect.maxX, y: y))
            dash.stroke()
        }
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]

        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
