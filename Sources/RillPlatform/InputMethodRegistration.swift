import Carbon
import Foundation
import RillInputMethodContracts

enum InputMethodRegistrationError: LocalizedError {
  case registrationFailed(OSStatus)
  case unavailable
  case enableFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .registrationFailed(let status):
      "组件已保存，但系统注册失败（\(status)）。请重试修复安装。"
    case .unavailable:
      "组件已保存，但系统尚未识别 Rill 输入源。请重试修复安装；仍未出现时，注销并重新登录后重试。"
    case .enableFailed(let status):
      "未能添加 Rill 输入源（\(status)）。请在系统输入法设置中添加 Rill。"
    }
  }
}

@MainActor
enum InputMethodRegistration {
  static func state() -> InputMethodInstallationState {
    let sources = sources()
    guard
      let parent = sources.first(where: {
        property($0, kTISPropertyInputSourceID) as? String == InputMethodPaths.bundleIdentifier
      }),
      let mode = sources.first(where: {
        property($0, kTISPropertyInputSourceID) as? String == InputMethodPaths.inputSourceIdentifier
          && property($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true
      })
    else { return .needsRepair }
    return state(
      parentEnabled: property(parent, kTISPropertyInputSourceIsEnabled) as? Bool == true,
      modeEnabled: property(mode, kTISPropertyInputSourceIsEnabled) as? Bool == true,
      modeSelected: property(mode, kTISPropertyInputSourceIsSelected) as? Bool == true)
  }

  static func state(
    parentEnabled: Bool, modeEnabled: Bool, modeSelected: Bool
  ) -> InputMethodInstallationState {
    // A default-enabled mode is not available until its parent method is enabled.
    guard parentEnabled, modeEnabled else { return .registered }
    return modeSelected ? .selected : .enabled
  }

  static func register(
    _ application: URL,
    registerSource: (URL) -> OSStatus = { TISRegisterInputSource($0 as CFURL) },
    queryState: () -> InputMethodInstallationState = { state() }
  ) throws {
    let result = registerSource(application)
    guard result == noErr else { throw InputMethodRegistrationError.registrationFailed(result) }
    switch queryState() {
    case .registered, .enabled, .selected: break
    case .notInstalled, .needsRepair: throw InputMethodRegistrationError.unavailable
    }
  }

  static func enable() throws {
    let sources = sources()
    // TIS requires the parent method to be enabled before its selectable mode.
    for identifier in [InputMethodPaths.bundleIdentifier, InputMethodPaths.inputSourceIdentifier] {
      guard
        let source = sources.first(where: {
          property($0, kTISPropertyInputSourceID) as? String == identifier
        })
      else { throw InputMethodRegistrationError.unavailable }
      if property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true { continue }
      let result = TISEnableInputSource(source)
      guard result == noErr else { throw InputMethodRegistrationError.enableFailed(result) }
    }
    guard state() == .enabled || state() == .selected else {
      throw InputMethodRegistrationError.unavailable
    }
  }

  private static func sources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: InputMethodPaths.bundleIdentifier] as CFDictionary
    return TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
  }

  private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  }
}
