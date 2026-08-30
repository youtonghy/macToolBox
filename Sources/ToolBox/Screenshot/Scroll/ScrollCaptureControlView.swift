import AppKit

@MainActor
final class ScrollCaptureControlController {
    var onRetry: () -> Void = {}
    var onManual: () -> Void = {}
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}

    private var panel: NSPanel?
    private let statusLabel = NSTextField(labelWithString: "准备滚动截图")
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let manualButton = NSButton(title: "手动", target: nil, action: nil)

    func show(avoiding roi: CGRect? = nil) {
        close()
        let finishButton = NSButton(title: "完成", target: self, action: #selector(finish))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        retryButton.target = self
        retryButton.action = #selector(retry)
        manualButton.target = self
        manualButton.action = #selector(manual)
        retryButton.isHidden = true
        for button in [retryButton, manualButton, finishButton, cancelButton] {
            button.bezelStyle = .rounded
        }
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .center
        let buttons = NSStackView(views: [retryButton, manualButton, finishButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [statusLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 310, height: 84),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = stack
        let panelSize = panel.frame.size
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        panel.setFrameOrigin(
            Self.placementOrigin(roi: roi, visibleFrames: visibleFrames, panelSize: panelSize)
        )
        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// Picks the panel origin on the screen containing the ROI, preferring
    /// corners that don't cover the ROI — the panel would otherwise intercept
    /// the auto-scroll events posted at the ROI center or the user's manual
    /// scrolling. Pure over its inputs for unit testing.
    ///
    /// - Without an ROI (or no matching screen), centers on the first screen.
    /// - Corner order: top-right, bottom-right, bottom-left, top-left, with a
    ///   12 pt avoidance margin; if every corner intersects the ROI, falls
    ///   back to the top-right corner of the ROI's screen.
    static func placementOrigin(
        roi: CGRect?,
        visibleFrames: [CGRect],
        panelSize: NSSize
    ) -> CGPoint {
        guard let first = visibleFrames.first else { return .zero }
        let margin: CGFloat = 16
        let avoidance: CGFloat = 12
        let candidates: (CGRect) -> [CGPoint] = { visible in
            [
                CGPoint(x: visible.maxX - panelSize.width - margin, y: visible.maxY - panelSize.height - margin),
                CGPoint(x: visible.maxX - panelSize.width - margin, y: visible.minY + margin),
                CGPoint(x: visible.minX + margin, y: visible.minY + margin),
                CGPoint(x: visible.minX + margin, y: visible.maxY - panelSize.height - margin),
            ]
        }
        guard let roi else {
            return CGPoint(
                x: first.midX - panelSize.width / 2,
                y: first.midY - panelSize.height / 2
            )
        }
        let screen = visibleFrames.first { $0.contains(CGPoint(x: roi.midX, y: roi.midY)) } ?? first
        let origins = candidates(screen)
        for origin in origins {
            let frame = CGRect(origin: origin, size: panelSize).insetBy(dx: -avoidance, dy: -avoidance)
            if !frame.intersects(roi) {
                return origin
            }
        }
        return origins[0]
    }

    func update(state: ScrollCaptureState, mode: ScrollCaptureMode, height: Int) {
        retryButton.isHidden = true
        manualButton.isEnabled = mode == .automatic
        switch state {
        case .acquiringTarget: statusLabel.stringValue = "正在确认目标"
        case .capturingInitialFrame: statusLabel.stringValue = "正在捕获首帧"
        case .scrolling: statusLabel.stringValue = mode == .automatic ? "正在自动滚动" : "等待手动滚动"
        case .waitingForStability: statusLabel.stringValue = "正在等待画面稳定"
        case .matchingOverlap, .appending: statusLabel.stringValue = "已捕获 \(height) px"
        case .paused(.lowConfidence):
            statusLabel.stringValue = "画面匹配不确定"
            retryButton.isHidden = false
        case .paused(.reverseMovement):
            statusLabel.stringValue = "检测到反向滚动"
            retryButton.isHidden = false
        case .paused(.unstableFrame):
            statusLabel.stringValue = "画面持续变化，等待稳定"
            retryButton.isHidden = false
        default: break
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func retry() { onRetry() }
    @objc private func manual() { onManual() }
    @objc private func finish() { onFinish() }
    @objc private func cancel() { onCancel() }
}
