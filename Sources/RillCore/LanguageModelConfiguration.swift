import Foundation

public enum ReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
  case none, low, high
  public var id: String { rawValue }
}

public enum LanguageModelProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case openAI = "openai"
  case deepSeek = "deepseek"
  case compatible
  public var id: String { rawValue }
  public var defaultBaseURL: String {
    self == .deepSeek ? LLMTextProcessing.deepSeekBaseURL : OpenAISettings.defaultBaseURL
  }
  public var defaultModel: String {
    self == .deepSeek ? LLMTextProcessing.deepSeekModel : OpenAISettings.defaultModel
  }
  public static func infer(from baseURL: String) -> Self {
    switch URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() {
    case "api.openai.com": .openAI
    case "api.deepseek.com": .deepSeek
    default: .compatible
    }
  }
}

/// Connection configuration. The adapter owns reasoning capabilities and native parameters.
public struct LanguageModelConfiguration: Codable, Sendable, Equatable {
  public var provider: LanguageModelProvider
  public var baseURL: String
  public var model: String
  public init(provider: LanguageModelProvider = .openAI, baseURL: String? = nil, model: String? = nil) {
    self.provider = provider
    self.baseURL = baseURL ?? provider.defaultBaseURL
    self.model = model ?? provider.defaultModel
  }
  public init(migrating settings: OpenAISettings) {
    self.init(provider: .infer(from: settings.baseURL), baseURL: settings.baseURL, model: settings.model)
  }
  public func validate() throws {
    guard OpenAISettings.isValidBaseURL(baseURL), OpenAISettings.isValidModelIdentifier(model) else {
      throw LanguageModelConfigurationError.invalidConfiguration
    }
  }
  public func validate(reasoning: ReasoningLevel) throws {
    try validate()
    if !supportedReasoningLevels.contains(reasoning) {
      throw LanguageModelConfigurationError.unsupportedReasoning(reasoning)
    }
  }
  public var supportedReasoningLevels: Set<ReasoningLevel> {
    guard let endpoint = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), endpoint.scheme?.lowercased() == "https",
      endpoint.port == nil || endpoint.port == 443
    else { return [] }
    let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch (provider, endpoint.host?.lowercased(), path) {
    case (.openAI, "api.openai.com", "v1"):
      if ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-luna", "gpt-6-sol"].contains(name) { return Set(ReasoningLevel.allCases) }
      if ["gpt-6-astra", "gpt-6.1-sol"].contains(name) { return [.low, .high] }
    case (.deepSeek, "api.deepseek.com", ""), (.deepSeek, "api.deepseek.com", "v1"):
      if ["deepseek-flash", "deepseek-v4-pro"].contains(name) { return Set(ReasoningLevel.allCases) }
    default: break
    }
    return []
  }
}

public enum LanguageModelConfigurationError: Error, LocalizedError, Sendable, Equatable {
  case unavailable, invalidConfiguration, missingCredential, decisionUnavailable, speechSynthesisUnavailable
  case unsupportedReasoning(ReasoningLevel)
  public var errorDescription: String? {
    switch self {
    case .decisionUnavailable: "Configure the Decision service in Settings before running this workflow."
    case .speechSynthesisUnavailable: "Configure the TTS service in Settings before running this workflow."
    case .unavailable: "Model service settings are unavailable."
    case .invalidConfiguration: "Configure the language model service in Settings."
    case .missingCredential: "The language model service needs an API key in Settings."
    case .unsupportedReasoning(let level): "The configured service has no verified support for \(level.rawValue) reasoning."
    }
  }
}

public enum SpeechSynthesisBinding: Sendable, Equatable {
  case system
  case localModel(String)
}

/// Run-owned service bindings. Credentials cannot be serialized with a workflow.
public struct WorkflowModelSnapshot: Sendable, Equatable {
  public var languageModel: OpenAISettings?
  public var decisionAuthorization: DecisionModelSettingsSource.Authorization?
  public var speechSynthesis: SpeechSynthesisBinding?
  public var skippedStepIDs: Set<UUID>
  public init(
    languageModel: OpenAISettings? = nil, speechSynthesis: SpeechSynthesisBinding? = nil,
    decisionAuthorization: DecisionModelSettingsSource.Authorization? = nil, skippedStepIDs: Set<UUID> = []
  ) {
    self.languageModel = languageModel
    self.speechSynthesis = speechSynthesis
    self.decisionAuthorization = decisionAuthorization
    self.skippedStepIDs = skippedStepIDs
  }
}

public final class LanguageModelSettingsSource: @unchecked Sendable {
  private let lock = NSLock()
  private var settings: OpenAISettings?
  public init() {}
  public func update(_ value: OpenAISettings?) { lock.withLock { settings = value } }
  public func currentSettings() throws -> OpenAISettings {
    try lock.withLock {
      guard let settings else { throw LanguageModelConfigurationError.unavailable }
      try LanguageModelConfiguration(migrating: settings).validate()
      return settings
    }
  }
  public func snapshot(
    for workflow: WorkflowDefinition,
    decisionAuthorization: DecisionModelSettingsSource.Authorization? = nil,
    speechSynthesis: SpeechSynthesisBinding? = nil
  ) throws -> WorkflowModelSnapshot {
    try lock.withLock {
      var snapshot = WorkflowModelSnapshot(speechSynthesis: speechSynthesis, decisionAuthorization: decisionAuthorization)
      for step in workflow.plan.process.allSteps where step.kind == .llmRewrite || step.kind == .llmAnswer {
        do {
          guard let settings else { throw LanguageModelConfigurationError.unavailable }
          guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LanguageModelConfigurationError.missingCredential
          }
          guard let reasoning = step.reasoning else { throw LanguageModelConfigurationError.invalidConfiguration }
          try LanguageModelConfiguration(migrating: settings).validate(reasoning: reasoning)
          snapshot.languageModel = settings
        } catch {
          guard step.optional else { throw error }
          snapshot.skippedStepIDs.insert(step.id)
        }
      }
      if decisionAuthorization == nil,
        workflow.plan.process.allSteps.contains(where: { $0.decision?.optional == false && !snapshot.skippedStepIDs.contains($0.id) })
      {
        throw LanguageModelConfigurationError.decisionUnavailable
      }
      if workflow.plan.output.actions.contains(where: { $0.id == SpeechOutputActionID.speak }),
        speechSynthesis == nil
      {
        throw LanguageModelConfigurationError.speechSynthesisUnavailable
      }
      return snapshot
    }
  }
  public func validateCredential(_ value: OpenAISettings) throws {
    guard lock.withLock({ settings?.apiKey == value.apiKey }), !value.apiKey.isEmpty else {
      throw LanguageModelConfigurationError.missingCredential
    }
  }
}
