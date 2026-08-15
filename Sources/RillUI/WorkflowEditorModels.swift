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

        static let productionChoices: [DestinationChoice] = [
            .pasteIntoApp,
            .copyToClipboard,
            .saveToQueue,
            .speakOnly,
            .runShortcut,
            .appendToMarkdown,
        ]

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
            switch workflow.plan.output.actions.first?.id {
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
    public var sourceCollectionID: UUID?
    public var wakePhrasesText: String

    // Condition
    public var excludePolishTag: Bool

    // Action – voice pipeline
    public var recognizer: RecognizerChoice
    public var speechLanguageOverride: String
    public var localSpeechModelOverride: String
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
    public var speechModelID: String

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
        localSpeechModelOverride: String = "",
        livePreviewEnabled: Bool = true,
        livePreviewPlacement: LivePreviewPlacement = .overlay,
        streamingProfile: String = "realtime",
        vocabularyBindings: [VocabularyCollectionBinding] = [
            VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID),
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
        speechModelID: String = "",
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
        self.localSpeechModelOverride = localSpeechModelOverride
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
        self.speechModelID = speechModelID
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

        // Determine event type from trigger or metadata
        if let eventTypeRaw = workflow.metadata["eventType"],
           let et = EventType(rawValue: eventTypeRaw) {
            self.eventType = et
        } else {
            switch workflow.trigger {
            case .hotkey: self.eventType = .hotkey
            case .manual: self.eventType = .manual
            case .menuBar: self.eventType = .menuBar
            case .wakeWord: self.eventType = .wakeWord
            }
        }
        self.wakePhrasesText =
            workflow.plan.setup.wakeWord?.phrases.joined(separator: "\n")
            ?? WakeWordConfiguration.defaultPhrases.joined(separator: "\n")

        if let sgid = workflow.metadata["sourceCollectionID"]
            ?? workflow.metadata[WorkflowMetadataKey.legacySourceCollectionID],
           let uuid = UUID(uuidString: sgid) {
            self.sourceCollectionID = uuid
        } else {
            self.sourceCollectionID = nil
        }

        self.excludePolishTag = workflow.metadata["excludePolishTag"] != "false"
        self.recognizer = recognizer
        self.speechLanguageOverride = workflow.metadata[WorkflowMetadataKey.languageOverride] ?? ""
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
            .configuration[SpeechOutputActionConfigurationKey.voice]
            .flatMap(Qwen3TTSVoice.init(rawValue:))
            ?? .vivian
        self.speechModelID =
            workflow.plan.output.actions
            .first(where: { $0.id == SpeechOutputActionID.speak })?
            .configuration[SpeechOutputActionConfigurationKey.model]
            ?? ""
        self.localSpeechModelOverride =
            workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]
            ?? workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride]
            ?? ""
        self.livePreviewEnabled =
            workflow.metadata[WorkflowMetadataKey.livePreviewEnabled] != "false"
        self.livePreviewPlacement =
            workflow.metadata[WorkflowMetadataKey.livePreviewPlacement]
            .flatMap(LivePreviewPlacement.init(rawValue:))
            ?? .overlay
        self.streamingProfile =
            workflow.metadata[WorkflowMetadataKey.streamingProfile]
            ?? (workflow.trigger == .wakeWord ? "agent" : "realtime")
        self.targetGroupID = workflow.targetRecordCollectionIDs.first?.rawValue
        let outputConfiguration = workflow.plan.output.actions.first?.configuration ?? [:]
        self.webhookURL = outputConfiguration[ExternalOutputActionConfigurationKey.webhookURL] ?? ""
        self.webhookHeadersJSON = outputConfiguration[ExternalOutputActionConfigurationKey.webhookHeadersJSON] ?? ""
        self.shortcutName = outputConfiguration[ExternalOutputActionConfigurationKey.shortcutName] ?? ""
        self.markdownAppendPath = outputConfiguration[ExternalOutputActionConfigurationKey.markdownAppendPath] ?? ""

        if let gak = workflow.metadata["groupActionKind"],
           let kind = RecordCollectionActionKind(rawValue: gak) {
            self.groupActionKind = kind
        } else {
            self.groupActionKind = .editRecord
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
        metadata["provider"] = RecognizerChoice.localSpeech.providerMetadataValue
        let trimmedLanguageOverride = speechLanguageOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelOverride = localSpeechModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputActionConfiguration = destination.outputConfiguration(from: self)

        // Event metadata
        metadata["eventType"] = eventType.rawValue
        if !eventType.isVoiceEvent {
            if let sourceCollectionID {
                metadata["sourceCollectionID"] = sourceCollectionID.uuidString
            } else {
                metadata.removeValue(forKey: "sourceCollectionID")
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
        metadata[WorkflowMetadataKey.excludeOutputFromRecordCapture] = excludeFromWorkflowCapture ? "true" : "false"
        metadata.removeValue(forKey: WorkflowMetadataKey.excludeOutputFromWorkflowCapture)
        metadata[WorkflowMetadataKey.textStyle] = textStyle.rawValue
        metadata[WorkflowMetadataKey.livePreviewEnabled] =
            livePreviewEnabled ? "true" : "false"
        metadata[WorkflowMetadataKey.livePreviewPlacement] = livePreviewPlacement.rawValue
        metadata[WorkflowMetadataKey.streamingProfile] = streamingProfile
        metadata.removeValue(forKey: WorkflowMetadataKey.recognizerSelectionMode)
        if !trimmedLanguageOverride.isEmpty {
            metadata[WorkflowMetadataKey.languageOverride] = trimmedLanguageOverride
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.languageOverride)
        }
        if !trimmedModelOverride.isEmpty {
            metadata[WorkflowMetadataKey.localSpeechModelOverride] = trimmedModelOverride
            metadata.removeValue(forKey: WorkflowMetadataKey.legacyWhisperKitModelOverride)
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.localSpeechModelOverride)
            metadata.removeValue(forKey: WorkflowMetadataKey.legacyWhisperKitModelOverride)
        }
        if destination == .saveToQueue, let targetGroupID {
            metadata[WorkflowMetadataKey.targetRecordCollectionIDs] = targetGroupID.uuidString
        } else {
            metadata.removeValue(forKey: WorkflowMetadataKey.targetRecordCollectionIDs)
        }
        metadata.removeValue(forKey: WorkflowMetadataKey.legacyTargetRecordCollectionID)

        let route = WorkflowSpeechRoute(
            selection: .fixed,
            recognizerID: RecognizerChoice.localSpeech.recognizerID,
            language: trimmedLanguageOverride.isEmpty ? nil : trimmedLanguageOverride,
            localModel:
                !trimmedModelOverride.isEmpty
                ? trimmedModelOverride
                : nil
        )
        let processSteps =
            [
                WorkflowProcessStep(kind: .recognizeSpeech),
                WorkflowProcessStep(kind: .applyVocabulary),
            ]
            + postProcessSteps.map { WorkflowProcessStep($0.toStep()) }
        var outputActions = [
            OutputActionReference(
                id: destination.outputActionID,
                configuration: outputActionConfiguration
            ),
        ]
        if speaksResult, destination != .speakOnly {
            outputActions.append(
                OutputActionReference(
                    id: SpeechOutputActionID.speak,
                    configuration: [
                        SpeechOutputActionConfigurationKey.provider:
                            SpeechSynthesisProvider.automatic.rawValue,
                        SpeechOutputActionConfigurationKey.voice:
                            speechVoice.rawValue,
                        SpeechOutputActionConfigurationKey.model:
                            speechModelID,
                    ]
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
            metadata: metadata
        )
    }

    // MARK: - Build RecordCollectionTrigger (for record collection events)

    func makeGroupTrigger(id: UUID) -> RecordCollectionTrigger? {
        guard let eventKind = eventType.groupEventKind else { return nil }
        var conditions: [RecordCollectionTriggerCondition] = []
        if excludePolishTag {
            conditions.append(.excludingTag(.polishGenerated))
        }
        var config: [String: String] = [:]
        let trimmedPrompt = actionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            config["prompt"] = trimmedPrompt
            config["action"] = "llmRewrite"
        }
        return RecordCollectionTrigger(
            id: id,
            name: name,
            eventKind: eventKind,
            sourceCollectionID: sourceCollectionID.map { RecordCollectionID($0) },
            conditions: conditions,
            actionKind: groupActionKind,
            actionConfiguration: config
        )
    }

    func outputValidationError(language: AppLanguage) -> String? {
        guard eventType.isVoiceEvent else {
            return language == .english
                ? "Record collection event workflows are unavailable until production actions and receipts are implemented."
                : "旧版记录集事件工作流已停用；生产投递请使用记录路由。"
        }
        if eventType == .wakeWord {
            do {
                _ = try WakeWordConfiguration(phrases: wakePhrases).validatedPhrases()
            } catch {
                return language == .english
                    ? error.localizedDescription
                    : "唤醒词必须包含 1–4 个不重复的有效短语。"
            }
        }
        if let unsupportedStep = postProcessSteps.first(where: {
            $0.kind != .normalizeWhitespace
                && $0.kind != .llmRewrite
                && $0.kind != .llmAnswer
        }) {
            return language == .english
                ? "The \(unsupportedStep.kind.rawValue) step is not available without a configured production transformer."
                : "尚未配置生产级 transformer，不能使用 \(unsupportedStep.kind.rawValue) 步骤。"
        }
        if postProcessSteps.contains(where: {
            ($0.kind == .llmRewrite || $0.kind == .llmAnswer)
                && $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return language == .english
                ? "Enter an instruction for every LLM rewrite step."
                : "请为每个大模型改写步骤填写指令。"
        }
        switch destination {
        case .pasteIntoApp, .copyToClipboard, .saveToQueue, .speakOnly:
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
    func outputConfiguration(from draft: WorkflowEditorDraft) -> [String: String] {
        switch self {
        case .pasteIntoApp, .copyToClipboard, .saveToQueue:
            return [:]
        case .speakOnly:
            return [
                SpeechOutputActionConfigurationKey.provider:
                    SpeechSynthesisProvider.automatic.rawValue,
                SpeechOutputActionConfigurationKey.voice:
                    draft.speechVoice.rawValue,
                SpeechOutputActionConfigurationKey.model:
                    draft.speechModelID,
            ]
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
            return "local-speech"
        }
    }
}
