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
    public static let catalog = "catalog"
    public static let triggerGesture = "trigger.gesture"
    public static let excludeOutputFromWorkflowCapture = "clipboard.excludeOutputFromWorkflowCapture"
    public static let recognizerSelectionMode = "recognizer.selection"
    public static let localSpeechModelOverride = "recognizer.local.model"
    /// Read-only migration key for workflows created before sherpa-onnx became
    /// the local speech engine.
    public static let legacyWhisperKitModelOverride = "recognizer.whisperkit.model"
    public static let languageOverride = "recognizer.language"
    public static let deepgramModelOverride = "deepgram.model"
    public static let exclusiveGroup = "workflow.exclusive-group"
    public static let builtinKind = "workflow.builtin-kind"
    public static let availability = "workflow.availability"
    public static let speechMode = "workflow.speech-mode"
    public static let targetClipboardGroupID = "clipboard.target-group-id"
    public static let settingsExposeOutputMode = "settings.expose.output-mode"
    public static let textStyle = "workflow.text-style"
    public static let legacyEventType = "eventType"
    public static let legacySourceGroupID = "sourceGroupID"
    public static let legacyExcludePolishTag = "excludePolishTag"
    public static let legacyGroupActionKind = "groupActionKind"
}

public enum WorkflowAvailability: String, Codable, Sendable, Equatable {
    case active
    case planned
}

public enum SpeechWorkflowMode: String, Codable, Sendable, Equatable {
    case streamingDirect = "streaming-direct"
    case dedicatedTranscription = "dedicated-transcription"
    case transcriptionWithRewrite = "transcription-with-rewrite"
}

/// A validated, content-free clipboard group automation declaration.
public struct ClipboardGroupAutomationConfiguration: Sendable, Equatable {
    public var rule: ClipboardGroupTriggerRule
    public var actionKind: ClipboardGroupActionKind

    public init(rule: ClipboardGroupTriggerRule, actionKind: ClipboardGroupActionKind) {
        self.rule = rule
        self.actionKind = actionKind
    }
}

/// Fixed parse failures for the legacy metadata-backed group automation format.
public enum ClipboardGroupAutomationConfigurationError: Error, Sendable, Equatable {
    case invalidEventType
    case missingSourceGroupID
    case invalidSourceGroupID
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

    var excludesOutputFromWorkflowCapture: Bool {
        guard let rawValue = metadata[WorkflowMetadataKey.excludeOutputFromWorkflowCapture] else {
            return true
        }
        return rawValue != "false"
    }

    var prefersAutomaticRecognizerSelection: Bool {
        metadata[WorkflowMetadataKey.recognizerSelectionMode] == "auto"
    }

    var exclusiveGroupIdentifier: String? {
        metadata[WorkflowMetadataKey.exclusiveGroup]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var targetClipboardGroupID: UUID? {
        guard let rawValue = metadata[WorkflowMetadataKey.targetClipboardGroupID] else {
            return nil
        }
        return UUID(uuidString: rawValue)
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

    /// Strictly parses the legacy metadata representation of a group automation.
    ///
    /// Non-group workflows return `nil`. A declaration that names a group event
    /// must include every policy field and every value must be valid. In
    /// particular, absent source groups do not become wildcards and absent
    /// action kinds do not silently become edit actions.
    func parseClipboardGroupAutomationConfiguration()
        throws -> ClipboardGroupAutomationConfiguration? {
        guard let rawEventType = metadata[WorkflowMetadataKey.legacyEventType] else {
            return nil
        }

        let eventKind: ClipboardGroupEventKind
        switch rawEventType {
        case "groupItemCreated":
            eventKind = .itemCreated
        case "groupItemEdited":
            eventKind = .itemEdited
        case "groupItemRemoved":
            eventKind = .itemRemoved
        case TriggerBinding.manual.rawValue,
             TriggerBinding.hotkey.rawValue,
             TriggerBinding.menuBar.rawValue,
             TriggerBinding.wakeWord.rawValue:
            return nil
        default:
            throw ClipboardGroupAutomationConfigurationError.invalidEventType
        }

        guard let rawSourceGroupID = metadata[WorkflowMetadataKey.legacySourceGroupID] else {
            throw ClipboardGroupAutomationConfigurationError.missingSourceGroupID
        }
        guard let sourceGroupID = UUID(uuidString: rawSourceGroupID) else {
            throw ClipboardGroupAutomationConfigurationError.invalidSourceGroupID
        }

        guard let rawExcludePolishTag = metadata[
            WorkflowMetadataKey.legacyExcludePolishTag
        ] else {
            throw ClipboardGroupAutomationConfigurationError.missingExcludePolishTag
        }
        let excludePolishTag: Bool
        switch rawExcludePolishTag {
        case "true":
            excludePolishTag = true
        case "false":
            excludePolishTag = false
        default:
            throw ClipboardGroupAutomationConfigurationError.invalidExcludePolishTag
        }

        guard let rawActionKind = metadata[WorkflowMetadataKey.legacyGroupActionKind] else {
            throw ClipboardGroupAutomationConfigurationError.missingActionKind
        }
        guard let actionKind = ClipboardGroupActionKind(rawValue: rawActionKind) else {
            throw ClipboardGroupAutomationConfigurationError.invalidActionKind
        }

        let conditions: [ClipboardGroupTriggerCondition] = excludePolishTag
            ? [.excludingTag(.polishGenerated)]
            : []
        return ClipboardGroupAutomationConfiguration(
            rule: ClipboardGroupTriggerRule(
                eventKind: eventKind,
                sourceGroupID: sourceGroupID,
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
    case formalWriting
    case translateInput
    case commandMode
    case localDictation
    case cloudDictation
    case stackDelivery
    case streamingInput
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
    case stackFirst
    case clipboardOnly
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
}

public struct WorkflowDefinition: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var titleKey: WorkflowTitleKey?
    public var trigger: TriggerBinding
    public var pipeline: PipelineDeclaration
    public var ui: WorkflowUIConfig
    public var metadata: [String: String]

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
        self.pipeline = pipeline
        self.ui = ui
        self.metadata = metadata
    }

    public var presentation: WorkflowPresentation {
        WorkflowPresentation(fallbackName: name, titleKey: titleKey)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
