import AppKit
import Carbon.HIToolbox
import SwiftUI

enum ShortcutRecorderResult: Equatable {
    case capture(ShortcutBinding)
    case cancel
    case invalid
}

enum ShortcutRecorderEventParser {
    static func parse(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutRecorderResult {
        var modifiers: ShortcutModifiers = []
        if modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifierFlags.contains(.option) { modifiers.insert(.option) }
        if modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if modifierFlags.contains(.command) { modifiers.insert(.command) }
        if keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            return .cancel
        }
        guard !modifiers.isEmpty else { return .invalid }

        return .capture(ShortcutBinding(
            keyCode: UInt32(keyCode),
            modifiers: modifiers
        ))
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (ShortcutBinding) -> Void
    let onInvalid: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        ShortcutRecorderNSView(frame: .zero)
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        let recording = _isRecording
        nsView.onResult = { result in
            switch result {
            case let .capture(binding):
                onCapture(binding)
            case .invalid:
                onInvalid()
            case .cancel:
                break
            }
            recording.wrappedValue = false
        }

        if isRecording {
            nsView.beginRecording()
        } else {
            nsView.endRecording()
        }
    }

    static func dismantleNSView(
        _ nsView: ShortcutRecorderNSView,
        coordinator: Void
    ) {
        nsView.onResult = nil
        nsView.endRecording()
    }
}

final class ShortcutRecorderNSView: NSView {
    var onResult: ((ShortcutRecorderResult) -> Void)?

    private(set) var isRecording = false
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { isRecording }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        previousResponder = window?.firstResponder
        focusWhenAttached()
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        guard window?.firstResponder === self else {
            previousResponder = nil
            return
        }
        window?.makeFirstResponder(previousResponder)
        previousResponder = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isRecording {
            focusWhenAttached()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        consume(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        consume(event)
        return true
    }

    private func focusWhenAttached() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    private func consume(_ event: NSEvent) {
        let result = ShortcutRecorderEventParser.parse(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        )
        endRecording()
        onResult?(result)
    }
}

extension ShortcutBinding {
    var displayText: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyLabel(for: keyCode)
    }

    private static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_Grave: "`"
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Slash: "/"
        case kVK_Escape: "Esc"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Space: "Space"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "⌦"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: "Key \(keyCode)"
        }
    }
}
