import Foundation
import Testing
@testable import RillCore

struct LanguageModelConfigurationTests {
  @Test func snapshotsResolveOnlyUsedRolesAndRetainTheAdmittedModel() throws {
    let source = LanguageModelSettingsSource()
    let fast = OpenAISettings(apiKey: "test-key", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
    source.update(fast, for: .fast)
    let admitted = try source.snapshot(for: [.fast])
    #expect(admitted.languageModels == [.fast: fast])
    #expect(throws: LanguageModelConfigurationError.unavailable) { try source.snapshot(for: [.intelligent]) }
    source.update(.init(apiKey: "test-key", model: "next-model"), for: .fast)
    #expect(admitted.languageModels[.fast] == fast)
    try source.validateCredential(fast, for: .fast)
    source.update(.init(apiKey: "replacement-key"), for: .fast)
    #expect(throws: LanguageModelConfigurationError.missingCredential(.fast)) {
      try source.validateCredential(fast, for: .fast)
    }
  }

  @Test func reasoningOnlyModelsCannotBeAssignedToTheFastRole() throws {
    let model = LanguageModelConfiguration(provider: .openAI, model: "gpt-6-astra")
    #expect(throws: LanguageModelConfigurationError.reasoningRequired(.fast)) { try model.validate(for: .fast) }
    try model.validate(for: .intelligent)
  }

  @Test func changingDecisionProviderRevokesAllSessionAuthorizations() throws {
    let source = DecisionModelSettingsSource()
    try source.setKey("test-key")
    source.setPolishingEnabled(true)
    let ranking = try #require(source.rankingAuthorization())
    let polishing = try #require(source.currentAuthorization())
    source.select(.init(model: .clef, accountID: String(repeating: "a", count: 32)))
    #expect(!source.isConfigured && !source.isPolishingEnabled)
    #expect(!source.isCurrent(ranking) && !source.isCurrent(polishing))
    try source.setKey("cloudflare-test-key")
    #expect(source.rankingAuthorization()?.configuration.model == .clef)
    #expect(source.currentAuthorization() == nil)
  }
}
