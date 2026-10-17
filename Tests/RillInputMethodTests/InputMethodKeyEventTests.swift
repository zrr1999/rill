import AppKit
import Carbon
import Testing

@testable import RillInputMethodKit

@MainActor
struct InputMethodKeyEventTests {
  @Test func capsLockReportsTheStateBeforeEachToggle() throws {
    let on = try translated(.flagsChanged, keyCode: kVK_CapsLock, flags: .capsLock)
    #expect(on.key == 0xffe5)
    #expect(on.modifiers == 0)
    let off = try translated(.flagsChanged, keyCode: kVK_CapsLock)
    #expect(off.key == 0xffe5)
    #expect(off.modifiers == 2)
  }

  @Test(arguments: [
    (kVK_Shift, Int32(0xffe1), NSEvent.ModifierFlags.shift, Int32(1)),
    (kVK_RightShift, 0xffe2, .shift, 1),
    (kVK_Control, 0xffe3, .control, 4),
    (kVK_RightControl, 0xffe4, .control, 4),
    (kVK_Option, 0xffe9, .option, 8),
    (kVK_RightOption, 0xffea, .option, 8),
    (kVK_Command, 0xffeb, .command, 1 << 26),
    (kVK_RightCommand, 0xffec, .command, 1 << 26),
  ])
  func modifierPressesAndReleasesPreserveTheirSide(
    _ input: (keyCode: Int, symbol: Int32, flag: NSEvent.ModifierFlags, mask: Int32)
  ) throws {
    let down = try translated(.flagsChanged, keyCode: input.keyCode, flags: input.flag)
    #expect(down.key == input.symbol)
    #expect(down.modifiers == input.mask)
    let up = try translated(.flagsChanged, keyCode: input.keyCode)
    #expect(up.key == input.symbol)
    #expect(up.modifiers == 1 << 30)
  }

  @Test(arguments: [
    (NSEvent.ModifierFlags(), "a", Int32(97)),
    (NSEvent.ModifierFlags(), "A", 65),
    (.shift, "A", 65),
    (.shift, "a", 65),
    (.capsLock, "a", 65),
    (NSEvent.ModifierFlags([.shift, .capsLock]), "A", 97),
  ])
  func englishLettersReflectShiftAndCapsLock(
    _ input: (flags: NSEvent.ModifierFlags, characters: String, symbol: Int32)
  ) throws {
    let key = try translated(
      .keyDown, keyCode: kVK_ANSI_A, flags: input.flags, characters: input.characters)
    #expect(key.key == input.symbol)
  }

  @Test func shiftedPunctuationAndNavigationKeepTheirKeySymbols() throws {
    let punctuation = try translated(
      .keyDown, keyCode: kVK_ANSI_1, flags: .shift, characters: "!")
    #expect(punctuation.key == 33)
    #expect(punctuation.modifiers == 1)
    let arrow = try translated(.keyDown, keyCode: kVK_LeftArrow, flags: .control)
    #expect(arrow.key == 0xff51)
    #expect(arrow.modifiers == 4)
  }

  private func translated(
    _ type: NSEvent.EventType, keyCode: Int,
    flags: NSEvent.ModifierFlags = [], characters: String = ""
  ) throws -> InputMethodKeyEvent {
    let event = try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)))
    return try #require(InputMethodKeyEvent(event))
  }
}
