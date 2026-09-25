import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct JevPolishingSettingsTests {
  @Test func oneCredentialHasIndependentPolishingConsentAndSynchronousRevocation() throws {
    let fixture = JevPanelFixture()
    let model = JevAPISettingsModel(service: fixture.service)
    let source = fixture.service.settings
    model.setKey(" unit-test-key ")
    #expect(model.isConfigured)
    #expect(!model.isPolishingEnabled)
    #expect(source.currentAuthorization() == nil)
    let ranking = try #require(source.rankingAuthorization())
    model.isPolishingEnabled = true
    let polishing = try #require(source.currentAuthorization())
    #expect(polishing.apiKey == ranking.apiKey)
    model.setKey("bad")
    #expect(model.error == .invalidInput)
    #expect(source.isCurrent(ranking) && source.isCurrent(polishing))
    model.setKey("replacement-test-key")
    #expect(!source.isCurrent(ranking) && !source.isCurrent(polishing))
    #expect(model.isPolishingEnabled)
    let replacement = try #require(source.rankingAuthorization())
    model.isPolishingEnabled = false
    #expect(source.isCurrent(replacement))
    #expect(source.currentAuthorization() == nil)
    model.isPolishingEnabled = true
    model.setKey("")
    #expect(!model.isConfigured && !model.isPolishingEnabled)
    #expect(!source.isCurrent(replacement))
    model.setKey("another-valid-key")
    #expect(!model.isPolishingEnabled)
    let fresh = JevSessionSettingsSource()
    #expect(!fresh.isConfigured && !fresh.isPolishingEnabled)
  }
}
