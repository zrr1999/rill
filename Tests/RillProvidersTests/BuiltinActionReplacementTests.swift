import XCTest
@testable import RillCore
@testable import RillProviders

private actor ReplacementStackSpy: DeliveryStackSink {
    struct Snapshot: Equatable {
        var pushes = 0
        var replacementSubjects: [ClipboardItemDryRunSubject] = []
    }

    private let replacementResult: ClipboardItemReplacementResult
    private let pushResult: ClipboardStorageMutationResult
    private var state = Snapshot()

    init(
        replacementResult: ClipboardItemReplacementResult,
        pushResult: ClipboardStorageMutationResult = .accepted(evictedHistoryItemCount: 0)
    ) {
        self.replacementResult = replacementResult
        self.pushResult = pushResult
    }

    @discardableResult
    func push(_: DeliveryItem) async -> ClipboardStorageMutationResult {
        state.pushes += 1
        return pushResult
    }

    func replace(
        _: DeliveryItem,
        replacing subject: ClipboardItemDryRunSubject
    ) async -> ClipboardItemReplacementResult {
        state.replacementSubjects.append(subject)
        return replacementResult
    }

    func popNext() async -> DeliveryItem? { nil }

    func snapshot() async -> DeliveryStackSnapshot {
        DeliveryStackSnapshot(count: state.pushes, topPreview: nil)
    }

    func current() -> Snapshot { state }
}

final class BuiltinActionReplacementTests: XCTestCase {
    func testPushToStackReplacementUsesExactSubjectAndFailsClosedOnDrift() async throws {
        let subject = makeReplacementSubject()
        let stack = ReplacementStackSpy(replacementResult: .sourceChanged)
        let action = PushToStackAction(stack: stack)

        let result = try await action.execute(
            text: "replacement",
            context: makeReplacementContext(subject: subject)
        )

        guard case .failed(let message) = result else {
            return XCTFail("Expected a failed exact replacement, got \(result)")
        }
        XCTAssertTrue(message.contains("changed before replacement"))
        let snapshot = await stack.current()
        XCTAssertEqual(snapshot.pushes, 0)
        XCTAssertEqual(snapshot.replacementSubjects, [subject])
    }

    func testPushToStackReplacementReportsSuccessOnlyAfterCASCommits() async throws {
        let subject = makeReplacementSubject()
        let stack = ReplacementStackSpy(replacementResult: .replaced)
        let action = PushToStackAction(stack: stack)

        let result = try await action.execute(
            text: "replacement",
            context: makeReplacementContext(subject: subject)
        )

        XCTAssertEqual(result, .pushedToStack)
        let snapshot = await stack.current()
        XCTAssertEqual(snapshot.pushes, 0)
        XCTAssertEqual(snapshot.replacementSubjects, [subject])
    }

    func testPushToStackDoesNotReportSuccessWhenStorageRejectsIngress() async throws {
        let stack = ReplacementStackSpy(
            replacementResult: .replaced,
            pushResult: .rejected(.activeItemLimitReached)
        )
        let action = PushToStackAction(stack: stack)
        var context = makeReplacementContext(subject: makeReplacementSubject())
        context.sourceClipboardItemSubject = nil

        let result = try await action.execute(text: "new item", context: context)

        guard case .failed(let message) = result else {
            return XCTFail("Expected storage rejection, got \(result)")
        }
        let snapshot = await stack.current()
        XCTAssertEqual(message, "The local clipboard is full of active or in-use items.")
        XCTAssertEqual(snapshot.pushes, 1)
    }
}

private func makeReplacementSubject() -> ClipboardItemDryRunSubject {
    ClipboardItemDryRunSubject(
        itemID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        itemVersion: ClipboardItemVersion(
            generationID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            revision: 7
        ),
        groupID: ClipboardGroup.defaultGroupID,
        contentKind: .text,
        hasTransferableContent: true
    )
}

private func makeReplacementContext(
    subject: ClipboardItemDryRunSubject
) -> ActionContext {
    let workflow = WorkflowDefinition(
        name: "Replace source",
        pipeline: PipelineDeclaration(
            recognizerID: "test.recognizer",
            outputActions: [OutputActionReference(id: "stack.push")]
        ),
        ui: WorkflowUIConfig(symbolName: "square.stack.3d.up", accentColorName: "blue")
    )
    return ActionContext(
        runID: UUID(),
        workflow: workflow,
        contextSnapshot: .empty,
        recognitionResult: RecognitionResult(rawText: "source", bestText: "source"),
        finalText: "replacement",
        sourceClipboardItemSubject: subject,
        startedAt: Date(timeIntervalSince1970: 1),
        finishedAt: Date(timeIntervalSince1970: 2)
    )
}
