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
    public var recordCollectionID: UUID?
    public var locale: String?

    public init(
        bundleIdentifier: String? = nil,
        recordCollectionID: UUID? = nil,
        locale: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.recordCollectionID = recordCollectionID
        self.locale = locale
    }

    public func matches(_ context: VocabularyRuleContext) -> Bool {
        if let bundleIdentifier, bundleIdentifier != context.bundleIdentifier {
            return false
        }
        if let recordCollectionID, recordCollectionID != context.recordCollectionID {
            return false
        }
        if let locale, locale != context.locale {
            return false
        }
        return true
    }

    public static let any = WorkflowBindingCondition()

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case recordCollectionID
        case legacyClipboardGroupID = "clipboardGroupID"
        case locale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        recordCollectionID = try container.decodeIfPresent(UUID.self, forKey: .recordCollectionID)
            ?? container.decodeIfPresent(UUID.self, forKey: .legacyClipboardGroupID)
        locale = try container.decodeIfPresent(String.self, forKey: .locale)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(recordCollectionID, forKey: .recordCollectionID)
        try container.encodeIfPresent(locale, forKey: .locale)
    }
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
    case conditional
    case recognizeSpeech
    case resolveUncertainty
    case applyVocabulary
    case snippetReplacement
    case llmRewrite
    case llmAnswer
    case normalizeWhitespace

    public var postProcessKind: PostProcessStepKind? {
        switch self {
        case .snippetReplacement:
            return .snippetReplacement
        case .llmRewrite:
            return .llmRewrite
        case .llmAnswer:
            return .llmAnswer
        case .normalizeWhitespace:
            return .normalizeWhitespace
        case .recognizeSpeech, .resolveUncertainty, .applyVocabulary, .conditional:
            return nil
        }
    }

    public init(postProcessKind: PostProcessStepKind) {
        switch postProcessKind {
        case .snippetReplacement:
            self = .snippetReplacement
        case .llmRewrite:
            self = .llmRewrite
        case .llmAnswer:
            self = .llmAnswer
        case .normalizeWhitespace:
            self = .normalizeWhitespace
        }
    }
}

public struct WorkflowProcessStep: Identifiable, Codable, Sendable, Equatable {
    public var documentID: String?
    public var nodeDescription: String?
    public var condition: WorkflowCondition?
    public var thenSteps: [WorkflowProcessStep]?
    public var elseSteps: [WorkflowProcessStep]?
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

    /// Reuses the text-processing and output plan when recognition is supplied
    /// by a stored Record or an editor sample. Nested speech steps remain invalid.
    public func acceptingTextInput() -> WorkflowPlan {
        var plan = self
        plan.setup.speechRoute = nil
        plan.process.steps.removeAll {
            $0.kind == .recognizeSpeech || $0.kind == .resolveUncertainty
        }
        return plan
    }
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
    private static func validateStructure(_ steps: [WorkflowProcessStep], depth: Int) throws {
        guard depth < 16 else { throw WorkflowDocumentError("process", "Steps exceed the nesting limit of 16.") }
        for step in steps {
            if step.kind == .conditional {
                guard let condition = step.condition, step.prompt == nil, step.uncertaintyPolicy == nil else {
                    throw WorkflowDocumentError("process", "An if step requires a condition and cannot have a prompt or recognition policy.")
                }
                try condition.validate()
                try validateStructure(step.thenSteps ?? [], depth: depth + 1)
                try validateStructure(step.elseSteps ?? [], depth: depth + 1)
            } else {
                guard step.condition == nil, step.thenSteps == nil, step.elseSteps == nil else {
                    throw WorkflowDocumentError("process", "Only if steps may declare condition, then, or else.")
                }
                if step.uncertaintyPolicy != nil, step.kind != .resolveUncertainty {
                    throw WorkflowDocumentError("process", "Only resolution steps may declare an uncertainty policy.")
                }
                if step.prompt != nil, ![.llmRewrite, .llmAnswer, .snippetReplacement].contains(step.kind) {
                    throw WorkflowDocumentError("process", "Only text generation or snippet steps may declare a prompt.")
                }
                if depth > 0, step.kind == .recognizeSpeech || step.kind == .resolveUncertainty {
                    throw WorkflowDocumentError("process", "Speech recognition and resolution must be at the workflow root.")
                }
            }
        }
    }

    public static func validate(
        _ plan: WorkflowPlan,
        input: WorkflowInputKind,
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
        try validateStructure(plan.process.steps, depth: 0)
        guard plan.process.allSteps.count <= 256, plan.output.actions.count <= 256 else {
            throw WorkflowDocumentError("workflow", "A workflow supports at most 256 process steps and 256 outputs.")
        }
        for action in plan.output.actions { try action.condition?.validate() }
        for step in plan.process.allSteps {
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
        case .text, .record:
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
