import AppKit

/// Big, centered, white monospaced countdown digit on a black background.
final class CountdownView: NSView {

    private let label = NSTextField(labelWithString: "60")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        label.font = .monospacedSystemFont(ofSize: 220, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setNumber(_ n: Int) {
        label.stringValue = "\(max(0, n))"
    }
}
