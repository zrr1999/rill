import XCTest
import Testing

@testable import RillCore
@testable import RillProviders

private actor RecordIngestionSpy: RecordIngestionSink {
    private var envelopes: [RecordCaptureEnvelope] = []

    func ingest(_ envelope: RecordCaptureEnvelope) async throws -> RecordProjection {
        envelopes.append(envelope)
        let record = Record(payload: envelope.draft.payload, provenance: envelope.draft.provenance)
        return RecordProjection(
            record: record,
            metadata: RecordMetadata(recordID: record.id),
            activity: RecordActivity(recordID: record.id),
            memberships: []
        )
    }

    func captured() -> [RecordCaptureEnvelope] { envelopes }
}

final class BuiltinActionReplacementTests: XCTestCase {
    func testRecordStoreActionForwardsDraftAndMultipleCollectionTargets() async throws {
        let first = RecordCollectionID()
        let second = RecordCollectionID()
        let ingestion = RecordIngestionSpy()
        let action = RecordStoreAction(ingestion: ingestion)
        var context = makeContext()
        context.workflow.metadata[WorkflowMetadataKey.targetRecordCollectionIDs] =
            "\(first.rawValue.uuidString),\(second.rawValue.uuidString)"
        let draft = RecordDraft(
            payload: .text("stored text"),
            provenance: RecordProvenance(
                source: RecordSourceIdentity(kind: .workflow),
                workflowID: context.workflow.id,
                workflowRunID: context.runID
            )
        )

        let result = try await action.execute(record: draft, context: context)

        XCTAssertEqual(result, .storedRecord)
        let captured = await ingestion.captured()
        let envelope = try XCTUnwrap(captured.first)
        XCTAssertEqual(envelope.draft, draft)
        XCTAssertEqual(envelope.requestedCollectionIDs, [first, second])
    }

    func testTextOnlyActionBridgeRejectsNonTextPayload() async throws {
        let action = TextOnlyProbeAction()

        do {
            _ = try await action.execute(
                record: RecordDraft(
                    payload: .image(Data([1, 2, 3])),
                    provenance: RecordProvenance(
                        source: RecordSourceIdentity(kind: .workflow)
                    )
                ),
                context: makeContext()
            )
            XCTFail("Expected unsupported payload rejection")
        } catch let error as OutputActionPayloadError {
            XCTAssertEqual(
                error,
                .unsupportedPayload(actionID: "text-only", payloadKind: .image)
            )
        }
    }
}

private struct TextOnlyProbeAction: OutputAction {
    let id = "text-only"

    func execute(record: RecordDraft, context _: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        return .externalOutput(text)
    }
}

private func makeContext() -> ActionContext {
    ActionContext(
        runID: UUID(),
        workflow: WorkflowDefinition(
            name: "Store Record",
            pipeline: PipelineDeclaration(
                recognizerID: "test.recognizer",
                outputActions: [OutputActionReference(id: RecordActionID.store)]
            ),
            ui: WorkflowUIConfig(symbolName: "tray.full", accentColorName: "blue")
        ),
        contextSnapshot: .empty,
        recognitionResult: RecognitionResult(rawText: "source", bestText: "source"),
        finalText: "stored text",
        startedAt: Date(timeIntervalSince1970: 1),
        finishedAt: Date(timeIntervalSince1970: 2)
    )
}

struct BufferDraftActionTests {
    @Test func recordActionCarriesRawRecognitionAndFrozenDraftIntent() async throws {
        let ingestion = RecordIngestionSpy()
        var context = makeContext()
        let intent = BufferDraftInputIntent(entryID: .init(bufferID: RecordBuffer.speechID, sequence: 1),
            draftID: UUID(), revision: 3, selection: .init(location: 2, length: 1), editingSessionID: UUID())
        context.bufferDraftInput = intent
        let capture = RecordDraft(payload: .text("polished"), provenance: .init(source: .init(kind: .workflow)))
        _ = try await RecordStoreAction(ingestion: ingestion).execute(record: capture, context: context)
        let envelope = try #require(await ingestion.captured().first)
        #expect(envelope.draftInput == intent)
        #expect(envelope.bufferEntryID == nil)
        #expect(envelope.recognitionText == "source")
        #expect(envelope.draft.payload.textValue == "polished")
    }
}
