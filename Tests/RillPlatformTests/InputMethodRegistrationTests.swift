import Carbon
import Foundation
import RillInputMethodContracts
import Testing

@testable import RillPlatform

@MainActor
struct InputMethodRegistrationTests {
  @Test func successfulRegistrationWithNoSelectableSourceIsAnError() {
    #expect(throws: InputMethodRegistrationError.self) {
      try InputMethodRegistration.register(
        URL(fileURLWithPath: "/test/RillInputMethod.app"),
        registerSource: { _ in noErr }, queryState: { .needsRepair })
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
