import AppKit
import Carbon
import IOKit.hidsystem

struct InputMethodKeyEvent {
  let key: Int32
  let modifiers: Int32

  init?(_ event: NSEvent) {
    let flags = event.modifierFlags
    var modifiers: Int32 = 0
    if flags.contains(.shift) { modifiers |= 1 }
    if flags.contains(.capsLock) { modifiers |= 2 }
    if flags.contains(.control) { modifiers |= 4 }
    if flags.contains(.option) { modifiers |= 8 }
    if flags.contains(.command) { modifiers |= 1 << 26 }

    switch event.type {
    case .flagsChanged:
      if event.keyCode == kVK_CapsLock {
        key = 0xffe5
        // Rime expects the lock state before the transition; AppKit reports it after.
        modifiers ^= 2
      } else {
        let modifier: (key: Int32, flag: NSEvent.ModifierFlags, side: Int32, otherSide: Int32)
        switch Int(event.keyCode) {
        case kVK_Shift: modifier = (0xffe1, .shift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK)
        case kVK_RightShift: modifier = (0xffe2, .shift, NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK)
        case kVK_Control: modifier = (0xffe3, .control, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK)
        case kVK_RightControl: modifier = (0xffe4, .control, NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK)
        case kVK_Option: modifier = (0xffe9, .option, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK)
        case kVK_RightOption: modifier = (0xffea, .option, NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK)
        case kVK_Command: modifier = (0xffeb, .command, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK)
        case kVK_RightCommand: modifier = (0xffec, .command, NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK)
        default: return nil
        }
        key = modifier.key
        let deviceFlags = flags.rawValue & UInt(modifier.side | modifier.otherSide)
        // Keep supporting event sources that omit device-specific flags.
        let isPressed =
          deviceFlags == 0
          ? flags.contains(modifier.flag)
          : deviceFlags & UInt(modifier.side) != 0
        if !isPressed { modifiers |= 1 << 30 }
      }
    case .keyDown:
      // IMK can leave shifted symbols unmodified in charactersIgnoringModifiers.
      let characters =
        flags.intersection([.control, .option, .command]).isEmpty
        ? event.characters ?? event.charactersIgnoringModifiers
        : event.charactersIgnoringModifiers
      if let special = Self.specialKeys[event.keyCode] {
        key = special
      } else if let character = characters?.unicodeScalars.first {
        var value = character.value
        if (97...122).contains(value), flags.contains(.shift) != flags.contains(.capsLock) {
          value -= 32
        } else if (65...90).contains(value), flags.contains([.shift, .capsLock]) {
          value += 32
        }
        key = Int32(value < 256 ? value : value | 0x0100_0000)
      } else {
        return nil
      }
    default:
      return nil
    }
    self.modifiers = modifiers
  }

  private static let specialKeys: [UInt16: Int32] = [
    36: 0xff0d, 76: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b,
    117: 0xffff, 123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52,
    115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
  ]
}
