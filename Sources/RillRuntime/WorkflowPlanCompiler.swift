import Foundation
import RillCore

public enum WorkflowPlanCompilationError: Error, LocalizedError, Sendable, Equatable {
    case invalidPlan(String)
    case missingVocabularyCollection(UUID)
    case duplicateVocabularyCollection(UUID)
    case duplicateVocabularyEntry(UUID)
    case missingRecognizer(String)
    case missingTransformer(PostProcessStepKind)
    case missingAction(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlan(let message):
            return message
        case .missingVocabularyCollection(let id):
            return "No vocabulary collection is available for \(id.uuidString)."
        case .duplicateVocabularyCollection(let id):
            return "Vocabulary collection ID \(id.uuidString) is duplicated."
        case .duplicateVocabularyEntry(let id):
            return "Vocabulary entry ID \(id.uuidString) is duplicated."
        case .missingRecognizer(let id):
            return "No speech recognizer is registered for \(id)."
        case .missingTransformer(let kind):
            return "No text transformer is registered for \(kind.rawValue)."
        case .missingAction(let id):
            return "No output action is registered for \(id)."
        }
    }
}

public struct ResolvedWorkflowPlan: Sendable, Equatable {
    public var declaration: WorkflowPlan
    public var recognizerID: String?
    public var recognitionHints: RecognitionHints
    public var replacementRules: [VocabularyRule]
    public var activeVocabularyCollectionCount: Int
    public var validHotwordCount: Int
    public var omittedHotwordCount: Int
    public var rejectedHotwordCount: Int
    public var recognizerAcceptsHotwords: Bool

    public init(
        declaration: WorkflowPlan,
        recognizerID: String?,
        recognitionHints: RecognitionHints,
        replacementRules: [VocabularyRule],
        activeVocabularyCollectionCount: Int,
        validHotwordCount: Int,
        omittedHotwordCount: Int,
        rejectedHotwordCount: Int,
        recognizerAcceptsHotwords: Bool
    ) {
        self.declaration = declaration
        self.recognizerID = recognizerID
        self.recognitionHints = recognitionHints
        self.replacementRules = replacementRules
        self.activeVocabularyCollectionCount = activeVocabularyCollectionCount
        self.validHotwordCount = validHotwordCount
        self.omittedHotwordCount = omittedHotwordCount
        self.rejectedHotwordCount = rejectedHotwordCount
        self.recognizerAcceptsHotwords = recognizerAcceptsHotwords
    }
}

public struct WorkflowPlanCompiler: Sendable {
    private let recognizerRegistry: SpeechRecognizerRegistry
    private let transformerRegistry: TextTransformerRegistry
    private let actionRegistry: OutputActionRegistry
    private let maximumKeytermCount: Int

    public init(
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        actionRegistry: OutputActionRegistry,
        maximumKeytermCount: Int = 50
    ) {
        self.recognizerRegistry = recognizerRegistry
        self.transformerRegistry = transformerRegistry
        self.actionRegistry = actionRegistry
        self.maximumKeytermCount = maximumKeytermCount
    }

    public func compile(
        workflow: WorkflowDefinition,
        collections: [VocabularyCollection],
        context: VocabularyRuleContext,
        input inputOverride: WorkflowPlanInput? = nil,
        allowEmptyOutput: Bool = false
    ) throws -> ResolvedWorkflowPlan {
        let hasRecognitionStep = workflow.plan.process.steps.contains {
            $0.kind == .recognizeSpeech
        }
        let inferredInput: WorkflowPlanInput =
            workflow.plan.setup.speechRoute != nil || hasRecognitionStep ? .audio : .text
        let input = inputOverride ?? inferredInput
        var validationPlan = workflow.plan
        if inputOverride == .text, inferredInput == .audio {
            validationPlan.setup.speechRoute = nil
            validationPlan.process.steps.removeAll {
                $0.kind == .recognizeSpeech || $0.kind == .resolveUncertainty
            }
        }
        do {
            try WorkflowPlanValidator.validate(
                validationPlan,
                input: input,
                requireOutput: !allowEmptyOutput
            )
        } catch {
            throw WorkflowPlanCompilationError.invalidPlan(error.localizedDescription)
        }

        let recognizer: (any SpeechRecognizer)?
        if input == .audio, let route = workflow.plan.setup.speechRoute {
            guard let registered = recognizerRegistry.recognizer(for: route.recognizerID) else {
                throw WorkflowPlanCompilationError.missingRecognizer(route.recognizerID)
            }
            recognizer = registered
        } else {
            recognizer = nil
        }

        var collectionIDs = Set<UUID>()
        var entryIDs = Set<UUID>()
        for collection in collections {
            guard collectionIDs.insert(collection.id).inserted else {
                throw WorkflowPlanCompilationError.duplicateVocabularyCollection(
                    collection.id
                )
            }
            for entry in collection.entries {
                guard entryIDs.insert(entry.id).inserted else {
                    throw WorkflowPlanCompilationError.duplicateVocabularyEntry(entry.id)
                }
            }
        }
        for binding in workflow.plan.setup.vocabularyBindings
        where !collectionIDs.contains(binding.collectionID) {
            throw WorkflowPlanCompilationError.missingVocabularyCollection(binding.collectionID)
        }

        for step in workflow.plan.process.steps {
            guard let kind = step.kind.postProcessKind else { continue }
            guard transformerRegistry.transformer(for: kind) != nil else {
                throw WorkflowPlanCompilationError.missingTransformer(kind)
            }
        }
        for action in workflow.plan.output.actions {
            guard actionRegistry.action(for: action.id) != nil else {
                throw WorkflowPlanCompilationError.missingAction(action.id)
            }
        }

        let vocabulary = VocabularyCollectionResolver.resolve(
            bindings: workflow.plan.setup.vocabularyBindings,
            collections: collections,
            context: context
        )
        let hints = VocabularyRecognitionHintResolver(
            maximumKeytermCount: maximumKeytermCount
        ).resolve(rules: vocabulary.hotwordRules)
        let acceptsHotwords = recognizer?.capabilities.supports(.keyterm) ?? false

        return ResolvedWorkflowPlan(
            declaration: workflow.plan,
            recognizerID: recognizer?.id,
            recognitionHints: acceptsHotwords ? hints.hints : .empty,
            replacementRules: vocabulary.replacementRules,
            activeVocabularyCollectionCount: vocabulary.activeCollectionCount,
            validHotwordCount: hints.validKeytermCount,
            omittedHotwordCount: hints.omittedKeytermCount,
            rejectedHotwordCount: hints.rejectedKeytermCount,
            recognizerAcceptsHotwords: acceptsHotwords
        )
    }
}
