@testable import RillRecords
@testable import RillWorkflows
import RillDomainTestSupport
import Foundation
import RillCore
import RillProviders
import Testing

struct BuiltinVoiceOutputTests {
    @Test(arguments: [WorkflowTitleKey.speechRecognition, .smartCleanup, .voiceAssistant], [false, true])
    func savesFinalTextBeforeDeliveryEvenWhenDeliveryFails(
        title: WorkflowTitleKey, deliveryFails: Bool
    ) async throws {
        let builtin = try #require(BuiltinWorkflowCatalog().manifest().workflows.first { $0.titleKey == title })
        guard case .resolved(let plan) = WorkflowExecutionPlanResolver.resolve(
            builtin, initiatedBy: builtin.trigger, recognizer: .localSpeech,
            output: .builtinPasteIntoApplication
        ) else {
            Issue.record("Expected an executable built-in workflow")
            return
        }
        let workflow = plan.executionWorkflow
        let store = RecordStore()
        let probe = VoiceDeliveryProbe()
        let sinkID = title == .voiceAssistant ? SpeechOutputActionID.speak : "focused-application.insert"
        let bus = EventBus()
        let receipts = InMemoryWorkflowRunReceiptRepository()
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: [VoiceOutputTransformer()]),
            actionRegistry: OutputActionRegistry(actions: [
                RecordStoreAction(ingestion: RecordIngestionCoordinator(store: store)),
                VoiceDeliveryAction(id: sinkID, store: store, probe: probe, fails: deliveryFails),
            ]),
            candidateResolver: CandidateResolver(eventBus: bus), recordStore: store, eventBus: bus,
            runReceiptRecorder: WorkflowRunReceiptRecorder(repository: receipts, eventBus: bus)
        )

        _ = await coordinator.runReportingOutcome(
            workflow: workflow, contextSnapshot: .empty, preRecognizedText: "recognized text"
        )

        let records = try await store.snapshot().records
        #expect(records.count == 1)
        let saved = try #require(records.first)
        let deliveries = await probe.deliveries
        #expect(deliveries.count == 1)
        #expect(saved.record.payload.textValue == deliveries.first?.text)
        #expect(deliveries.first?.savedRecordCount == 1)
        #expect(saved.memberships.map(\.collectionID) == [RecordCollection.voiceInputID])
        let receipt = try #require(try await receipts.receipts(matching: .all).first)
        #expect(receipt.actionDetails.map(\.result) == [
            .storedRecord, deliveryFails ? .failed : .externalOutput,
        ])
        #expect(receipt.termination == (deliveryFails ? .partiallyCompleted(code: .processing) : .completed))
    }
}

private struct VoiceOutputContext: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct VoiceOutputTransformer: TextTransformer {
    let id = "test.voice-output-transformer"
    let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace, .llmRewrite, .llmAnswer]

    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        switch step.kind {
        case .llmRewrite: "Cleaned text"
        case .llmAnswer: "Assistant answer"
        default: text
        }
    }
}

private actor VoiceDeliveryProbe {
    struct Delivery: Sendable {
        let text: String
        let savedRecordCount: Int
    }
    var deliveries: [Delivery] = []
    func record(text: String, savedRecordCount: Int) {
        deliveries.append(Delivery(text: text, savedRecordCount: savedRecordCount))
    }
}

private struct VoiceDeliveryAction: OutputAction {
    let id: String
    let store: RecordStore
    let probe: VoiceDeliveryProbe
    let fails: Bool

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        await probe.record(text: text, savedRecordCount: try await store.snapshot().records.count)
        return fails ? .failed("Delivery unavailable") : .externalOutput("Delivered")
    }
}
