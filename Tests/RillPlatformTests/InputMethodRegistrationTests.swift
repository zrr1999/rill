import Carbon
import Foundation
import RillInputMethodContracts
import Testing

@testable import RillPlatform

@MainActor
struct InputMethodRegistrationTests {
  @Test func defaultEnabledModeStillNeedsItsParentEnabled() {
    #expect(
      InputMethodRegistration.state(
        parentEnabled: false, modeEnabled: true, modeSelected: false) == .registered)
    #expect(
      InputMethodRegistration.state(
        parentEnabled: true, modeEnabled: false, modeSelected: false) == .registered)
    #expect(
      InputMethodRegistration.state(
        parentEnabled: true, modeEnabled: true, modeSelected: false) == .enabled)
    #expect(
      InputMethodRegistration.state(
        parentEnabled: true, modeEnabled: true, modeSelected: true) == .selected)
  }

  @Test func successfulRegistrationWithNoSelectableSourceIsAnError() {
    #expect(throws: InputMethodRegistrationError.self) {
      try InputMethodRegistration.register(
        URL(fileURLWithPath: "/test/RillInputMethod.app"),
        registerSource: { _ in noErr }, queryState: { .registrationPending })
    }
  }

  @Test func failedRegistrationDoesNotTrustAnOldSource() {
    #expect(throws: InputMethodRegistrationError.self) {
      try InputMethodRegistration.register(
        URL(fileURLWithPath: "/test/RillInputMethod.app"),
        registerSource: { _ in OSStatus(paramErr) }, queryState: { .enabled })
    }
  }

  @Test(arguments: [InputMethodInstallationState.registered, .enabled, .selected])
  func actualSelectableSourceCompletesRegistration(state: InputMethodInstallationState) throws {
    try InputMethodRegistration.register(
      URL(fileURLWithPath: "/test/RillInputMethod.app"),
      registerSource: { _ in noErr }, queryState: { state })
  }
}
