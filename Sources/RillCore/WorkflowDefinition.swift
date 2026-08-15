import Foundation

public struct VoiceProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var defaultRecognizerID: String
    public var defaultLocale: String

    public init(
        id: UUID = UUID(),
        name: String,
        defaultRecognizerID: String,
        defaultLocale: String = "en-US"
    ) {
        self.id = id
        self.name = name
        self.defaultRecognizerID = defaultRecognizerID
        self.defaultLocale = defaultLocale
    }
}

public enum TriggerBinding: String, Codable, Sendable, Equatable {
    case manual
    case hotkey
    case menuBar
    case wakeWord
}

public enum WorkflowMetadataKey {
    public static let targetRecordCollectionIDs = "record.target-collection-ids"
    public static let excludeOutputFromRecordCapture = "record.exclude-output-from-capture"
    public static let catalog = "catalog"
    public static let triggerGesture = "trigger.gesture"
    public static let excludeOutputFromWorkflowCapture = "clipboard.excludeOutputFromWorkflowCapture"
    public static let recognizerSelectionMode = "recognizer.selection"
    public static let localSpeechModelOverride = "recognizer.local.model"
    public static let livePreviewEnabled = "recognizer.live_preview"
    public static let livePreviewPlacement = "recognizer.live_preview_placement"
    public static let streamingProfile = "recognizer.streaming_profile"
    /// Read-only migration key for workflows created before sherpa-onnx became
    /// the local speech engine.
    public static let legacyWhisperKitModelOverride = "recognizer.whisperkit.model"
    public static let languageOverride = "recognizer.language"
    public static let exclusiveGroup = "workflow.exclusive-group"
    public static let builtinKind = "workflow.builtin-kind"
    public static let defaultEnabled = "workflow.default-enabled"
    public static let availability = "workflow.availability"
    public static let speechMode = "workflow.speech-mode"
    public static let legacyTargetRecordCollectionID = "clipboard.target-group-id"
    public static let settingsExposeOutputMode = "settings.expose.output-mode"
    public static let textStyle = "workflow.text-style"
    public static let legacyEventType = "eventType"
    public static let legacySourceCollectionID = "sourceGroupID"
    public static let legacyExcludePolishTag = "excludePolishTag"
    public static let legacyGroupActionKind = "groupActionKind"
}

public enum LivePreviewPlacement: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case overlay
    case cursor

    public var id: String { rawValue }
}

public extension WorkflowDefinition {
    var livePreviewIsEnabled: Bool {
        let value = metadata[WorkflowMetadataKey.livePreviewEnabled]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value else { return true }
        return !["false", "no", "0", "off"].contains(value)
    }

    /// The run-time placement. A disabled preview deliberately resolves to the
    /// overlay so cursor mutation can never be armed by a retained preference.
    var resolvedLivePreviewPlacement: LivePreviewPlacement {
        guard livePreviewIsEnabled else { return .overlay }
        return metadata[WorkflowMetadataKey.livePreviewPlacement]
            .flatMap(LivePreviewPlacement.init(rawValue:))
            ?? .overlay
    }
}

public enum WorkflowAvailability: String, Codable, Sendable, Equatable {
    case active
    case planned
}

public enum SpeechWorkflowMode: String, Codable, Sendable, Equatable {
    case streamingDirect = "streaming-direct"
    case dedicatedTranscription = "dedicated-transcription"
    case transcriptionWithRewrite = "transcription-with-rewrite"
    case voiceAssistant = "voice-assistant"
}

/// A validated, content-free record collection automation declaration.
public struct RecordCollectionAutomationConfiguration: Sendable, Equatable {
    public var rule: RecordCollectionTriggerRule
    public var actionKind: RecordCollectionActionKind

    public init(rule: RecordCollectionTriggerRule, actionKind: RecordCollectionActionKind) {
        self.rule = rule
        self.actionKind = actionKind
    }
}

/// Fixed parse failures for the legacy metadata-backed record collection automation format.
public enum RecordCollectionAutomationConfigurationError: Error, Sendable, Equatable {
    case invalidEventType
    case missingSourceCollectionID
    case invalidSourceCollectionID
    case missingExcludePolishTag
    case invalidExcludePolishTag
    case missingActionKind
    case invalidActionKind
}

public enum BuiltinWorkflowRoutingValue {
    public static let catalog = "builtin"
    public static let pushToTalkGesture = "fn-hold"
    public static let pushToTalkKindPrefix = "push-to-talk"
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

public extension WorkflowDefinition {
    var availability: WorkflowAvailability {
        guard let rawValue = metadata[WorkflowMetadataKey.availability] else {
            return .active
        }
        return WorkflowAvailability(rawValue: rawValue) ?? .planned
    }

    var speechMode: SpeechWorkflowMode? {
        metadata[WorkflowMetadataKey.speechMode]
            .flatMap(SpeechWorkflowMode.init(rawValue:))
    }

    var isEnabledByDefault: Bool {
        guard let rawValue = metadata[WorkflowMetadataKey.defaultEnabled] else {
            return true
        }
        return rawValue == "true"
    }

    var excludesOutputFromRecordCapture: Bool {
        guard let rawValue = metadata[WorkflowMetadataKey.excludeOutputFromRecordCapture]
            ?? metadata[WorkflowMetadataKey.excludeOutputFromWorkflowCapture]
        else {
            return true
        }
        return rawValue != "false"
    }

    var prefersAutomaticRecognizerSelection: Bool {
        plan.setup.speechRoute?.selection == .automatic
            || metadata[WorkflowMetadataKey.recognizerSelectionMode] == "auto"
    }

    var exclusiveGroupIdentifier: String? {
        metadata[WorkflowMetadataKey.exclusiveGroup]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var legacyTargetRecordCollectionID: UUID? {
        guard let rawValue = metadata[WorkflowMetadataKey.legacyTargetRecordCollectionID] else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    var targetRecordCollectionIDs: [RecordCollectionID] {
        if let rawValue = metadata[WorkflowMetadataKey.targetRecordCollectionIDs] {
            var seen: Set<RecordCollectionID> = []
            return rawValue
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { component in
                    let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let uuid = UUID(uuidString: value) else { return nil }
                    let id = RecordCollectionID(uuid)
                    return seen.insert(id).inserted ? id : nil
                }
                .prefix(RecordGraphLimits.maximumRouteCollections)
                .map { $0 }
        }
        return legacyTargetRecordCollectionID.map { [RecordCollectionID($0)] } ?? []
    }

    func usesBuiltinPushToTalkOutputRouting(
        initiatedBy binding: TriggerBinding
    ) -> Bool {
        binding == .hotkey &&
            trigger == .hotkey &&
            metadata[WorkflowMetadataKey.catalog] == BuiltinWorkflowRoutingValue.catalog &&
            metadata[WorkflowMetadataKey.triggerGesture] ==
                BuiltinWorkflowRoutingValue.pushToTalkGesture &&
            metadata[WorkflowMetadataKey.builtinKind]?
                .hasPrefix(BuiltinWorkflowRoutingValue.pushToTalkKindPrefix) == true
    }

    /// Strictly parses the legacy metadata representation of a record collection automation.
    ///
    /// Non-collection workflows return `nil`. A declaration that names a record collection event
    /// must include every policy field and every value must be valid. In
    /// particular, absent source collections do not become wildcards and absent
    /// action kinds do not silently become edit actions.
    func parseRecordCollectionAutomationConfiguration()
        throws -> RecordCollectionAutomationConfiguration? {
        guard let rawEventType = metadata[WorkflowMetadataKey.legacyEventType] else {
            return nil
        }

        let eventKind: RecordCollectionEventKind
        switch rawEventType {
        case "groupItemCreated":
            eventKind = .recordCreated
        case "groupItemEdited":
            eventKind = .recordEdited
        case "groupItemRemoved":
            eventKind = .recordRemoved
        case TriggerBinding.manual.rawValue,
             TriggerBinding.hotkey.rawValue,
             TriggerBinding.menuBar.rawValue,
             TriggerBinding.wakeWord.rawValue:
            return nil
        default:
            throw RecordCollectionAutomationConfigurationError.invalidEventType
        }

        guard let rawSourceCollectionID = metadata["sourceCollectionID"]
            ?? metadata[WorkflowMetadataKey.legacySourceCollectionID] else {
            throw RecordCollectionAutomationConfigurationError.missingSourceCollectionID
        }
        guard let rawCollectionID = UUID(uuidString: rawSourceCollectionID) else {
            throw RecordCollectionAutomationConfigurationError.invalidSourceCollectionID
        }
        let sourceCollectionID = RecordCollectionID(rawCollectionID)

        guard let rawExcludePolishTag = metadata[
            WorkflowMetadataKey.legacyExcludePolishTag
        ] else {
            throw RecordCollectionAutomationConfigurationError.missingExcludePolishTag
        }
        let excludePolishTag: Bool
        switch rawExcludePolishTag {
        case "true":
            excludePolishTag = true
        case "false":
            excludePolishTag = false
        default:
            throw RecordCollectionAutomationConfigurationError.invalidExcludePolishTag
        }

        guard let rawActionKind = metadata[WorkflowMetadataKey.legacyGroupActionKind] else {
            throw RecordCollectionAutomationConfigurationError.missingActionKind
        }
        guard let actionKind = RecordCollectionActionKind(rawValue: rawActionKind) else {
            throw RecordCollectionAutomationConfigurationError.invalidActionKind
        }

        let conditions: [RecordCollectionTriggerCondition] = excludePolishTag
            ? [.excludingTag(.polishGenerated)]
            : []
        return RecordCollectionAutomationConfiguration(
            rule: RecordCollectionTriggerRule(
                eventKind: eventKind,
                sourceCollectionID: sourceCollectionID,
                conditions: conditions
            ),
            actionKind: actionKind
        )
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
    case formalWriting
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

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "stackFirst", "stack-first", "collection-first", "collectionFirst":
            self = .collectionFirst
        case "clipboardOnly", "clipboard-only", "system-clipboard-only", "systemClipboardOnly":
            self = .systemClipboardOnly
        case "immediate":
            self = .immediate
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown delivery strategy.")
            )
        }
    }
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

public struct PostProcessStep: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: PostProcessStepKind
    public var prompt: String?

    public init(id: UUID = UUID(), kind: PostProcessStepKind, prompt: String? = nil) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
    }
}

public struct OutputActionReference: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var configuration: [String: String]

    public init(id: String, configuration: [String: String] = [:]) {
        self.id = id
        self.configuration = configuration
    }
}

public struct PipelineDeclaration: Codable, Sendable, Equatable {
    public var recognizerID: String
    public var postProcessSteps: [PostProcessStep]
    public var outputActions: [OutputActionReference]
    public var uncertaintyPolicy: UncertaintyPolicy
    public var deliveryPolicy: DeliveryPolicy

    public init(
        recognizerID: String,
        postProcessSteps: [PostProcessStep] = [],
        outputActions: [OutputActionReference],
        uncertaintyPolicy: UncertaintyPolicy = .init(),
        deliveryPolicy: DeliveryPolicy = .init(strategy: .immediate)
    ) {
        self.recognizerID = recognizerID
        self.postProcessSteps = postProcessSteps
        self.outputActions = outputActions
        self.uncertaintyPolicy = uncertaintyPolicy
        self.deliveryPolicy = deliveryPolicy
    }

    public func workflowPlan(
        metadata: [String: String] = [:]
    ) -> WorkflowPlan {
        let selection: SpeechRouteSelection =
            metadata[WorkflowMetadataKey.recognizerSelectionMode] == "auto"
            ? .automatic
            : .fixed
        var processSteps = [
            WorkflowProcessStep(kind: .recognizeSpeech),
        ]
        if uncertaintyPolicy.mode != .off {
            processSteps.append(
                WorkflowProcessStep(
                    kind: .resolveUncertainty,
                    uncertaintyPolicy: uncertaintyPolicy
                )
            )
        }
        processSteps.append(WorkflowProcessStep(kind: .applyVocabulary))
        processSteps.append(contentsOf: postProcessSteps.map(WorkflowProcessStep.init))
        return WorkflowPlan(
            setup: WorkflowSetupPhase(
                speechRoute: WorkflowSpeechRoute(
                    selection: selection,
                    recognizerID: recognizerID,
                    language: metadata[WorkflowMetadataKey.languageOverride],
                    localModel: metadata[WorkflowMetadataKey.localSpeechModelOverride]
                )
            ),
            process: WorkflowProcessPhase(steps: processSteps),
            output: WorkflowOutputPhase(
                actions: outputActions,
                deliveryPolicy: deliveryPolicy
            )
        )
    }

    public init(plan: WorkflowPlan) {
        let uncertaintyPolicy =
            plan.process.steps.first(where: { $0.kind == .resolveUncertainty })?
            .uncertaintyPolicy
            ?? .init(mode: .off)
        self.init(
            recognizerID: plan.setup.speechRoute?.recognizerID ?? "",
            postProcessSteps: plan.process.steps.compactMap(\.postProcessStep),
            outputActions: plan.output.actions,
            uncertaintyPolicy: uncertaintyPolicy,
            deliveryPolicy: plan.output.deliveryPolicy
        )
    }
}

public struct WorkflowDefinition: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var titleKey: WorkflowTitleKey?
    public var trigger: TriggerBinding
    public var plan: WorkflowPlan
    public var ui: WorkflowUIConfig
    public var metadata: [String: String]

    /// Schema-v1 compatibility projection. New runtime code must consume `plan`.
    public var pipeline: PipelineDeclaration {
        get { PipelineDeclaration(plan: plan) }
        set { plan = newValue.workflowPlan(metadata: metadata) }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        titleKey: WorkflowTitleKey? = nil,
        trigger: TriggerBinding = .manual,
        pipeline: PipelineDeclaration,
        ui: WorkflowUIConfig,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.titleKey = titleKey
        self.trigger = trigger
        self.ui = ui
        self.metadata = metadata
        self.plan = pipeline.workflowPlan(metadata: metadata)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        titleKey: WorkflowTitleKey? = nil,
        trigger: TriggerBinding = .manual,
        plan: WorkflowPlan,
        ui: WorkflowUIConfig,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.titleKey = titleKey
        self.trigger = trigger
        self.plan = plan
        self.ui = ui
        self.metadata = metadata
    }

    public var presentation: WorkflowPresentation {
        WorkflowPresentation(fallbackName: name, titleKey: titleKey)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case titleKey
        case trigger
        case plan
        case pipeline
        case ui
        case metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        titleKey = try container.decodeIfPresent(WorkflowTitleKey.self, forKey: .titleKey)
        trigger = try container.decode(TriggerBinding.self, forKey: .trigger)
        ui = try container.decode(WorkflowUIConfig.self, forKey: .ui)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        if let decodedPlan = try container.decodeIfPresent(WorkflowPlan.self, forKey: .plan) {
            plan = decodedPlan
        } else {
            let legacyPipeline = try container.decode(PipelineDeclaration.self, forKey: .pipeline)
            plan = legacyPipeline.workflowPlan(metadata: metadata)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(titleKey, forKey: .titleKey)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(plan, forKey: .plan)
        try container.encode(ui, forKey: .ui)
        try container.encode(metadata, forKey: .metadata)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
