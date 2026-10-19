import Foundation

public enum TriggerBinding: String, Codable, Sendable, Equatable {
  case manual
  case hotkey
  case menuBar
  case wakeWord
}

public enum LivePreviewPlacement: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
  case overlay
  case cursor

  public var id: String { rawValue }
}

public extension WorkflowDefinition {
  var livePreviewIsEnabled: Bool { plan.setup.speechRoute?.livePreviewEnabled ?? false }
  var resolvedLivePreviewPlacement: LivePreviewPlacement {
    livePreviewIsEnabled ? (plan.setup.speechRoute?.livePreviewPlacement ?? .overlay) : .overlay
  }
}

public enum WorkflowAvailability: String, Codable, Sendable, Equatable {
  case active
  case planned
}

/// A validated, content-free record collection automation declaration.
public struct RecordCollectionAutomationConfiguration: Codable, Sendable, Equatable {
  public var rule: RecordCollectionTriggerRule
  public var actionKind: RecordCollectionActionKind

  public init(rule: RecordCollectionTriggerRule, actionKind: RecordCollectionActionKind) {
    self.rule = rule
    self.actionKind = actionKind
  }
}

public enum ExternalOutputActionID {
  public static let webhookPost = "external.webhook.post"
  public static let shortcutsRun = "external.shortcuts.run"
  public static let markdownAppend = "external.markdown.append"
}

public enum ExternalOutputActionConfigurationKey {
  public static let webhookURL = "webhook.url"
  public static let webhookHeadersJSON = "webhook.headersJSON"
  public static let webhookSecureReference = "webhook.secureReference"
  public static let shortcutName = "shortcuts.name"
  public static let markdownAppendPath = "markdown.append.path"
}

public struct WorkflowUIConfig: Codable, Sendable, Equatable {
  public var symbolName: String
  public var accentColorName: String

  public init(symbolName: String, accentColorName: String) {
    self.symbolName = symbolName
    self.accentColorName = accentColorName
  }
}

/// Closed SF Symbol values emitted by Rill-owned workflow definitions.
///
/// User-authored workflow files may still provide arbitrary symbol names; the
/// UI validates those open values and falls back before rendering them.
public enum WorkflowUISymbol: String, CaseIterable, Sendable {
  case micFill = "mic.fill"
  case sparkles = "sparkles"
  case squareStack3dUpFill = "square.stack.3d.up.fill"
}

public struct WorkflowProperties: Codable, Sendable, Equatable {
  public var gesture: String?
  public var exclusiveGroup: String?
  public var defaultEnabled: Bool
  public var availability: WorkflowAvailability
  public var isBuiltin: Bool
  public var textStyle: String?
  public var automation: RecordCollectionAutomationConfiguration?
  public init(
    gesture: String? = nil, exclusiveGroup: String? = nil, defaultEnabled: Bool = true,
    availability: WorkflowAvailability = .active, isBuiltin: Bool = false, textStyle: String? = nil,
    automation: RecordCollectionAutomationConfiguration? = nil
  ) {
    self.gesture = gesture
    self.exclusiveGroup = exclusiveGroup
    self.defaultEnabled = defaultEnabled
    self.availability = availability
    self.isBuiltin = isBuiltin
    self.textStyle = textStyle
    self.automation = automation
  }
}

public extension WorkflowDefinition {
  var availability: WorkflowAvailability { properties.availability }
  var isEnabledByDefault: Bool { properties.defaultEnabled }
  var exclusiveGroupIdentifier: String? { properties.exclusiveGroup }
  var prefersAutomaticRecognizerSelection: Bool { plan.setup.speechRoute?.selection == .automatic }
  var excludesOutputFromRecordCapture: Bool {
    plan.output.actions.contains { $0.configuration.excludeFromCapture }
  }
  var collectsSpeech: Bool { plan.output.actions.contains { $0.configuration.buffer == "speech" } }
  var targetRecordCollectionIDs: [RecordCollectionID] {
    var seen = Set<RecordCollectionID>()
    return plan.output.actions.flatMap { $0.configuration.collections.map { RecordCollectionID($0) } }.filter { seen.insert($0).inserted }
  }
}

public enum WorkflowTitleKey: String, Codable, Sendable, Equatable {
  case ambiguousDemoStack
  case directDemoClipboard
  case rewriteDemoStack
  case pushToTalkCapture
  case pushToTalkPolish
  case rawInput
  case cleanInput
  case speechRecognition
  case bufferDictation
  case bufferDraftDictation
  case formalWriting
  case smartCleanup
  case translateInput
  case commandMode
  case localDictation
  case cloudDictation
  case recordDelivery
  case streamingInput
  case voiceAssistant

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    let canonicalValue = value == "stackDelivery" ? "recordDelivery" : value
    guard let key = Self(rawValue: canonicalValue) else {
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Unknown workflow title key."
      )
    }
    self = key
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct WorkflowPresentation: Codable, Sendable, Equatable {
  public var fallbackName: String
  public var titleKey: WorkflowTitleKey?

  public init(fallbackName: String, titleKey: WorkflowTitleKey? = nil) {
    self.fallbackName = fallbackName
    self.titleKey = titleKey
  }
}

public enum ResolutionMode: String, Codable, Sendable, Equatable {
  case off
  case nonBlocking
  case blocking
}

public struct UncertaintyPolicy: Codable, Sendable, Equatable {
  public var mode: ResolutionMode
  public var confidenceThreshold: Double
  public var timeoutSeconds: Double

  public init(
    mode: ResolutionMode = .nonBlocking,
    confidenceThreshold: Double = 0.72,
    timeoutSeconds: Double = 5
  ) {
    self.mode = mode
    self.confidenceThreshold = confidenceThreshold
    self.timeoutSeconds = timeoutSeconds
  }
}

public enum DeliveryStrategy: String, Codable, Sendable, Equatable {
  case immediate
  case collectionFirst
  case systemClipboardOnly

}

public struct DeliveryPolicy: Codable, Sendable, Equatable {
  public var strategy: DeliveryStrategy

  public init(strategy: DeliveryStrategy) {
    self.strategy = strategy
  }
}

public enum PostProcessStepKind: String, Codable, Sendable, Equatable {
  case snippetReplacement
  case llmRewrite
  case llmAnswer
  case normalizeWhitespace
}

public enum WorkflowTaskFailurePolicy: String, Codable, Sendable, Equatable {
  case fail
  case preserveInput = "preserve-input"
}

public struct PostProcessStep: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var kind: PostProcessStepKind
  public var prompt: String?
  public var optional: Bool = false
  public var decision: WorkflowServiceRequirement?
  public var failurePolicy: WorkflowTaskFailurePolicy = .fail
  public var preservesContent: Bool = false
  public var reasoning: ReasoningLevel?

  public init(
    id: UUID = UUID(), kind: PostProcessStepKind, prompt: String? = nil,
    reasoning: ReasoningLevel? = nil, failurePolicy: WorkflowTaskFailurePolicy = .fail
  ) {
    self.id = id
    self.kind = kind
    self.prompt = prompt
    self.reasoning = reasoning
    self.failurePolicy = failurePolicy
  }

}

public struct OutputActionReference: Identifiable, Codable, Sendable, Equatable {
  public var documentID: String?
  public var nodeDescription: String?
  public var condition: WorkflowCondition?
  public var id: String
  public var optional = false
  public var configuration: WorkflowOutputParameters

  public init(id: String, configuration: WorkflowOutputParameters = .init()) {
    self.id = id
    self.configuration = configuration
  }
}

public struct WorkflowDefinition: Identifiable, Codable, Sendable, Equatable {
  public var documentDescription: String?
  public var declaredInputKind: WorkflowInputKind?
  public var id: UUID
  public var name: String
  public var titleKey: WorkflowTitleKey?
  public var trigger: TriggerBinding
  public var plan: WorkflowPlan
  public var ui: WorkflowUIConfig
  public var properties: WorkflowProperties

  public init(
    id: UUID = UUID(),
    name: String,
    titleKey: WorkflowTitleKey? = nil,
    trigger: TriggerBinding = .manual,
    plan: WorkflowPlan,
    ui: WorkflowUIConfig,
    properties: WorkflowProperties = .init()
  ) {
    self.id = id
    self.name = name
    self.titleKey = titleKey
    self.trigger = trigger
    self.plan = plan
    self.ui = ui
    self.properties = properties
  }

  public var presentation: WorkflowPresentation {
    WorkflowPresentation(fallbackName: name, titleKey: titleKey)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case documentDescription
    case declaredInputKind
    case name
    case titleKey
    case trigger
    case plan
    case ui
    case properties
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    documentDescription = try container.decodeIfPresent(String.self, forKey: .documentDescription)
    declaredInputKind = try container.decodeIfPresent(WorkflowInputKind.self, forKey: .declaredInputKind)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    titleKey = try container.decodeIfPresent(WorkflowTitleKey.self, forKey: .titleKey)
    trigger = try container.decode(TriggerBinding.self, forKey: .trigger)
    ui = try container.decode(WorkflowUIConfig.self, forKey: .ui)
    properties = try container.decode(WorkflowProperties.self, forKey: .properties)
    plan = try container.decode(WorkflowPlan.self, forKey: .plan)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(documentDescription, forKey: .documentDescription)
    try container.encodeIfPresent(declaredInputKind, forKey: .declaredInputKind)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(titleKey, forKey: .titleKey)
    try container.encode(trigger, forKey: .trigger)
    try container.encode(plan, forKey: .plan)
    try container.encode(ui, forKey: .ui)
    try container.encode(properties, forKey: .properties)
  }
}
