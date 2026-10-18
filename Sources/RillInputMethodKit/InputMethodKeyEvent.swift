import AppKit
import Carbon

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
        let modifier: (key: Int32, flag: NSEvent.ModifierFlags)
        switch Int(event.keyCode) {
        case kVK_Shift: modifier = (0xffe1, .shift)
        case kVK_RightShift: modifier = (0xffe2, .shift)
        case kVK_Control: modifier = (0xffe3, .control)
        case kVK_RightControl: modifier = (0xffe4, .control)
        case kVK_Option: modifier = (0xffe9, .option)
        case kVK_RightOption: modifier = (0xffea, .option)
        case kVK_Command: modifier = (0xffeb, .command)
        case kVK_RightCommand: modifier = (0xffec, .command)
        default: return nil
        }
        key = modifier.key
        if !flags.contains(modifier.flag) { modifiers |= 1 << 30 }
      }
    case .keyDown:
      if let special = Self.specialKeys[event.keyCode] {
        key = special
      } else if let character = event.charactersIgnoringModifiers?.unicodeScalars.first {
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
