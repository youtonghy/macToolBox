import AppKit
import SwiftUI

class GlassHostingViewController<Content: View>: NSViewController {
    private let rootView: Content
    private var contentSize: NSSize
    private let contentInsets: NSEdgeInsets
    private var hostingController: NSHostingController<Content>?

    init(
        rootView: Content,
        contentSize: NSSize,
        contentInsets: NSEdgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    ) {
        self.rootView = rootView
        self.contentSize = contentSize
        self.contentInsets = contentInsets
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = contentSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = GlassContainerView(frame: NSRect(origin: .zero, size: contentSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (view as? GlassContainerView)?.refreshAppearance()

        let hostingController = NSHostingController(rootView: rootView)
        addChild(hostingController)

        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.wantsLayer = true
        hostedView.layer?.backgroundColor = NSColor.clear.cgColor

        view.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: contentInsets.left),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -contentInsets.right),
            hostedView.topAnchor.constraint(equalTo: view.topAnchor, constant: contentInsets.top),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -contentInsets.bottom)
        ])

        self.hostingController = hostingController
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }

    func updateContentSize(_ size: NSSize) {
        guard size != contentSize else { return }
        contentSize = size
        preferredContentSize = size
        if isViewLoaded {
            view.setFrameSize(size)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }
}

final class GlassContainerView: NSView {
    private let backgroundEffectView = NSVisualEffectView()
    private let glowEffectView = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let innerGlowLayer = CAShapeLayer()

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func layout() {
        super.layout()

        backgroundEffectView.frame = bounds
        glowEffectView.frame = bounds
        tintLayer.frame = bounds

        let outerPath = roundedPath(
            in: bounds.insetBy(dx: 0.5, dy: 0.5),
            radius: MenuPanelLayout.cornerRadius
        )
        borderLayer.path = outerPath.cgPath

        let innerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = roundedPath(
            in: innerRect,
            radius: MenuPanelLayout.cornerRadius - 2
        )
        highlightLayer.path = innerPath.cgPath

        let glowRect = bounds.insetBy(dx: 10, dy: 10)
        let glowPath = roundedPath(
            in: glowRect,
            radius: MenuPanelLayout.cornerRadius - 8
        )
        innerGlowLayer.path = glowPath.cgPath
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = MenuPanelLayout.cornerRadius
        layer?.masksToBounds = true
        layer?.shadowOpacity = 0

        glowEffectView.material = .hudWindow
        glowEffectView.blendingMode = .behindWindow
        glowEffectView.state = .active
        glowEffectView.alphaValue = 0.38
        glowEffectView.wantsLayer = true
        glowEffectView.layer?.cornerRadius = MenuPanelLayout.cornerRadius
        glowEffectView.layer?.masksToBounds = true

        backgroundEffectView.material = .popover
        backgroundEffectView.blendingMode = .behindWindow
        backgroundEffectView.state = .active
        backgroundEffectView.isEmphasized = true
        backgroundEffectView.wantsLayer = true
        backgroundEffectView.layer?.cornerRadius = MenuPanelLayout.cornerRadius
        backgroundEffectView.layer?.masksToBounds = true

        tintLayer.cornerRadius = MenuPanelLayout.cornerRadius
        tintLayer.cornerCurve = .continuous
        tintLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.16).cgColor

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1

        highlightLayer.fillColor = NSColor.clear.cgColor
        highlightLayer.lineWidth = 1

        innerGlowLayer.fillColor = NSColor.white.withAlphaComponent(0.04).cgColor
        innerGlowLayer.strokeColor = NSColor.clear.cgColor

        addSubview(glowEffectView)
        addSubview(backgroundEffectView)
        layer?.addSublayer(tintLayer)
        layer?.addSublayer(innerGlowLayer)
        layer?.addSublayer(borderLayer)
        layer?.addSublayer(highlightLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func updateLayer() {
        super.updateLayer()
        applyAppearance()
    }

    func refreshAppearance() {
        applyAppearance()
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        tintLayer.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.white.withAlphaComponent(0.20)).cgColor
        borderLayer.strokeColor = (isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.72)).cgColor
        highlightLayer.strokeColor = (isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.42)).cgColor
        innerGlowLayer.fillColor = (isDark
            ? NSColor.white.withAlphaComponent(0.03)
            : NSColor.white.withAlphaComponent(0.07)).cgColor
    }

    private func roundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        )
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }

        return path
    }
}
