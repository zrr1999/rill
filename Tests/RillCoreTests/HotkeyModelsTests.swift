import XCTest
@testable import RillCore

final class HotkeyModelsTests: XCTestCase {
    func testKeyboardShortcutStorageRoundTrip() {
        let shortcut = KeyboardShortcut(
            keyCode: 8,
            modifiers: [.command, .shift]
        )

        let restored = KeyboardShortcut(storageString: shortcut.storageString)

        XCTAssertEqual(restored, shortcut)
    }

    func testHotkeyBindingDescriptorDefaultsToDoubleCommand() {
        XCTAssertEqual(HotkeyBindingDescriptor(storageString: nil), .doubleCommand)
        XCTAssertEqual(HotkeyBindingDescriptor(storageString: "unknown"), .doubleCommand)
    }

    func testGlobalHotkeyPolicyRejectsDangerousSystemAndApplicationShortcuts() {
        let commandQ = KeyboardShortcut(keyCode: 12, modifiers: [.command])
        let commandW = KeyboardShortcut(keyCode: 13, modifiers: [.command])
        let commandC = KeyboardShortcut(keyCode: 8, modifiers: [.command])
        let lockScreen = KeyboardShortcut(keyCode: 12, modifiers: [.control, .command])

        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: commandQ), .systemReserved)
        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: commandW), .systemReserved)
        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: commandC), .standardApplicationShortcut)
        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: lockScreen), .systemReserved)
    }

    func testGlobalHotkeyPolicyRejectsTypingAndRillReservedShortcuts() {
        let shiftedLetter = KeyboardShortcut(keyCode: 0, modifiers: [.shift])
        let optionLetter = KeyboardShortcut(keyCode: 8, modifiers: [.option])
        let controlLetter = KeyboardShortcut(keyCode: 8, modifiers: [.control])
        let pushToTalk = KeyboardShortcut(keyCode: 49, modifiers: [.control, .option, .shift])

        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: shiftedLetter), .modifierOnlyTyping)
        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: optionLetter), .modifierOnlyTyping)
        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: controlLetter), .modifierOnlyTyping)
        XCTAssertEqual(GlobalHotkeyPolicy.rejection(for: pushToTalk), .rillReserved)
    }

    func testGlobalHotkeyPolicyAcceptsDistinctMultiModifierShortcut() {
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])

        XCTAssertTrue(GlobalHotkeyPolicy.accepts(shortcut))
        XCTAssertEqual(
            HotkeyBindingDescriptor(storageString: shortcut.storageString),
            .keyboardShortcut(shortcut)
        )
    }

    func testHotkeyBindingDescriptorDiscardsUnsafePersistedShortcut() {
        let commandQ = KeyboardShortcut(keyCode: 12, modifiers: [.command])

        XCTAssertEqual(
            HotkeyBindingDescriptor(storageString: commandQ.storageString),
            .doubleCommand
        )
    }
}
