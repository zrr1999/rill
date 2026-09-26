import Foundation
import RillInputMethodContracts
import Testing

@testable import RillUI

@MainActor
struct InputMethodInstallationTests {
  @Test func reopeningAndReturningFromSystemSettingsReadActualInstallationState() async {
    var actual = InputMethodInstallationState.needsRepair
    let model = InputMethodFeatureModel(
      settings: UITestSettingsStore(), privacy: { .defaults },
      confirmRule: { _, id in (id, true) }, revokeRule: { _ in }, install: { _ in "" },
      inspectInstallation: { actual })
    #expect(model.installationState == .needsRepair)
    actual = .registrationPending
    model.refreshInstallationState()
    #expect(model.installationState == .registrationPending)
    actual = .enabled
    model.refreshInstallationState()
    #expect(model.installationState == .enabled)
    actual = .selected
    model.refreshInstallationState()
    #expect(model.installationState == .selected)
    await model.shutdown()
  }

  @Test func failedInstallationCanBeRepairedThenReflectsSystemActivation() async {
    var actual = InputMethodInstallationState.notInstalled
    var attempt = 0
    let model = InputMethodFeatureModel(
      settings: UITestSettingsStore(), privacy: { .defaults },
      confirmRule: { _, id in (id, true) }, revokeRule: { _ in },
      install: { _ in
        attempt += 1
        actual = attempt == 1 ? .needsRepair : .registered
        if attempt == 1 { throw CocoaError(.fileWriteUnknown) }
        return "Installed"
      }, inspectInstallation: { actual })
    await model.installInputMethod()
    #expect(model.installationState == .needsRepair)
    #expect(model.error != nil)
    #expect(model.status == nil)
    #expect(!model.isInstalling)
    await model.installInputMethod()
    #expect(model.installationState == .registered)
    #expect(model.error == nil)
    actual = .enabled
    model.refreshInstallationState()
    #expect(model.installationState == .enabled)
    #expect(model.error == nil)
    await model.shutdown()
  }
}
