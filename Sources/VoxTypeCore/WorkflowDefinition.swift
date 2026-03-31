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
    public static let excludeOutputFromWorkflowCapture = "clipboard.excludeOutputFromWorkflowCapture"
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
    var excludesOutputFromWorkflowCapture: Bool {
        guard let rawValue = metadata[WorkflowMetadataKey.excludeOutputFromWorkflowCapture] else {
            return true
        }
        return rawValue != "false"
    }
}

public enum WorkflowTitleKey: String, Codable, Sendable, Equatable {
    case ambiguousDemoStack
    case directDemoClipboard
    case rewriteDemoStack
    case pushToTalkCapture
    case localDictation
    case cloudDictation
    case stackDelivery
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
