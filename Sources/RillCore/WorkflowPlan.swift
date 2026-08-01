import Foundation

public enum WorkflowPhaseKind: String, Codable, Sendable, CaseIterable {
    case setup
    case process
    case output
}

public enum SpeechRouteSelection: String, Codable, Sendable, Equatable {
    case automatic
    case fixed
}

public struct WorkflowSpeechRoute: Codable, Sendable, Equatable {
    public var selection: SpeechRouteSelection
    public var recognizerID: String
    public var language: String?
    public var localModel: String?
    public var providerModel: String?

    public init(
        selection: SpeechRouteSelection = .fixed,
        recognizerID: String,
        language: String? = nil,
        localModel: String? = nil,
        providerModel: String? = nil
    ) {
        self.selection = selection
        self.recognizerID = recognizerID
        self.language = language
        self.localModel = localModel
        self.providerModel = providerModel
    }
}

public enum VocabularyBindingUse: String, Codable, Sendable, Hashable, CaseIterable {
    case recognitionHints
    case textReplacement
}

public struct WorkflowBindingCondition: Codable, Sendable, Equatable, Hashable {
    public var bundleIdentifier: String?
    public var clipboardGroupID: UUID?
    public var locale: String?

    public init(
        bundleIdentifier: String? = nil,
        clipboardGroupID: UUID? = nil,
        locale: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.clipboardGroupID = clipboardGroupID
        self.locale = locale
    }

    public func matches(_ context: VocabularyRuleContext) -> Bool {
        if let bundleIdentifier, bundleIdentifier != context.bundleIdentifier {
            return false
        }
        if let clipboardGroupID, clipboardGroupID != context.clipboardGroupID {
            return false
        }
        if let locale, locale != context.locale {
            return false
        }
        return true
    }

    public static let any = WorkflowBindingCondition()
}

public struct VocabularyCollectionBinding: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var collectionID: UUID
    public var uses: Set<VocabularyBindingUse>
    public var condition: WorkflowBindingCondition

    public init(
        id: UUID = UUID(),
        collectionID: UUID,
        uses: Set<VocabularyBindingUse> = Set(VocabularyBindingUse.allCases),
        condition: WorkflowBindingCondition = .any
    ) {
        self.id = id
        self.collectionID = collectionID
        self.uses = uses
        self.condition = condition
    }
}

public struct WakeWordConfiguration: Codable, Sendable, Equatable {
    public enum ValidationError: Error, LocalizedError, Sendable, Equatable {
        case phraseCountOutOfRange
        case invalidPhrase
        case duplicatePhrase

        public var errorDescription: String? {
            switch self {
            case .phraseCountOutOfRange:
                return "A wake-word workflow must contain between one and four phrases."
            case .invalidPhrase:
                return "Wake phrases must be short printable text without control characters."
            case .duplicatePhrase:
                return "Wake phrases must be unique."
            }
        }
    }

    public static let defaultPhrases = ["Hey Rill"]
    public static let maximumPhraseCount = 4
    public static let maximumPhraseScalarCount = 64
    public static let maximumPhraseByteCount = 256

    public var phrases: [String]

    public init(phrases: [String] = Self.defaultPhrases) {
        self.phrases = phrases
    }

    public func validatedPhrases() throws -> [String] {
        guard (1...Self.maximumPhraseCount).contains(phrases.count) else {
            throw ValidationError.phraseCountOutOfRange
        }

        var seen = Set<String>()
        return try phrases.map { phrase in
            let normalized = Self.normalizedPhrase(phrase)
            guard
                normalized.unicodeScalars.count >= 2,
                normalized.unicodeScalars.count <= Self.maximumPhraseScalarCount,
                normalized.utf8.count <= Self.maximumPhraseByteCount,
                !normalized.unicodeScalars.contains(where: { scalar in
                    CharacterSet.controlCharacters.contains(scalar)
                        || CharacterSet.newlines.contains(scalar)
                })
            else {
                throw ValidationError.invalidPhrase
            }
            let identity = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(identity).inserted else {
                throw ValidationError.duplicatePhrase
            }
            return normalized
        }
    }

    public static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct WorkflowSetupPhase: Codable, Sendable, Equatable {
    public var speechRoute: WorkflowSpeechRoute?
    public var vocabularyBindings: [VocabularyCollectionBinding]
    public var wakeWord: WakeWordConfiguration?

    public init(
        speechRoute: WorkflowSpeechRoute? = nil,
        vocabularyBindings: [VocabularyCollectionBinding] = [],
        wakeWord: WakeWordConfiguration? = nil
    ) {
        self.speechRoute = speechRoute
        self.vocabularyBindings = vocabularyBindings
        self.wakeWord = wakeWord
    }
}

public enum WorkflowProcessStepKind: String, Codable, Sendable, Equatable, CaseIterable {
    case recognizeSpeech
    case resolveUncertainty
    case applyVocabulary
    case snippetReplacement
    case llmRewrite
    case normalizeWhitespace

    public var postProcessKind: PostProcessStepKind? {
        switch self {
        case .snippetReplacement:
            return .snippetReplacement
        case .llmRewrite:
            return .llmRewrite
        case .normalizeWhitespace:
            return .normalizeWhitespace
        case .recognizeSpeech, .resolveUncertainty, .applyVocabulary:
            return nil
        }
    }

    public init(postProcessKind: PostProcessStepKind) {
        switch postProcessKind {
        case .snippetReplacement:
            self = .snippetReplacement
        case .llmRewrite:
            self = .llmRewrite
        case .normalizeWhitespace:
            self = .normalizeWhitespace
        }
    }
}

public struct WorkflowProcessStep: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: WorkflowProcessStepKind
    public var prompt: String?
    public var uncertaintyPolicy: UncertaintyPolicy?

    public init(
        id: UUID = UUID(),
        kind: WorkflowProcessStepKind,
        prompt: String? = nil,
        uncertaintyPolicy: UncertaintyPolicy? = nil
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.uncertaintyPolicy = uncertaintyPolicy
    }

    public init(_ step: PostProcessStep) {
        self.init(
            id: step.id,
            kind: WorkflowProcessStepKind(postProcessKind: step.kind),
            prompt: step.prompt
        )
    }

    public var postProcessStep: PostProcessStep? {
        guard let kind = kind.postProcessKind else { return nil }
        return PostProcessStep(id: id, kind: kind, prompt: prompt)
    }
}

public struct WorkflowProcessPhase: Codable, Sendable, Equatable {
    public var steps: [WorkflowProcessStep]

    public init(steps: [WorkflowProcessStep] = []) {
        self.steps = steps
    }
}

public struct WorkflowOutputPhase: Codable, Sendable, Equatable {
    public var actions: [OutputActionReference]
    public var deliveryPolicy: DeliveryPolicy

    public init(
        actions: [OutputActionReference],
        deliveryPolicy: DeliveryPolicy = .init(strategy: .immediate)
    ) {
        self.actions = actions
        self.deliveryPolicy = deliveryPolicy
    }
}

public struct WorkflowPlan: Codable, Sendable, Equatable {
    public var setup: WorkflowSetupPhase
    public var process: WorkflowProcessPhase
    public var output: WorkflowOutputPhase

    public init(
        setup: WorkflowSetupPhase,
        process: WorkflowProcessPhase,
        output: WorkflowOutputPhase
    ) {
        self.setup = setup
        self.process = process
        self.output = output
    }
}

public enum WorkflowPlanInput: String, Codable, Sendable, Equatable {
    case audio
    case text
}

public enum WorkflowPlanValidationError: Error, LocalizedError, Sendable, Equatable {
    case missingSpeechRoute
    case unexpectedSpeechRoute
    case missingRecognitionStep
    case duplicateRecognitionStep
    case recognitionMustBeFirst
    case unexpectedRecognitionStep
    case resolutionRequiresRecognition
    case vocabularyMustFollowRecognition
    case duplicateProcessStepID(UUID)
    case duplicateBindingID(UUID)
    case emptyBindingUses(UUID)
    case missingOutput

    public var errorDescription: String? {
        switch self {
        case .missingSpeechRoute:
            return "A voice workflow must configure a speech route in Setup."
        case .unexpectedSpeechRoute:
            return "A text workflow must not configure a speech route."
        case .missingRecognitionStep:
            return "A voice workflow must begin Process with recognizeSpeech."
        case .duplicateRecognitionStep:
            return "A workflow can contain only one recognizeSpeech step."
        case .recognitionMustBeFirst:
            return "recognizeSpeech must be the first Process step."
        case .unexpectedRecognitionStep:
            return "A text workflow must not contain recognizeSpeech."
        case .resolutionRequiresRecognition:
            return "resolveUncertainty requires a preceding recognizeSpeech step."
        case .vocabularyMustFollowRecognition:
            return "applyVocabulary must run after recognizeSpeech in a voice workflow."
        case .duplicateProcessStepID(let id):
            return "Process contains duplicate step ID \(id.uuidString)."
        case .duplicateBindingID(let id):
            return "Setup contains duplicate vocabulary binding ID \(id.uuidString)."
        case .emptyBindingUses(let id):
            return "Vocabulary binding \(id.uuidString) does not enable any use."
        case .missingOutput:
            return "Output must contain at least one action."
        }
    }
}

public enum WorkflowPlanValidator {
    public static func validate(
        _ plan: WorkflowPlan,
        input: WorkflowPlanInput,
        requireOutput: Bool = true
    ) throws {
        guard !requireOutput || !plan.output.actions.isEmpty else {
            throw WorkflowPlanValidationError.missingOutput
        }

        var bindingIDs = Set<UUID>()
        for binding in plan.setup.vocabularyBindings {
            guard bindingIDs.insert(binding.id).inserted else {
                throw WorkflowPlanValidationError.duplicateBindingID(binding.id)
            }
            guard !binding.uses.isEmpty else {
                throw WorkflowPlanValidationError.emptyBindingUses(binding.id)
            }
        }

        var stepIDs = Set<UUID>()
        for step in plan.process.steps {
            guard stepIDs.insert(step.id).inserted else {
                throw WorkflowPlanValidationError.duplicateProcessStepID(step.id)
            }
        }

        let recognitionIndexes = plan.process.steps.indices.filter {
            plan.process.steps[$0].kind == .recognizeSpeech
        }
        switch input {
        case .audio:
            guard plan.setup.speechRoute != nil else {
                throw WorkflowPlanValidationError.missingSpeechRoute
            }
            guard !recognitionIndexes.isEmpty else {
                throw WorkflowPlanValidationError.missingRecognitionStep
            }
            guard recognitionIndexes.count == 1 else {
                throw WorkflowPlanValidationError.duplicateRecognitionStep
            }
            guard recognitionIndexes[0] == plan.process.steps.startIndex else {
                throw WorkflowPlanValidationError.recognitionMustBeFirst
            }
            if let vocabularyIndex = plan.process.steps.firstIndex(where: {
                $0.kind == .applyVocabulary
            }), vocabularyIndex < recognitionIndexes[0] {
                throw WorkflowPlanValidationError.vocabularyMustFollowRecognition
            }
        case .text:
            guard plan.setup.speechRoute == nil else {
                throw WorkflowPlanValidationError.unexpectedSpeechRoute
            }
            guard recognitionIndexes.isEmpty else {
                throw WorkflowPlanValidationError.unexpectedRecognitionStep
            }
            guard !plan.process.steps.contains(where: {
                $0.kind == .resolveUncertainty
            }) else {
                throw WorkflowPlanValidationError.resolutionRequiresRecognition
            }
        }
    }
}
