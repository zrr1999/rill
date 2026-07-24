import Foundation
import RillCore

public struct WorkflowEditorDraft: Equatable, Sendable {

    // MARK: - Event Type (unified: voice triggers + group events)

    public enum EventType: String, CaseIterable, Identifiable, Codable, Sendable {
        case hotkey
        case manual
        case menuBar
        case groupItemCreated
        case groupItemEdited
        case groupItemRemoved

        public var id: String { rawValue }

        public var isVoiceEvent: Bool {
            switch self {
            case .hotkey, .manual, .menuBar: return true
            case .groupItemCreated, .groupItemEdited, .groupItemRemoved: return false
            }
        }

        var triggerBinding: TriggerBinding? {
            switch self {
            case .hotkey: return .hotkey
            case .manual: return .manual
            case .menuBar: return .menuBar
            case .groupItemCreated, .groupItemEdited, .groupItemRemoved: return nil
            }
        }

        var groupEventKind: ClipboardGroupEventKind? {
            switch self {
            case .hotkey, .manual, .menuBar: return nil
            case .groupItemCreated: return .itemCreated
            case .groupItemEdited: return .itemEdited
            case .groupItemRemoved: return .itemRemoved
            }
        }
    }

    // MARK: - Recognizer & Destination (for voice actions)

    public enum RecognizerChoice: String, CaseIterable, Identifiable, Codable, Sendable {
        case automatic
        case localSpeech
        case cloudSpeech

        public var id: String { rawValue }

        var recognizerID: String {
            switch self {
            case .automatic, .localSpeech:
                return "sherpa-onnx.local"
            case .cloudSpeech:
                return "deepgram.prerecorded"
            }
        }

        init?(recognizerID: String) {
            switch recognizerID {
            case "sherpa-onnx.local":
                self = .localSpeech
            case "deepgram.prerecorded":
                self = .cloudSpeech
            default:
                return nil
            }
        }
    }

    public enum DestinationChoice: String, CaseIterable, Identifiable, Codable, Sendable {
        case pasteIntoApp
        case copyToClipboard
        case saveToQueue
        case sendToWebhook
        case runShortcut
        case appendToMarkdown

        static let productionChoices: [DestinationChoice] = [
            .pasteIntoApp,
            .copyToClipboard,
            .saveToQueue,
            .runShortcut,
            .appendToMarkdown,
        ]

        public var id: String { rawValue }

        var outputActionID: String {
            switch self {
            case .pasteIntoApp:
                return "inject.text"
            case .copyToClipboard:
                return "clipboard.copy"
            case .saveToQueue:
                return "stack.push"
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
                return .clipboardOnly
            case .saveToQueue:
                return .stackFirst
            case .sendToWebhook, .runShortcut, .appendToMarkdown:
                return .immediate
            }
        }

        init?(workflow: WorkflowDefinition) {
            switch workflow.pipeline.outputActions.first?.id {
            case "inject.text":
                self = .pasteIntoApp
            case "clipboard.copy":
                self = .copyToClipboard
            case "stack.push":
                self = .saveToQueue
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

        public init(id: UUID = UUID(), kind: PostProcessStepKind, prompt: String = "") {
            self.id = id
            self.kind = kind
            self.prompt = prompt
        }

        init(step: PostProcessStep) {
            self.id = step.id
            self.kind = step.kind
            self.prompt = step.prompt ?? ""
        }

        func toStep() -> PostProcessStep {
            PostProcessStep(
                id: id,
                kind: kind,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            )
        }
    }

    // MARK: - Draft Properties

    public var name: String

    // Event
    public var eventType: EventType
    public var sourceGroupID: UUID?

    // Condition
    public var excludePolishTag: Bool

    // Action – voice pipeline
    public var recognizer: RecognizerChoice
    public var speechLanguageOverride: String
    public var localSpeechModelOverride: String
    public var deepgramModelOverride: String
    public var postProcessSteps: [PostProcessStepDraft]
    public var destination: DestinationChoice
    public var targetGroupID: UUID?
    public var webhookURL: String
    public var webhookHeadersJSON: String
    public var shortcutName: String
    public var markdownAppendPath: String
    public var excludeFromWorkflowCapture: Bool

    // Action – group event
    public var groupActionKind: ClipboardGroupActionKind
    public var actionPrompt: String

    // MARK: - Init

    public init(
        name: String = "",
        eventType: EventType = .hotkey,
        sourceGroupID: UUID? = nil,
        excludePolishTag: Bool = true,
        recognizer: RecognizerChoice = .automatic,
        speechLanguageOverride: String = "",
        localSpeechModelOverride: String = "",
        deepgramModelOverride: String = "",
        postProcessSteps: [PostProcessStepDraft] = [PostProcessStepDraft(kind: .normalizeWhitespace)],
        destination: DestinationChoice = .pasteIntoApp,
        targetGroupID: UUID? = nil,
        webhookURL: String = "",
        webhookHeadersJSON: String = "",
        shortcutName: String = "",
        markdownAppendPath: String = "",
        excludeFromWorkflowCapture: Bool = true,
        groupActionKind: ClipboardGroupActionKind = .editItem,
        actionPrompt: String = ""
    ) {
        self.name = name
        self.eventType = eventType
        self.sourceGroupID = sourceGroupID
        self.excludePolishTag = excludePolishTag
        self.recognizer = recognizer
        self.speechLanguageOverride = speechLanguageOverride
        self.localSpeechModelOverride = localSpeechModelOverride
        self.deepgramModelOverride = deepgramModelOverride
        self.postProcessSteps = postProcessSteps
        self.destination = destination
        self.targetGroupID = targetGroupID
        self.webhookURL = webhookURL
        self.webhookHeadersJSON = webhookHeadersJSON
        self.shortcutName = shortcutName
        self.markdownAppendPath = markdownAppendPath
        self.excludeFromWorkflowCapture = excludeFromWorkflowCapture
        self.groupActionKind = groupActionKind
        self.actionPrompt = actionPrompt
    }

    // Backward-compatible convenience
    public var normalizeWhitespace: Bool {
        postProcessSteps.contains(where: { $0.kind == .normalizeWhitespace })
    }

    // MARK: - From WorkflowDefinition (voice workflows)

    init?(workflow: WorkflowDefinition) {
        guard
            let recognizer = workflow.prefersAutomaticRecognizerSelection
                ? RecognizerChoice.automatic
                : RecognizerChoice(recognizerID: workflow.pipeline.recognizerID),
            let destination = DestinationChoice(workflow: workflow),
            destination != .sendToWebhook,
            workflow.trigger != .wakeWord
        else {
            return nil
        }

        self.name = workflow.name

        // Determine event type from trigger or metadata
        if let eventTypeRaw = workflow.metadata["eventType"],
           let et = EventType(rawValue: eventTypeRaw) {
            self.eventType = et
        } else {
            switch workflow.trigger {
            case .hotkey: self.eventType = .hotkey
            case .manual: self.eventType = .manual
            case .menuBar: self.eventType = .menuBar
            default: self.eventType = .manual
            }
        }

        if let sgid = workflow.metadata["sourceGroupID"], let uuid = UUID(uuidString: sgid) {
            self.sourceGroupID = uuid
        } else {
            self.sourceGroupID = nil
        }

        self.excludePolishTag = workflow.metadata["excludePolishTag"] != "false"
        self.recognizer = recognizer
        self.speechLanguageOverride = workflow.metadata[WorkflowMetadataKey.languageOverride] ?? ""
        self.destination = destination
        self.postProcessSteps = workflow.pipeline.postProcessSteps.map { PostProcessStepDraft(step: $0) }
        self.excludeFromWorkflowCapture = workflow.excludesOutputFromWorkflowCapture
        self.localSpeechModelOverride =
            workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]
            ?? workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride]
            ?? ""
        self.deepgramModelOverride = workflow.metadata[WorkflowMetadataKey.deepgramModelOverride] ?? ""
        self.targetGroupID = workflow.targetClipboardGroupID
        let outputConfiguration = workflow.pipeline.outputActions.first?.configuration ?? [:]
        self.webhookURL = outputConfiguration[ExternalOutputActionConfigurationKey.webhookURL] ?? ""
        self.webhookHeadersJSON = outputConfiguration[ExternalOutputActionConfigurationKey.webhookHeadersJSON] ?? ""
        self.shortcutName = outputConfiguration[ExternalOutputActionConfigurationKey.shortcutName] ?? ""
        self.markdownAppendPath = outputConfiguration[ExternalOutputActionConfigurationKey.markdownAppendPath] ?? ""

        if let gak = workflow.metadata["groupActionKind"],
           let kind = ClipboardGroupActionKind(rawValue: gak) {
            self.groupActionKind = kind
        } else {
            self.groupActionKind = .editItem
        }
        self.actionPrompt = workflow.metadata["actionPrompt"] ?? ""
    }

    // MARK: - Build WorkflowDefinition

    func makeWorkflow(
        id: UUID,
        existingMetadata: [String: String] = [:],
        hotkeyGesture: String
    ) -> WorkflowDefinition {
        var metadata = existingMetadata
        metadata[AppModel.workflowOriginMetadataKey] = AppModel.userWorkflowOriginMetadataValue
        metadata["provider"] = recognizer.providerMetadataValue
        let trimmedLanguageOverride = speechLanguageOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelOverride = localSpeechModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeepgramModelOverride = deepgramModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputActionConfiguration = destination.outputConfiguration(from: self)

        // Event metadata
        metadata["eventType"] = eventType.rawValue
        if !eventType.isVoiceEvent {
            if let sourceGroupID {
                metadata["sourceGroupID"] = sourceGroupID.uuidString
            } else {
                metadata.removeValue(forKey: "sourceGroupID")
            }
            metadata["groupActionKind"] = groupActionKind.rawValue
            let trimmedPrompt = actionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                metadata["actionPrompt"] = trimmedPrompt
            } else {
                metadata.removeValue(forKey: "actionPrompt")
            }
        }

        // Condition metadata
        metadata["excludePolishTag"] = excludePolishTag ? "true" : "false"

        let trigger = eventType.triggerBinding ?? .manual
        if trigger == .hotkey {
            metadata["trigger.gesture"] = hotkeyGesture
        } else {
            metadata.removeValue(forKey: "trigger.gesture")
        }
        metadata[WorkflowMetadataKey.excludeOutputFromWorkflowCapture] = excludeFromWorkflowCapture ? "true" : "false"
        metadata[WorkflowMetadataKey.textStyle] = textStyle.rawValue
        if recognizer == .automatic {
            metadata[WorkflowMetadataKey.recognizerSelectionMode] = "auto"
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.recognizerSelectionMode)
        }
        if !trimmedLanguageOverride.isEmpty {
            metadata[WorkflowMetadataKey.languageOverride] = trimmedLanguageOverride
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.languageOverride)
        }
        if recognizer != .cloudSpeech, !trimmedModelOverride.isEmpty {
            metadata[WorkflowMetadataKey.localSpeechModelOverride] = trimmedModelOverride
            metadata.removeValue(forKey: WorkflowMetadataKey.legacyWhisperKitModelOverride)
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.localSpeechModelOverride)
            metadata.removeValue(forKey: WorkflowMetadataKey.legacyWhisperKitModelOverride)
        }
        if recognizer != .localSpeech, !trimmedDeepgramModelOverride.isEmpty {
            metadata[WorkflowMetadataKey.deepgramModelOverride] = trimmedDeepgramModelOverride
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.deepgramModelOverride)
        }
        if destination == .saveToQueue, let targetGroupID {
            metadata[WorkflowMetadataKey.targetClipboardGroupID] = targetGroupID.uuidString
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.targetClipboardGroupID)
        }

        return WorkflowDefinition(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: trigger,
            pipeline: PipelineDeclaration(
                recognizerID: recognizer.recognizerID,
                postProcessSteps: postProcessSteps.map { $0.toStep() },
                outputActions: [OutputActionReference(
                    id: destination.outputActionID,
                    configuration: outputActionConfiguration
                )],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: destination.deliveryStrategy)
            ),
            ui: WorkflowUIConfig(
                symbolName: systemSymbol.rawValue,
                accentColorName: accentColorName
            ),
            metadata: metadata
        )
    }

    // MARK: - Build ClipboardGroupTrigger (for group events)

    func makeGroupTrigger(id: UUID) -> ClipboardGroupTrigger? {
        guard let eventKind = eventType.groupEventKind else { return nil }
        var conditions: [ClipboardGroupTriggerCondition] = []
        if excludePolishTag {
            conditions.append(.excludingTag(.polishGenerated))
        }
        var config: [String: String] = [:]
        let trimmedPrompt = actionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            config["prompt"] = trimmedPrompt
            config["action"] = "llmRewrite"
        }
        return ClipboardGroupTrigger(
            id: id,
            name: name,
            eventKind: eventKind,
            sourceGroupID: sourceGroupID,
            conditions: conditions,
            actionKind: groupActionKind,
            actionConfiguration: config
        )
    }

    func outputValidationError(language: AppLanguage) -> String? {
        guard eventType.isVoiceEvent else {
            return language == .english
                ? "Clipboard event workflows are unavailable until production actions and receipts are implemented."
                : "剪贴板事件工作流将在生产级动作与执行收据完成后开放。"
        }
        if let unsupportedStep = postProcessSteps.first(where: { $0.kind != .normalizeWhitespace }) {
            return language == .english
                ? "The \(unsupportedStep.kind.rawValue) step is not available without a configured production transformer."
                : "尚未配置生产级 transformer，不能使用 \(unsupportedStep.kind.rawValue) 步骤。"
        }
        switch destination {
        case .pasteIntoApp, .copyToClipboard, .saveToQueue:
            return nil
        case .sendToWebhook:
            return UIStrings.externalOutputValidationMessage(.webhookUnavailable, language: language)
        case .runShortcut:
            return shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? UIStrings.externalOutputValidationMessage(.shortcutNameRequired, language: language)
                : nil
        case .appendToMarkdown:
            let path = markdownAppendPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                return UIStrings.externalOutputValidationMessage(.markdownPathRequired, language: language)
            }
            let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            return pathExtension == "md" || pathExtension == "markdown"
                ? nil
                : UIStrings.externalOutputValidationMessage(.markdownPathInvalid, language: language)
        }
    }

    // MARK: - Derived

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
        case .cloudSpeech:
            return "cyan"
        }
    }

}

private extension WorkflowEditorDraft.DestinationChoice {
    func outputConfiguration(from draft: WorkflowEditorDraft) -> [String: String] {
        switch self {
        case .pasteIntoApp, .copyToClipboard, .saveToQueue:
            return [:]
        case .sendToWebhook:
            var configuration: [String: String] = [:]
            configuration[ExternalOutputActionConfigurationKey.webhookURL] = draft.webhookURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let headers = draft.webhookHeadersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headers.isEmpty {
                configuration[ExternalOutputActionConfigurationKey.webhookHeadersJSON] = headers
            }
            return configuration
        case .runShortcut:
            return [
                ExternalOutputActionConfigurationKey.shortcutName: draft.shortcutName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        case .appendToMarkdown:
            return [
                ExternalOutputActionConfigurationKey.markdownAppendPath: draft.markdownAppendPath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }
    }
}

private extension WorkflowEditorDraft.RecognizerChoice {
    var providerMetadataValue: String {
        switch self {
        case .automatic:
            return "automatic"
        case .localSpeech:
            return "sherpa-onnx"
        case .cloudSpeech:
            return "deepgram"
        }
    }
}
