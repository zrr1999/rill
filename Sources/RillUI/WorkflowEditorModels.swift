import Foundation
import RillCore

public struct WorkflowEditorDraft: Equatable, Sendable {

  // MARK: - Event Type (unified: voice triggers + record collection events)

  public enum EventType: String, CaseIterable, Identifiable, Codable, Sendable {
    case hotkey
    case manual
    case menuBar
    case wakeWord
    case groupItemCreated
    case groupItemEdited
    case groupItemRemoved

    public var id: String { rawValue }

    public var isVoiceEvent: Bool {
      switch self {
      case .hotkey, .manual, .menuBar, .wakeWord: return true
      case .groupItemCreated, .groupItemEdited, .groupItemRemoved: return false
      }
    }

    var triggerBinding: TriggerBinding? {
      switch self {
      case .hotkey: return .hotkey
      case .manual: return .manual
      case .menuBar: return .menuBar
      case .wakeWord: return .wakeWord
      case .groupItemCreated, .groupItemEdited, .groupItemRemoved: return nil
      }
    }

    var groupEventKind: RecordCollectionEventKind? {
      switch self {
      case .hotkey, .manual, .menuBar, .wakeWord: return nil
      case .groupItemCreated: return .recordCreated
      case .groupItemEdited: return .recordEdited
      case .groupItemRemoved: return .recordRemoved
      }
    }
  }

  // MARK: - Recognizer & Destination (for voice actions)

  public enum RecognizerChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case localSpeech

    public var id: String { rawValue }

    var recognizerID: String {
      switch self {
      case .automatic, .localSpeech:
        return "local-speech"
      }
    }

    init?(recognizerID: String) {
      switch recognizerID {
      case "local-speech", "sherpa-onnx.local", "sherpa-onnx.streaming":
        self = .localSpeech
      default:
        return nil
      }
    }
  }

  public enum DestinationChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case pasteIntoApp
    case copyToClipboard
    case saveToQueue
    case speakOnly
    case sendToWebhook
    case runShortcut
    case appendToMarkdown

    public var id: String { rawValue }

    var outputActionID: String {
      switch self {
      case .pasteIntoApp:
        return "focused-application.insert"
      case .copyToClipboard:
        return "system-clipboard.copy"
      case .saveToQueue:
        return "record.store"
      case .speakOnly:
        return SpeechOutputActionID.speak
      case .sendToWebhook:
        return ExternalOutputActionID.webhookPost
      case .runShortcut:
        return ExternalOutputActionID.shortcutsRun
      case .appendToMarkdown:
        return ExternalOutputActionID.markdownAppend
      }
    }

    var deliveryStrategy: DeliveryStrategy {
      switch self {
      case .pasteIntoApp:
        return .immediate
      case .copyToClipboard:
        return .systemClipboardOnly
      case .saveToQueue:
        return .collectionFirst
      case .speakOnly, .sendToWebhook, .runShortcut, .appendToMarkdown:
        return .immediate
      }
    }

    init?(workflow: WorkflowDefinition) {
      let primaryAction =
        workflow.plan.output.actions.first { $0.id != RecordActionID.store }
        ?? workflow.plan.output.actions.first
      switch primaryAction?.id {
      case "focused-application.insert":
        self = .pasteIntoApp
      case "system-clipboard.copy":
        self = .copyToClipboard
      case "record.store":
        self = .saveToQueue
      case SpeechOutputActionID.speak:
        self = .speakOnly
      case ExternalOutputActionID.webhookPost:
        self = .sendToWebhook
      case ExternalOutputActionID.shortcutsRun:
        self = .runShortcut
      case ExternalOutputActionID.markdownAppend:
        self = .appendToMarkdown
      default:
        return nil
      }
    }
  }

  // MARK: - Post-Process Step Draft

  public struct PostProcessStepDraft: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: PostProcessStepKind
    public var prompt: String
    public var optional = false
    public var decision: WorkflowServiceRequirement?
    public var failurePolicy: WorkflowTaskFailurePolicy = .fail
    public var preservesContent = false
    public var reasoning: ReasoningLevel?

    public init(id: UUID = UUID(), kind: PostProcessStepKind, prompt: String = "", reasoning: ReasoningLevel? = nil) {
      self.id = id
      self.kind = kind
      self.prompt = prompt
      self.reasoning = reasoning
    }

    init(step: PostProcessStep) {
      self.id = step.id
      self.kind = step.kind
      self.prompt = step.prompt ?? ""
      self.reasoning = step.reasoning
      self.optional = step.optional
      self.decision = step.decision
      self.failurePolicy = step.failurePolicy
      self.preservesContent = step.preservesContent
    }

    func toStep() -> PostProcessStep {
      var step = PostProcessStep(
        id: id,
        kind: kind,
        prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt,
        reasoning: reasoning
      )
      step.optional = optional
      step.decision = decision
      step.failurePolicy = failurePolicy
      step.preservesContent = preservesContent
      return step
    }
  }

  // MARK: - Draft Properties

  public var name: String

  // Event
  public var eventType: EventType
  public var sourceCollectionID: UUID?
  public var wakePhrasesText: String

  // Condition
  public var excludePolishTag: Bool

  // Action – voice pipeline
  public var recognizer: RecognizerChoice
  public var speechLanguageOverride: String
  public var livePreviewEnabled: Bool
  public var livePreviewPlacement: LivePreviewPlacement
  public var streamingProfile: String
  public var vocabularyBindings: [VocabularyCollectionBinding]
  public var postProcessSteps: [PostProcessStepDraft]
  public var destination: DestinationChoice
  public var targetGroupID: UUID?
  public var webhookURL: String
  public var webhookHeadersJSON: String
  public var shortcutName: String
  public var markdownAppendPath: String
  public var excludeFromWorkflowCapture: Bool
  public var speaksResult: Bool
  public var speechVoice: Qwen3TTSVoice

  // Action – record collection event
  public var groupActionKind: RecordCollectionActionKind
  public var actionPrompt: String

  // MARK: - Init

  public init(
    name: String = "",
    eventType: EventType = .hotkey,
    sourceCollectionID: UUID? = nil,
    wakePhrasesText: String = WakeWordConfiguration.defaultPhrases.joined(separator: "\n"),
    excludePolishTag: Bool = true,
    recognizer: RecognizerChoice = .localSpeech,
    speechLanguageOverride: String = "",
    livePreviewEnabled: Bool = true,
    livePreviewPlacement: LivePreviewPlacement = .overlay,
    streamingProfile: String = "realtime",
    vocabularyBindings: [VocabularyCollectionBinding] = [
      VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID)
    ],
    postProcessSteps: [PostProcessStepDraft] = [PostProcessStepDraft(kind: .normalizeWhitespace)],
    destination: DestinationChoice = .pasteIntoApp,
    targetGroupID: UUID? = nil,
    webhookURL: String = "",
    webhookHeadersJSON: String = "",
    shortcutName: String = "",
    markdownAppendPath: String = "",
    excludeFromWorkflowCapture: Bool = true,
    speaksResult: Bool = false,
    speechVoice: Qwen3TTSVoice = .vivian,
    groupActionKind: RecordCollectionActionKind = .editRecord,
    actionPrompt: String = ""
  ) {
    self.name = name
    self.eventType = eventType
    self.sourceCollectionID = sourceCollectionID
    self.wakePhrasesText = wakePhrasesText
    self.excludePolishTag = excludePolishTag
    self.recognizer = recognizer
    self.speechLanguageOverride = speechLanguageOverride
    self.livePreviewEnabled = livePreviewEnabled
    self.livePreviewPlacement = livePreviewPlacement
    self.streamingProfile = streamingProfile
    self.vocabularyBindings = vocabularyBindings
    self.postProcessSteps = postProcessSteps
    self.destination = destination
    self.targetGroupID = targetGroupID
    self.webhookURL = webhookURL
    self.webhookHeadersJSON = webhookHeadersJSON
    self.shortcutName = shortcutName
    self.markdownAppendPath = markdownAppendPath
    self.excludeFromWorkflowCapture = excludeFromWorkflowCapture
    self.speaksResult = speaksResult
    self.speechVoice = speechVoice
    self.groupActionKind = groupActionKind
    self.actionPrompt = actionPrompt
  }

  // Backward-compatible convenience
  public var normalizeWhitespace: Bool {
    postProcessSteps.contains(where: { $0.kind == .normalizeWhitespace })
  }

  // MARK: - From WorkflowDefinition (voice workflows)

  init?(workflow: WorkflowDefinition) {
    let selectedRecognizer = workflow.plan.setup.speechRoute.flatMap {
      RecognizerChoice(recognizerID: $0.recognizerID)
    }
    guard
      let recognizer = selectedRecognizer,
      let destination = DestinationChoice(workflow: workflow),
      destination != .sendToWebhook
    else {
      return nil
    }

    self.name = workflow.name

    switch workflow.trigger {
    case .hotkey: self.eventType = .hotkey
    case .manual: self.eventType = .manual
    case .menuBar: self.eventType = .menuBar
    case .wakeWord: self.eventType = .wakeWord
    }
    self.wakePhrasesText =
      workflow.plan.setup.wakeWord?.phrases.joined(separator: "\n")
      ?? WakeWordConfiguration.defaultPhrases.joined(separator: "\n")

    self.sourceCollectionID = nil
    self.excludePolishTag = true
    self.recognizer = recognizer
    self.speechLanguageOverride = workflow.plan.setup.speechRoute?.language ?? ""
    self.destination = destination
    self.vocabularyBindings = workflow.plan.setup.vocabularyBindings
    self.postProcessSteps = workflow.plan.process.steps
      .compactMap(\.postProcessStep)
      .map { PostProcessStepDraft(step: $0) }
    self.excludeFromWorkflowCapture = workflow.excludesOutputFromRecordCapture
    self.speaksResult = workflow.plan.output.actions.contains {
      $0.id == SpeechOutputActionID.speak
    }
    self.speechVoice =
      workflow.plan.output.actions
      .first(where: { $0.id == SpeechOutputActionID.speak })?
      .configuration.voice
      .flatMap(Qwen3TTSVoice.init(rawValue:))
      ?? .vivian
    self.livePreviewEnabled = workflow.livePreviewIsEnabled
    self.livePreviewPlacement = workflow.resolvedLivePreviewPlacement
    self.streamingProfile =
      workflow.plan.setup.speechRoute?.streamingProfile
      ?? (workflow.trigger == .wakeWord ? "agent" : "realtime")
    self.targetGroupID = workflow.targetRecordCollectionIDs.first?.rawValue
    let outputConfiguration =
      workflow.plan.output.actions
      .first { $0.id == destination.outputActionID }?.configuration ?? WorkflowOutputParameters()
    self.webhookURL = outputConfiguration.webhookURL ?? ""
    self.webhookHeadersJSON = outputConfiguration.webhookHeadersJSON ?? ""
    self.shortcutName = outputConfiguration.shortcutName ?? ""
    self.markdownAppendPath = outputConfiguration.markdownPath ?? ""

    self.groupActionKind = workflow.properties.automation?.actionKind ?? .editRecord
    self.actionPrompt = ""
  }

  // MARK: - Build WorkflowDefinition

  func makeWorkflow(
    id: UUID,
    existingProperties: WorkflowProperties = .init(),
    hotkeyGesture: String
  ) -> WorkflowDefinition {
    let trigger = eventType.triggerBinding ?? .manual
    var properties = existingProperties
    properties.isBuiltin = false
    properties.gesture = eventType == .hotkey ? hotkeyGesture : nil
    properties.textStyle = textStyle.rawValue
    let trimmedLanguageOverride = speechLanguageOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    var route = WorkflowSpeechRoute(
      selection: .automatic, recognizerID: "local-speech",
      language: trimmedLanguageOverride.isEmpty ? nil : trimmedLanguageOverride
    )
    route.livePreviewEnabled = livePreviewEnabled
    route.livePreviewPlacement = livePreviewPlacement
    route.streamingProfile = streamingProfile
    let processSteps =
      [
        WorkflowProcessStep(kind: .recognizeSpeech),
        WorkflowProcessStep(kind: .applyVocabulary),
      ]
      + postProcessSteps.map { WorkflowProcessStep($0.toStep()) }
    let outputActionConfiguration = destination.outputConfiguration(from: self)
    var outputActions = [
      OutputActionReference(
        id: destination.outputActionID,
        configuration: outputActionConfiguration
      )
    ]
    if speaksResult, destination != .speakOnly {
      outputActions.append(
        OutputActionReference(
          id: SpeechOutputActionID.speak,
          configuration: .init(voice: speechVoice.rawValue)
        )
      )
    }
    return WorkflowDefinition(
      id: id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      trigger: trigger,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(
          speechRoute: route,
          vocabularyBindings: vocabularyBindings,
          wakeWord:
            trigger == .wakeWord
            ? WakeWordConfiguration(phrases: wakePhrases)
            : nil
        ),
        process: WorkflowProcessPhase(steps: processSteps),
        output: WorkflowOutputPhase(
          actions: outputActions,
          deliveryPolicy: DeliveryPolicy(strategy: destination.deliveryStrategy)
        )
      ),
      ui: WorkflowUIConfig(
        symbolName: systemSymbol.rawValue,
        accentColorName: accentColorName
      ),
      properties: properties
    )
  }

  func outputValidationError(language: AppLanguage) -> String? {
    guard eventType.isVoiceEvent else {
      return L10n.workflowText(.workflowRecordEventUnavailable, language: language)
    }
    if eventType == .wakeWord {
      do {
        _ = try WakeWordConfiguration(phrases: wakePhrases).validatedPhrases()
      } catch {
        return L10n.workflowWakePhraseValidationError(
          englishDescription: error.localizedDescription,
          language: language
        )
      }
    }
    if let unsupportedStep = postProcessSteps.first(where: {
      $0.kind != .normalizeWhitespace
        && $0.kind != .llmRewrite
        && $0.kind != .llmAnswer
    }) {
      return L10n.workflowUnsupportedStepError(unsupportedStep.kind.rawValue, language: language)
    }
    if postProcessSteps.contains(where: {
      ($0.kind == .llmRewrite || $0.kind == .llmAnswer)
        && $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
      return L10n.workflowText(.workflowLLMInstructionRequired, language: language)
    }
    switch destination {
    case .pasteIntoApp, .copyToClipboard, .saveToQueue, .speakOnly:
      return nil
    case .sendToWebhook:
      return L10n.externalOutputValidationMessage(.webhookUnavailable, language: language)
    case .runShortcut:
      return shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? L10n.externalOutputValidationMessage(.shortcutNameRequired, language: language)
        : nil
    case .appendToMarkdown:
      let path = markdownAppendPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty else {
        return L10n.externalOutputValidationMessage(.markdownPathRequired, language: language)
      }
      let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
      return pathExtension == "md" || pathExtension == "markdown"
        ? nil
        : L10n.externalOutputValidationMessage(.markdownPathInvalid, language: language)
    }
  }

  // MARK: - Derived

  var wakePhrases: [String] {
    wakePhrasesText
      .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" })
      .map(String.init)
      .map(WakeWordConfiguration.normalizedPhrase)
      .filter { !$0.isEmpty }
  }

  private var systemSymbol: RillSystemSymbol {
    if !eventType.isVoiceEvent {
      return .boltFill
    }
    if eventType == .hotkey {
      return .micFill
    }
    if eventType == .menuBar {
      return .menubarRectangle
    }

    switch destination {
    case .pasteIntoApp:
      return .textCursor
    case .copyToClipboard:
      return .docOnClipboard
    case .saveToQueue:
      return .squareStack3dUp
    case .speakOnly:
      return .speakerWave2
    case .sendToWebhook:
      return .point3ConnectedTrianglepathDotted
    case .runShortcut:
      return .boltBadgeAutomatic
    case .appendToMarkdown:
      return .noteText
    }
  }

  private var accentColorName: String {
    if !eventType.isVoiceEvent {
      return "orange"
    }
    switch recognizer {
    case .automatic:
      return "blue"
    case .localSpeech:
      return "teal"
    }
  }

}

private extension WorkflowEditorDraft.DestinationChoice {
  func outputConfiguration(from draft: WorkflowEditorDraft) -> WorkflowOutputParameters {
    switch self {
    case .pasteIntoApp, .copyToClipboard: .init(excludeFromCapture: draft.excludeFromWorkflowCapture)
    case .saveToQueue: .init(collections: draft.targetGroupID.map { [$0] } ?? [], buffer: "speech", excludeFromCapture: draft.excludeFromWorkflowCapture)
    case .speakOnly: .init(voice: draft.speechVoice.rawValue)
    case .sendToWebhook: .init(webhookURL: draft.webhookURL, webhookHeadersJSON: draft.webhookHeadersJSON)
    case .runShortcut: .init(shortcutName: draft.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines))
    case .appendToMarkdown: .init(markdownPath: draft.markdownAppendPath.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

private extension WorkflowEditorDraft.RecognizerChoice {
  var providerMetadataValue: String {
    switch self {
    case .automatic:
      return "automatic"
    case .localSpeech:
      return "local-speech"
    }
  }
}
