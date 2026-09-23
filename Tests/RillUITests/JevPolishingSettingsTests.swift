import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct JevPolishingSettingsTests {
  @Test func consentIsExplicitAndRevokedSynchronouslyWhenKeyOrToggleChanges() throws {
    let source = JevPolishingSettingsSource()
    let model = JevPolishingSettingsModel(source: source)
    model.apiKey = " unit-test-key "
    #expect(model.hasValidKey)
    #expect(source.currentAuthorization() == nil)
    model.isEnabled = true
    let original = try #require(source.currentAuthorization())
    #expect(original.apiKey == "unit-test-key")
    model.apiKey = "replacement-test-key"
    #expect(!source.isCurrent(original))
    let replacement = try #require(source.currentAuthorization())
    model.isEnabled = false
    #expect(!source.isCurrent(replacement))
    #expect(source.currentAuthorization() == nil)
    model.isEnabled = true
    model.apiKey = ""
    #expect(!model.hasValidKey)
    #expect(source.currentAuthorization() == nil)
    let freshSession = JevPolishingSettingsModel()
    #expect(!freshSession.isEnabled)
    #expect(freshSession.apiKey.isEmpty)
  }
}
