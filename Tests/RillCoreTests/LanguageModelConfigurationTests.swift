import Foundation
import RillCore
import Testing

struct LanguageModelConfigurationTests {
  private func workflow(reasoning: ReasoningLevel, optional: Bool = false) -> WorkflowDefinition {
    var step = WorkflowProcessStep(kind: .llmRewrite, prompt: "Rewrite", reasoning: reasoning)
    step.optional = optional
    return WorkflowDefinition(
      name: "Fixture", plan: .init(setup: .init(), process: .init(steps: [step]), output: .init(actions: [])),
      ui: .init(symbolName: "sparkles", accentColorName: "blue"))
  }
  @Test(arguments: ReasoningLevel.allCases)
  func singleConnectionServesAllLevels(_ level: ReasoningLevel) throws {
    let source = LanguageModelSettingsSource()
    let settings = OpenAISettings(apiKey: "synthetic-key")
    source.update(settings)
    let snapshot = try source.snapshot(for: workflow(reasoning: level))
    #expect(snapshot.languageModel == settings)
    source.update(OpenAISettings(apiKey: "replacement", model: "deepseek-flash"))
    #expect(snapshot.languageModel == settings)
    #expect(throws: LanguageModelConfigurationError.missingCredential) { try source.validateCredential(settings) }
  }
  @Test func unknownCapabilitiesAreRejected() throws {
    let configuration = LanguageModelConfiguration(provider: .compatible, baseURL: "https://gateway.example/v1", model: "unknown-model")
    for level in ReasoningLevel.allCases {
      #expect(throws: LanguageModelConfigurationError.unsupportedReasoning(level)) { try configuration.validate(reasoning: level) }
    }
    #expect(throws: LanguageModelConfigurationError.unsupportedReasoning(.none)) {
      try LanguageModelConfiguration(model: "gpt-6-astra").validate(reasoning: .none)
    }
  }
  @Test(arguments: ["gpt-6-sol", "deepseek-flash"])
  func knownModelNameDoesNotVerifyAnArbitraryGateway(_ model: String) {
    let configuration = LanguageModelConfiguration(provider: .compatible, baseURL: "https://gateway.example/v1", model: model)
    #expect(configuration.supportedReasoningLevels.isEmpty)
  }
  @Test(arguments: [" https://api.openai.com/v1 ", "HTTPS://api.openai.com/v1"])
  func verifiedEndpointsUseTheTransportNormalization(_ endpoint: String) throws {
    let configuration = LanguageModelConfiguration(migrating: .init(apiKey: "test", baseURL: endpoint))
    try configuration.validate(reasoning: .none)
  }
  @Test func optionalUnconfiguredServiceProducesSkippedStep() throws {
    let source = LanguageModelSettingsSource()
    let optional = workflow(reasoning: .none, optional: true)
    #expect(try source.snapshot(for: optional).skippedStepIDs == Set(optional.plan.process.steps.map(\.id)))
    #expect(throws: LanguageModelConfigurationError.unavailable) { try source.snapshot(for: workflow(reasoning: .none)) }
  }
  @Test func decisionDependencyIsRequiredOnlyWhenDeclaredRequired() throws {
    let source = LanguageModelSettingsSource()
    source.update(.init(apiKey: "test"))
    var value = workflow(reasoning: .none)
    value.plan.process.steps[0].decision = .init(optional: true)
    #expect(try source.snapshot(for: value).decisionAuthorization == nil)
    value.plan.process.steps[0].decision = .init(optional: false)
    #expect(throws: LanguageModelConfigurationError.decisionUnavailable) { try source.snapshot(for: value) }
    value.plan.process.steps[0].optional = true
    source.update(nil)
    #expect(try source.snapshot(for: value).skippedStepIDs.contains(value.plan.process.steps[0].id))
  }
  @Test func speechOutputRequiresAFrozenTTSBinding() throws {
    let source = LanguageModelSettingsSource()
    var value = workflow(reasoning: .none, optional: true)
    value.plan.output.actions = [.init(id: SpeechOutputActionID.speak)]
    #expect(throws: LanguageModelConfigurationError.speechSynthesisUnavailable) { try source.snapshot(for: value) }
    #expect(try source.snapshot(for: value, speechSynthesis: .system).speechSynthesis == .system)
    #expect(try source.snapshot(for: value, speechSynthesis: .localModel("fixture-tts")).speechSynthesis == .localModel("fixture-tts"))
  }

}
