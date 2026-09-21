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
    public let outputConfigurations: [WorkflowActionConfiguration]
    public let steps: [CompiledWorkflowStep]
    public let declaration: WorkflowPlan
    public let recognizerID: String?
    public let recognitionHints: RecognitionHints
    public let replacementRules: [VocabularyRule]
    public let activeVocabularyCollectionCount: Int
    public let validHotwordCount: Int
    public let omittedHotwordCount: Int
    public let rejectedHotwordCount: Int
    public let recognizerAcceptsHotwords: Bool

    init(
        outputConfigurations: [WorkflowActionConfiguration],
        steps: [CompiledWorkflowStep],
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
        self.outputConfigurations = outputConfigurations
        self.steps = steps
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
        input inputOverride: WorkflowInputKind? = nil,
        allowEmptyOutput: Bool = false
    ) throws -> ResolvedWorkflowPlan {
        let input = try validate(workflow: workflow, input: inputOverride, allowEmptyOutput: allowEmptyOutput)
        let recognizer = input == .audio
            ? workflow.plan.setup.speechRoute.flatMap { recognizerRegistry.recognizer(for: $0.recognizerID) }
            : nil

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

        let vocabulary = VocabularyCollectionResolver.resolve(
            bindings: workflow.plan.setup.vocabularyBindings,
            collections: collections,
            context: context
        )
        let hints = VocabularyRecognitionHintResolver(
            maximumKeytermCount: maximumKeytermCount
        ).resolve(rules: vocabulary.hotwordRules)
        let acceptsHotwords = recognizer?.capabilities.supports(.keyterm) ?? false

        var nextIndex = 0
        let steps = try CompiledWorkflowStep.compile(workflow.plan.process.steps, nextIndex: &nextIndex)
        return ResolvedWorkflowPlan(
            outputConfigurations: try workflow.plan.output.actions.map(WorkflowActionConfiguration.init),
            steps: steps,
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
    func validate(
        workflow: WorkflowDefinition,
        input inputOverride: WorkflowInputKind? = nil,
        allowEmptyOutput: Bool = false
    ) throws -> WorkflowInputKind {
        let input = inputOverride ?? workflow.inputKind
        let plan = inputOverride == .text && workflow.inputKind == .audio
            ? workflow.plan.acceptingTextInput() : workflow.plan
        do { try WorkflowPlanValidator.validate(plan, input: input, requireOutput: !allowEmptyOutput) }
        catch { throw WorkflowPlanCompilationError.invalidPlan(error.localizedDescription) }
        if input == .audio, let route = plan.setup.speechRoute,
           recognizerRegistry.recognizer(for: route.recognizerID) == nil {
            throw WorkflowPlanCompilationError.missingRecognizer(route.recognizerID)
        }
        for step in workflow.plan.process.allSteps {
            guard let kind = step.kind.postProcessKind else { continue }
            guard transformerRegistry.transformer(for: kind) != nil else {
                throw WorkflowPlanCompilationError.missingTransformer(kind)
            }
        }
        for action in workflow.plan.output.actions {
            do { _ = try WorkflowActionConfiguration(action) }
            catch { throw WorkflowPlanCompilationError.invalidPlan(error.localizedDescription) }
            guard actionRegistry.action(for: action.id) != nil else {
                throw WorkflowPlanCompilationError.missingAction(action.id)
            }
        }

        return input
    }

}
