
@testable import RillCore
@testable import RillWorkflows
import Foundation
import XCTest

private struct CompilerRecognizer: SpeechRecognizer {
    let id: String
    let capabilities: SpeechRecognizerCapabilities

    init(id: String, acceptsHotwords: Bool) {
        self.id = id
        capabilities = SpeechRecognizerCapabilities(
            supportedHintKinds: acceptsHotwords ? [.keyterm] : []
        )
    }

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        RecognitionResult(rawText: "", bestText: "")
    }
}

private struct CompilerTransformer: TextTransformer {
    let id = "compiler.transformer"
    let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace]

    func transform(
        text: String,
        step: PostProcessStep,
        context: TransformContext
    ) async throws -> String {
        text
    }
}

private struct CompilerAction: OutputAction {
    var id = "compiler.action"

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        return .copiedToClipboard
    }
}

final class WorkflowPlanCompilerTests: XCTestCase {
    func testDuplicateRegistrationsFailWithoutSelectingAProvider() throws {
        let recognizer = CompilerRecognizer(id: "same", acceptsHotwords: true)
        let recognizers = SpeechRecognizerRegistry(recognizers: [recognizer, recognizer])
        XCTAssertNil(recognizers.recognizer(for: "same"))
        XCTAssertThrowsError(try recognizers.validate()) {
            XCTAssertEqual($0 as? ComponentRegistrationError, .duplicateRecognizer("same"))
        }
        let actions = OutputActionRegistry(actions: [CompilerAction(), CompilerAction()])
        XCTAssertNil(actions.action(for: "compiler.action"))
        XCTAssertThrowsError(try actions.validate()) {
            XCTAssertEqual($0 as? ComponentRegistrationError, .duplicateOutput("compiler.action"))
        }
        let transformers = TextTransformerRegistry(transformers: [CompilerTransformer(), CompilerTransformer()])
        XCTAssertNil(transformers.transformer(for: .normalizeWhitespace))
        XCTAssertThrowsError(try transformers.validate()) {
            XCTAssertEqual($0 as? ComponentRegistrationError, .duplicateTransformer("compiler.transformer"))
        }
        let compiler = WorkflowPlanCompiler(recognizerRegistry: recognizers,
            transformerRegistry: .init(transformers: []), actionRegistry: .init(actions: []))
        XCTAssertThrowsError(try compiler.compile(workflow: makeVoiceWorkflow(collectionID: UUID()),
                                                collections: [], context: .init())) {
            XCTAssertEqual($0 as? ComponentRegistrationError, .duplicateRecognizer("same"))
        }
    }

    func testRepeatedOutputIDsKeepIndependentFrozenConfiguration() throws {
        let compiler = WorkflowPlanCompiler(recognizerRegistry: .init(recognizers: []),
            transformerRegistry: .init(transformers: []),
            actionRegistry: .init(actions: [CompilerAction(id: ExternalOutputActionID.shortcutsRun)]))
        var workflow = WorkflowDefinition(name: "Two shortcuts", plan: WorkflowPlan(
            setup: .init(), process: .init(steps: []), output: .init(actions: [
                .init(id: ExternalOutputActionID.shortcutsRun, configuration: [ExternalOutputActionConfigurationKey.shortcutName: "First"]),
                .init(id: ExternalOutputActionID.shortcutsRun, configuration: [ExternalOutputActionConfigurationKey.shortcutName: "Second"])
            ])), ui: .init(symbolName: "square", accentColorName: "blue"))
        let compiled = try compiler.compile(workflow: workflow, collections: [], context: .init())
        workflow.plan.output.actions.removeAll()
        XCTAssertEqual(compiled.outputConfigurations, [.shortcut(name: "First"), .shortcut(name: "Second")])
        XCTAssertEqual(compiled.declaration.output.actions.count, 2)
    }

    func testRemoteRecognizerReceivesFrozenApplicableVocabulary() throws {
        let compiler = makeCompiler(acceptsHotwords: true)
        let collectionID = UUID()
        var collection = makeCollection(id: collectionID)
        let workflow = makeVoiceWorkflow(collectionID: collectionID)

        let resolved = try compiler.compile(
            workflow: workflow,
            collections: [collection],
            context: VocabularyRuleContext(locale: "zh-CN")
        )
        collection.entries.removeAll()

        XCTAssertEqual(resolved.recognitionHints.keyterms, ["VoxType"])
        XCTAssertEqual(resolved.replacementRules.map(\.replacement), ["Rill"])
        XCTAssertEqual(resolved.activeVocabularyCollectionCount, 1)
        XCTAssertTrue(resolved.recognizerAcceptsHotwords)
    }

    func testLocalRecognizerSkipsHintsButKeepsReplacementRules() throws {
        let compiler = makeCompiler(acceptsHotwords: false)
        let collectionID = UUID()
        let resolved = try compiler.compile(
            workflow: makeVoiceWorkflow(collectionID: collectionID),
            collections: [makeCollection(id: collectionID)],
            context: VocabularyRuleContext(locale: "zh-CN")
        )

        XCTAssertTrue(resolved.recognitionHints.keyterms.isEmpty)
        XCTAssertEqual(resolved.validHotwordCount, 1)
        XCTAssertEqual(resolved.replacementRules.count, 1)
        XCTAssertFalse(resolved.recognizerAcceptsHotwords)
    }

    func testCompilerSupportsTextOnlyWorkflowWithoutRecognizer() throws {
        let collectionID = UUID()
        let workflow = WorkflowDefinition(
            name: "Clipboard Text",
            plan: WorkflowPlan(
                setup: WorkflowSetupPhase(
                    vocabularyBindings: [
                        VocabularyCollectionBinding(
                            collectionID: collectionID,
                            uses: [.textReplacement]
                        ),
                    ]
                ),
                process: WorkflowProcessPhase(
                    steps: [WorkflowProcessStep(kind: .applyVocabulary)]
                ),
                output: WorkflowOutputPhase(
                    actions: [OutputActionReference(id: "compiler.action")]
                )
            ),
            ui: WorkflowUIConfig(symbolName: "doc", accentColorName: "blue")
        )

        let resolved = try makeCompiler(acceptsHotwords: false).compile(
            workflow: workflow,
            collections: [makeCollection(id: collectionID)],
            context: VocabularyRuleContext(locale: "zh-CN")
        )

        XCTAssertNil(resolved.recognizerID)
        XCTAssertEqual(resolved.replacementRules.count, 1)
    }

    func testCompilerRejectsMissingCollectionBeforeRun() {
        let missingID = UUID()

        XCTAssertThrowsError(
            try makeCompiler(acceptsHotwords: true).compile(
                workflow: makeVoiceWorkflow(collectionID: missingID),
                collections: [],
                context: VocabularyRuleContext(locale: "zh-CN")
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowPlanCompilationError,
                .missingVocabularyCollection(missingID)
            )
        }
    }

    func testCompilerRejectsDuplicateCollectionIDs() {
        let collectionID = UUID()
        let workflow = makeVoiceWorkflow(collectionID: collectionID)

        XCTAssertThrowsError(
            try makeCompiler(acceptsHotwords: true).compile(
                workflow: workflow,
                collections: [
                    makeCollection(id: collectionID),
                    makeCollection(id: collectionID),
                ],
                context: VocabularyRuleContext(locale: "zh-CN")
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowPlanCompilationError,
                .duplicateVocabularyCollection(collectionID)
            )
        }
    }

    private func makeCompiler(acceptsHotwords: Bool) -> WorkflowPlanCompiler {
        WorkflowPlanCompiler(
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    CompilerRecognizer(
                        id: "compiler.recognizer",
                        acceptsHotwords: acceptsHotwords
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [CompilerTransformer()]
            ),
            actionRegistry: OutputActionRegistry(actions: [CompilerAction()])
        )
    }

    private func makeVoiceWorkflow(collectionID: UUID) -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Voice",
            plan: WorkflowPlan(
                setup: WorkflowSetupPhase(
                    speechRoute: WorkflowSpeechRoute(
                        recognizerID: "compiler.recognizer"
                    ),
                    vocabularyBindings: [
                        VocabularyCollectionBinding(collectionID: collectionID),
                    ]
                ),
                process: WorkflowProcessPhase(
                    steps: [
                        WorkflowProcessStep(kind: .recognizeSpeech),
                        WorkflowProcessStep(kind: .applyVocabulary),
                        WorkflowProcessStep(kind: .normalizeWhitespace),
                    ]
                ),
                output: WorkflowOutputPhase(
                    actions: [OutputActionReference(id: "compiler.action")]
                )
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }

    private func makeCollection(id: UUID) -> VocabularyCollection {
        VocabularyCollection(
            id: id,
            name: "Personal",
            entries: [
                VocabularyEntry(
                    content: .hotword(phrase: "VoxType"),
                    priority: 10
                ),
                VocabularyEntry(
                    content: .replacement(
                        pattern: "voxtype",
                        replacement: "Rill",
                        matchMode: .wordBoundary,
                        caseSensitive: false
                    )
                ),
            ]
        )
    }
}
