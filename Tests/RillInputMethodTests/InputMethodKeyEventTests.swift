import AppKit
import Carbon
import IOKit.hidsystem
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
    (kVK_Shift, Int32(0xffe1), NSEvent.ModifierFlags.shift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK),
    (kVK_RightShift, 0xffe2, .shift, NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK),
    (kVK_Control, 0xffe3, .control, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK),
    (kVK_RightControl, 0xffe4, .control, NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK),
    (kVK_Option, 0xffe9, .option, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK),
    (kVK_RightOption, 0xffea, .option, NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK),
    (kVK_Command, 0xffeb, .command, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK),
    (kVK_RightCommand, 0xffec, .command, NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK),
  ])
  func releasingOneModifierWhileItsOtherSideIsHeldKeepsTheRelease(
    _ input: (keyCode: Int, symbol: Int32, flag: NSEvent.ModifierFlags, side: Int32, otherSide: Int32)
  ) throws {
    let bothHeld = input.flag.union(.init(rawValue: UInt(input.side | input.otherSide)))
    let down = try translated(.flagsChanged, keyCode: input.keyCode, flags: bothHeld)
    #expect(down.key == input.symbol)
    #expect(down.modifiers & (1 << 30) == 0)
    let otherHeld = input.flag.union(.init(rawValue: UInt(input.otherSide)))
    let up = try translated(.flagsChanged, keyCode: input.keyCode, flags: otherHeld)
    #expect(up.key == input.symbol)
    #expect(up.modifiers == down.modifiers | (1 << 30))
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

  @Test(
    arguments: [
      (kVK_ANSI_Slash, "/", "?"),
      (kVK_ANSI_1, "1", "!"),
      (kVK_ANSI_2, "2", "@"),
      (kVK_ANSI_3, "3", "#"),
      (kVK_ANSI_4, "4", "$"),
      (kVK_ANSI_5, "5", "%"),
      (kVK_ANSI_6, "6", "^"),
      (kVK_ANSI_7, "7", "&"),
      (kVK_ANSI_8, "8", "*"),
      (kVK_ANSI_9, "9", "("),
      (kVK_ANSI_0, "0", ")"),
      (kVK_ANSI_Minus, "-", "_"),
      (kVK_ANSI_Equal, "=", "+"),
      (kVK_ANSI_LeftBracket, "[", "{"),
      (kVK_ANSI_RightBracket, "]", "}"),
      (kVK_ANSI_Backslash, "\\", "|"),
      (kVK_ANSI_Semicolon, ";", ":"),
      (kVK_ANSI_Quote, "'", "\""),
      (kVK_ANSI_Comma, ",", "<"),
      (kVK_ANSI_Period, ".", ">"),
      (kVK_ANSI_Grave, "`", "~"),
      (kVK_ANSI_Minus, "ß", "?"),
    ], [NSEvent.ModifierFlags.shift, [.shift, .capsLock]])
  func shiftedSymbolsUseTheKeyboardLayoutCharacters(
    _ input: (keyCode: Int, unmodified: String, shifted: String),
    flags: NSEvent.ModifierFlags
  ) throws {
    let key = try translated(
      .keyDown, keyCode: input.keyCode, flags: flags, characters: input.shifted,
      charactersIgnoringModifiers: input.unmodified)
    #expect(key.key == Int32(try #require(input.shifted.unicodeScalars.first).value))
    #expect(key.modifiers == (flags.contains(.capsLock) ? 3 : 1))
  }

  @Test(arguments: [
    (NSEvent.ModifierFlags.control, "\u{1f}", "/", Int32(4)),
    (NSEvent.ModifierFlags([.shift, .control]), "\u{1f}", "?", 5),
    (NSEvent.ModifierFlags([.shift, .option]), "¿", "?", 9),
    (NSEvent.ModifierFlags([.shift, .command]), "?", "/", Int32((1 << 26) | 1)),
  ])
  func shortcutCharactersKeepTheirUnmodifiedKeySymbols(
    _ input: (flags: NSEvent.ModifierFlags, characters: String, unmodified: String, mask: Int32)
  ) throws {
    let key = try translated(
      .keyDown, keyCode: kVK_ANSI_Slash, flags: input.flags, characters: input.characters,
      charactersIgnoringModifiers: input.unmodified)
    #expect(key.key == Int32(try #require(input.unmodified.unicodeScalars.first).value))
    #expect(key.modifiers == input.mask)
  }

  private func translated(
    _ type: NSEvent.EventType, keyCode: Int,
    flags: NSEvent.ModifierFlags = [], characters: String = "",
    charactersIgnoringModifiers: String? = nil
  ) throws -> InputMethodKeyEvent {
    let event = try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: false, keyCode: UInt16(keyCode)))
    return try #require(InputMethodKeyEvent(event))
  }
}
