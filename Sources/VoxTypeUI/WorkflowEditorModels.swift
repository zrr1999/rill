import Foundation
import VoxTypeCore

public struct WorkflowEditorDraft: Equatable, Sendable {
    public enum RecognizerChoice: String, CaseIterable, Identifiable, Codable, Sendable {
        case localSpeech
        case cloudSpeech

        public var id: String { rawValue }

        var recognizerID: String {
            switch self {
            case .localSpeech:
                return "whisperkit.local"
            case .cloudSpeech:
                return "deepgram.prerecorded"
            }
        }

        init?(recognizerID: String) {
            switch recognizerID {
            case "whisperkit.local":
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

        public var id: String { rawValue }

        var outputActionID: String {
            switch self {
            case .pasteIntoApp:
                return "inject.text"
            case .copyToClipboard:
                return "clipboard.copy"
            case .saveToQueue:
                return "stack.push"
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
            default:
                return nil
            }
        }
    }

    public var name: String
    public var recognizer: RecognizerChoice
    public var destination: DestinationChoice
    public var trigger: TriggerBinding
    public var normalizeWhitespace: Bool
    public var excludeFromWorkflowCapture: Bool
    public var whisperKitModelOverride: String

    public init(
        name: String = "",
        recognizer: RecognizerChoice = .localSpeech,
        destination: DestinationChoice = .pasteIntoApp,
        trigger: TriggerBinding = .manual,
        normalizeWhitespace: Bool = true,
        excludeFromWorkflowCapture: Bool = true,
        whisperKitModelOverride: String = ""
    ) {
        self.name = name
        self.recognizer = recognizer
        self.destination = destination
        self.trigger = trigger
        self.normalizeWhitespace = normalizeWhitespace
        self.excludeFromWorkflowCapture = excludeFromWorkflowCapture
        self.whisperKitModelOverride = whisperKitModelOverride
    }

    init?(workflow: WorkflowDefinition) {
        guard
            let recognizer = RecognizerChoice(recognizerID: workflow.pipeline.recognizerID),
            let destination = DestinationChoice(workflow: workflow),
            workflow.trigger != .wakeWord
        else {
            return nil
        }

        self.name = workflow.name
        self.recognizer = recognizer
        self.destination = destination
        self.trigger = workflow.trigger
        self.normalizeWhitespace = workflow.pipeline.postProcessSteps.contains(where: { $0.kind == .normalizeWhitespace })
        self.excludeFromWorkflowCapture = workflow.excludesOutputFromWorkflowCapture
        self.whisperKitModelOverride = workflow.metadata["recognizer.whisperkit.model"] ?? ""
    }

    func makeWorkflow(
        id: UUID,
        existingMetadata: [String: String] = [:],
        hotkeyGesture: String
    ) -> WorkflowDefinition {
        var metadata = existingMetadata
        metadata[AppModel.workflowOriginMetadataKey] = AppModel.userWorkflowOriginMetadataValue
        metadata["provider"] = recognizer == .cloudSpeech ? "deepgram" : "whisperkit"
        let trimmedModelOverride = whisperKitModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if trigger == .hotkey {
            metadata["trigger.gesture"] = hotkeyGesture
        } else {
            metadata.removeValue(forKey: "trigger.gesture")
        }
        metadata[WorkflowMetadataKey.excludeOutputFromWorkflowCapture] = excludeFromWorkflowCapture ? "true" : "false"
        if recognizer == .localSpeech, !trimmedModelOverride.isEmpty {
            metadata["recognizer.whisperkit.model"] = trimmedModelOverride
        } else {
            metadata.removeValue(forKey: "recognizer.whisperkit.model")
        }

        return WorkflowDefinition(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: trigger,
            pipeline: PipelineDeclaration(
                recognizerID: recognizer.recognizerID,
                postProcessSteps: normalizeWhitespace ? [PostProcessStep(kind: .normalizeWhitespace)] : [],
                outputActions: [OutputActionReference(id: destination.outputActionID)],
                uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0, timeoutSeconds: 0),
                deliveryPolicy: DeliveryPolicy(strategy: destination.deliveryStrategy)
            ),
            ui: WorkflowUIConfig(
                symbolName: iconName,
                accentColorName: accentColorName
            ),
            metadata: metadata
        )
    }

    private var iconName: String {
        if trigger == .hotkey {
            return "mic.fill"
        }
        if trigger == .menuBar {
            return "menubar.rectangle"
        }

        switch destination {
        case .pasteIntoApp:
            return "text.cursor"
        case .copyToClipboard:
            return "doc.on.clipboard"
        case .saveToQueue:
            return "square.stack.3d.up"
        }
    }

    private var accentColorName: String {
        switch recognizer {
        case .localSpeech:
            return "teal"
        case .cloudSpeech:
            return "cyan"
        }
    }
}
