import Carbon.HIToolbox

enum ShortcutActionID: String, Codable, CaseIterable, Sendable {
    case captureRegion
    case screenWipeExit
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let command = Self(rawValue: UInt32(cmdKey))
    static let option = Self(rawValue: UInt32(optionKey))
    static let control = Self(rawValue: UInt32(controlKey))
    static let shift = Self(rawValue: UInt32(shiftKey))
}

struct ShortcutBinding: Codable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: ShortcutModifiers
}

struct ShortcutRule: Codable, Equatable, Sendable {
    let id: ShortcutActionID
    let binding: ShortcutBinding
    var isEnabled: Bool

    static let defaults = [
        ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(
                keyCode: UInt32(kVK_ANSI_S),
                modifiers: [.control, .option]
            ),
            isEnabled: true
        ),
        ShortcutRule(
            id: .screenWipeExit,
            binding: ShortcutBinding(
                keyCode: UInt32(kVK_Escape),
                modifiers: [.control, .option, .command]
            ),
            isEnabled: true
        ),
    ]
}
