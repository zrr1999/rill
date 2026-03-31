import XCTest
@testable import VoxTypeCore

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
}
