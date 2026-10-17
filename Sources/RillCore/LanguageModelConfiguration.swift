import Foundation

public enum LanguageModelRole: String, Codable, CaseIterable, Identifiable, Sendable {
  case fast
  case intelligent

  public var id: String { rawValue }

  public var credentialKey: SecureCredentialKey {
    self == .fast ? .openAIAPIKey : .intelligentAPIKey
  }

  public var baseURLKey: AppSettingKey {
    self == .fast ? .openAIBaseURL : .intelligentBaseURL
  }

  public var modelKey: AppSettingKey {
    self == .fast ? .openAIModel : .intelligentModel
  }

}

public enum LanguageModelProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case openAI = "openai"
  case deepSeek = "deepseek"
  case compatible

  public var id: String { rawValue }

  public var defaultBaseURL: String {
    switch self {
    case .openAI, .compatible: OpenAISettings.defaultBaseURL
    case .deepSeek: LLMTextProcessing.deepSeekBaseURL
    }
  }

  public var defaultModel: String {
    switch self {
    case .openAI, .compatible: OpenAISettings.defaultModel
    case .deepSeek: LLMTextProcessing.deepSeekModel
    }
  }

  public static func infer(from baseURL: String) -> Self {
    switch URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() {
    case "api.openai.com": .openAI
    case "api.deepseek.com": .deepSeek
    default: .compatible
    }
  }
}

/// Durable model selection. Credentials are stored separately in Keychain.
public struct LanguageModelConfiguration: Codable, Sendable, Equatable {
  public var provider: LanguageModelProvider
  public var baseURL: String
  public var model: String

  public init(
    provider: LanguageModelProvider = .openAI,
    baseURL: String? = nil,
    model: String? = nil
  ) {
    self.provider = provider
    self.baseURL = baseURL ?? provider.defaultBaseURL
    self.model = model ?? provider.defaultModel
  }

  public init(migrating settings: OpenAISettings) {
    self.init(
      provider: .infer(from: settings.baseURL), baseURL: settings.baseURL, model: settings.model)
  }

  public func validate(for role: LanguageModelRole) throws {
    guard OpenAISettings.isValidBaseURL(baseURL), OpenAISettings.isValidModelIdentifier(model) else {
      throw LanguageModelConfigurationError.invalidConfiguration(role)
    }
    let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if provider == .openAI, role == .fast,
      name == "gpt-6-astra" || name.hasPrefix("gpt-6-astra-")
        || name == "gpt-6.1-sol" || name.hasPrefix("gpt-6.1-sol-")
    {
      throw LanguageModelConfigurationError.reasoningRequired(role)
    }
  }
}

public enum LanguageModelConfigurationError: Error, LocalizedError, Sendable, Equatable {
  case unavailable
  case invalidConfiguration(LanguageModelRole)
  case missingCredential(LanguageModelRole)
  case reasoningRequired(LanguageModelRole)

  public var errorDescription: String? {
    switch self {
    case .unavailable: "Model settings are unavailable."
    case .invalidConfiguration(let role): "Configure the \(role.rawValue) model in Settings."
    case .missingCredential(let role): "The \(role.rawValue) model needs an API key in Settings."
    case .reasoningRequired: "This model cannot disable reasoning. Select it for the intelligent role."
    }
  }
}

/// Run-owned credentials and model bindings; deliberately not serializable.
public struct WorkflowModelSnapshot: Sendable, Equatable {
  public var languageModels: [LanguageModelRole: OpenAISettings]
  public var decisionAuthorization: DecisionModelSettingsSource.Authorization?
  public var speechSynthesisModelID: String?

  public init(
    languageModels: [LanguageModelRole: OpenAISettings] = [:],
    speechSynthesisModelID: String? = nil,
    decisionAuthorization: DecisionModelSettingsSource.Authorization? = nil
  ) {
    self.languageModels = languageModels
    self.speechSynthesisModelID = speechSynthesisModelID
    self.decisionAuthorization = decisionAuthorization
  }
}

/// The UI publishes accepted edits synchronously, independently of durable writes.
public final class LanguageModelSettingsSource: @unchecked Sendable {
  private let lock = NSLock()
  private var settings: [LanguageModelRole: OpenAISettings] = [:]

  public init() {}

  public func update(_ value: OpenAISettings?, for role: LanguageModelRole) {
    lock.withLock { settings[role] = value }
  }

  public func currentSettings(for role: LanguageModelRole) throws -> OpenAISettings {
    let snapshot = try snapshot(for: [role])
    guard let value = snapshot.languageModels[role] else { throw LanguageModelConfigurationError.unavailable }
    return value
  }

  public func snapshot(for roles: Set<LanguageModelRole>) throws -> WorkflowModelSnapshot {
    try lock.withLock {
      var bindings: [LanguageModelRole: OpenAISettings] = [:]
      for role in roles {
        guard let value = settings[role] else { throw LanguageModelConfigurationError.unavailable }
        try LanguageModelConfiguration(migrating: value).validate(for: role)
        guard !value.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw LanguageModelConfigurationError.missingCredential(role)
        }
        bindings[role] = value
      }
      return WorkflowModelSnapshot(languageModels: bindings)
    }
  }

  public func validateCredential(_ value: OpenAISettings, for role: LanguageModelRole) throws {
    guard lock.withLock({ settings[role]?.apiKey == value.apiKey }), !value.apiKey.isEmpty else {
      throw LanguageModelConfigurationError.missingCredential(role)
    }
  }
}

extension WorkflowDefinition {
  public var languageModelRoles: Set<LanguageModelRole> {
    Set(plan.process.allSteps.compactMap { $0.postProcessStep?.resolvedModelRole })
  }
}

extension WorkflowDefinition {
  /// One-way import migration; obsolete selections never enter the executor.
  public func followingGlobalModels() -> Self {
    var workflow = self
    if workflow.plan.setup.speechRoute != nil {
      workflow.plan.setup.speechRoute?.selection = .automatic
      workflow.plan.setup.speechRoute?.recognizerID = "local-speech"
    }
    for key in Self.retiredModelOptionKeys { workflow.metadata.removeValue(forKey: key) }
    if workflow.metadata["text.polishing-gate"] == "jev" {
      workflow.metadata["text.polishing-gate"] = "classification"
    }
    func migrate(_ steps: [WorkflowProcessStep]) -> [WorkflowProcessStep] {
      steps.map { original in
        var step = original
        if let role = step.postProcessStep?.resolvedModelRole { step.modelRole = role }
        step.thenSteps = step.thenSteps.map(migrate)
        step.elseSteps = step.elseSteps.map(migrate)
        return step
      }
    }
    workflow.plan.process.steps = migrate(workflow.plan.process.steps)
    for index in workflow.plan.output.actions.indices where workflow.plan.output.actions[index].id == SpeechOutputActionID.speak {
      workflow.plan.output.actions[index].configuration.removeValue(forKey: SpeechOutputActionConfigurationKey.provider)
      workflow.plan.output.actions[index].configuration.removeValue(forKey: SpeechOutputActionConfigurationKey.model)
    }
    return workflow
  }

  public static let retiredModelOptionKeys: Set<String> = [
    WorkflowMetadataKey.recognizerSelectionMode, WorkflowMetadataKey.localSpeechModelOverride,
    WorkflowMetadataKey.legacyWhisperKitModelOverride, "provider", "deepgram.model",
    "openai.model", "openai.base-url", "speech.provider", "speech.model",
  ]
}
