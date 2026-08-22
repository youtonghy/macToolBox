import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ToolBoxCore

final class ShortcutRecorderTests: XCTestCase {
    func testEscapeCancelsRecording() {
        XCTAssertEqual(
            ShortcutRecorderEventParser.parse(
                keyCode: UInt16(kVK_Escape),
                modifierFlags: []
            ),
            .cancel
        )
    }

    func testKeyWithoutSupportedModifierIsInvalid() {
        XCTAssertEqual(
            ShortcutRecorderEventParser.parse(
                keyCode: UInt16(kVK_ANSI_S),
                modifierFlags: [.capsLock]
            ),
            .invalid
        )
    }

    func testModifiedEscapeCanBeRecorded() {
        XCTAssertEqual(
            ShortcutRecorderEventParser.parse(
                keyCode: UInt16(kVK_Escape),
                modifierFlags: [.control, .option, .command]
            ),
            .capture(ShortcutBinding(
                keyCode: UInt32(kVK_Escape),
                modifiers: [.control, .option, .command]
            ))
        )
    }

    func testSupportedModifiersProduceCarbonBinding() {
        XCTAssertEqual(
            ShortcutRecorderEventParser.parse(
                keyCode: UInt16(kVK_ANSI_S),
                modifierFlags: [.control, .option, .shift, .capsLock]
            ),
            .capture(ShortcutBinding(
                keyCode: UInt32(kVK_ANSI_S),
                modifiers: [.control, .option, .shift]
            ))
        )
    }

    func testDefaultBindingsHaveStableDisplayLabels() {
        XCTAssertEqual(ShortcutRule.defaults[0].binding.displayText, "⌃⌥S")
        XCTAssertEqual(ShortcutRule.defaults[1].binding.displayText, "⌃⌥⌘Esc")
    }
}
