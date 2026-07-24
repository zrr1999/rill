import XCTest
@testable import RillCore
@testable import RillRuntime

private actor ClipboardDryRunContextProbe {
    private var captures = 0
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<ContextSnapshot, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func setSuspended(_ suspended: Bool) {
        shouldSuspend = suspended
    }

    func capture() async -> ContextSnapshot {
        captures += 1
        guard shouldSuspend else { return .empty }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilCaptureStarts() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        shouldSuspend = false
        continuation?.resume(returning: .empty)
        continuation = nil
    }

    func captureCount() -> Int { captures }
}

final class ClipboardItemDryRunPreparerTests: XCTestCase {
    func testDirectUsePreviewDoesNotCapturePrivacyContextOrMutateStore() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "CANARY-PRIVATE-TEXT", changeCount: 1),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
        )
        let before = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(before.items.first)
        let probe = ClipboardDryRunContextProbe()
        let preparer = ClipboardItemDryRunPreparer(
            deliveryStack: stack,
            privacyRunGate: makeDryRunGate(),
            privacyContextProvider: { await probe.capture() }
        )

        let prepared = try await preparer.preview(
            itemID: item.id,
            operation: .use,
            workflow: nil
        )
        let after = await stack.clipboardSnapshot()

        let captureCount = await probe.captureCount()
        XCTAssertEqual(captureCount, 0)
        XCTAssertEqual(after, before)
        XCTAssertEqual(prepared.receipt.status, .ready)
        XCTAssertEqual(prepared.subject.itemID, item.id)
        XCTAssertFalse(String(describing: prepared).contains("CANARY-PRIVATE-TEXT"))
    }

    func testReplayUsesInvocationAwarePrivacyPreviewWithoutRecognizerOrConfirmation() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
        )
        let snapshot = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(snapshot.items.first)
        let probe = ClipboardDryRunContextProbe()
        let preparer = ClipboardItemDryRunPreparer(
            deliveryStack: stack,
            privacyRunGate: makeDryRunGate(),
            privacyContextProvider: { await probe.capture() }
        )
        let workflow = WorkflowDefinition(
            name: "Cloud recognizer is skipped during replay",
            pipeline: PipelineDeclaration(
                recognizerID: "deepgram.prerecorded",
                outputActions: [OutputActionReference(id: "stack.push")]
            ),
            ui: WorkflowUIConfig(symbolName: "doc", accentColorName: "blue")
        )

        let prepared = try await preparer.preview(
            itemID: item.id,
            operation: .replay,
            workflow: workflow
        )
        let captureCount = await probe.captureCount()

        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(prepared.receipt.status, .ready)
        XCTAssertFalse(prepared.receipt.processingDestinations.contains(.cloudService))
        XCTAssertFalse(prepared.receipt.privacyReasons.contains(.cloudProviderSelected))
    }

    func testItemMutationDuringPrivacyEvaluationRejectsPreparedResult() async throws {
        let stack = DeliveryStack(eventBus: EventBus())
        await stack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(plainText: "before", changeCount: 1),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
        )
        let snapshot = await stack.clipboardSnapshot()
        let item = try XCTUnwrap(snapshot.items.first)
        let probe = ClipboardDryRunContextProbe()
        await probe.setSuspended(true)
        let preparer = ClipboardItemDryRunPreparer(
            deliveryStack: stack,
            privacyRunGate: makeDryRunGate(),
            privacyContextProvider: { await probe.capture() }
        )
        let workflow = WorkflowDefinition(
            name: "Replay",
            pipeline: PipelineDeclaration(
                recognizerID: "deepgram.prerecorded",
                outputActions: [OutputActionReference(id: "stack.push")]
            ),
            ui: WorkflowUIConfig(symbolName: "doc", accentColorName: "blue")
        )

        let task = Task {
            try await preparer.preview(
                itemID: item.id,
                operation: .replay,
                workflow: workflow
            )
        }
        await probe.waitUntilCaptureStarts()
        await stack.updateItemText(item.id, text: "after", captureTags: item.captureTags)
        await probe.resume()

        do {
            _ = try await task.value
            XCTFail("A changed item must reject the prepared preview.")
        } catch let error as ClipboardItemDryRunPreparationError {
            XCTAssertEqual(error, .itemChanged)
        }
    }
}

private func makeDryRunGate() -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: { .defaults },
        cloudConfirmationProvider: { _, _, _ in
            XCTFail("Advisory preview must never request confirmation.")
            return false
        }
    )
}
