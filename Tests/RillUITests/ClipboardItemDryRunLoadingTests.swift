import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor ClipboardDryRunNonCooperativeLoad {
    private var startedIDs: [UUID] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load(
        requestID: UUID,
        suspended: Bool,
        result: PreparedClipboardItemDryRun
    ) async -> PreparedClipboardItemDryRun {
        startedIDs.append(requestID)
        if suspended {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return result
    }

    func waitUntilFirstLoadStarts() async {
        if !startedIDs.isEmpty { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeFirstLoad() {
        continuation?.resume()
        continuation = nil
    }

    func started() -> [UUID] { startedIDs }
}

final class ClipboardItemDryRunLoadingTests: XCTestCase {
    @MainActor
    func testCoordinatorBoundsNonCooperativeLoadsAndDeliversOnlyLatestPendingResult() async {
        let coordinator = ClipboardItemDryRunLoadCoordinator()
        let gate = ClipboardDryRunNonCooperativeLoad()
        let first = makeRequest()
        let replacedPending = makeRequest()
        let latest = makeRequest()
        let prepared = makePrepared(itemID: latest.itemID)
        let delivered = expectation(description: "latest result delivered")
        var outcomes: [ClipboardItemDryRunLoadOutcome] = []
        let deliver: ClipboardItemDryRunLoadCoordinator.Deliver = { outcome in
            outcomes.append(outcome)
            delivered.fulfill()
        }

        await coordinator.submit(
            first,
            load: {
                await gate.load(
                    requestID: first.id,
                    suspended: true,
                    result: prepared
                )
            },
            deliver: deliver
        )
        await gate.waitUntilFirstLoadStarts()
        await coordinator.submit(
            replacedPending,
            load: {
                await gate.load(
                    requestID: replacedPending.id,
                    suspended: false,
                    result: prepared
                )
            },
            deliver: deliver
        )
        await coordinator.submit(
            latest,
            load: {
                await gate.load(
                    requestID: latest.id,
                    suspended: false,
                    result: prepared
                )
            },
            deliver: deliver
        )

        let bounded = await coordinator.snapshot()
        XCTAssertEqual(bounded.inFlightCount, 1)
        XCTAssertEqual(bounded.pendingCount, 1)
        XCTAssertEqual(bounded.desiredRequestID, latest.id)

        await gate.resumeFirstLoad()
        await fulfillment(of: [delivered], timeout: 1)
        let started = await gate.started()

        XCTAssertEqual(started, [first.id, latest.id])
        XCTAssertEqual(
            outcomes,
            [.loaded(requestID: latest.id, prepared)]
        )
    }

    @MainActor
    func testCancelDropsPendingAndSuppressesLateDelivery() async {
        let coordinator = ClipboardItemDryRunLoadCoordinator()
        let gate = ClipboardDryRunNonCooperativeLoad()
        let request = makeRequest()
        let prepared = makePrepared(itemID: request.itemID)
        var outcomes: [ClipboardItemDryRunLoadOutcome] = []

        await coordinator.submit(
            request,
            load: {
                await gate.load(
                    requestID: request.id,
                    suspended: true,
                    result: prepared
                )
            },
            deliver: { outcomes.append($0) }
        )
        await gate.waitUntilFirstLoadStarts()
        await coordinator.cancel(requestID: request.id)
        let cancelled = await coordinator.snapshot()
        await gate.resumeFirstLoad()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(cancelled.pendingCount, 0)
        XCTAssertNil(cancelled.desiredRequestID)
        XCTAssertEqual(outcomes, [])
    }

    @MainActor
    func testLateCancellationCannotClearANewerRequest() async {
        let coordinator = ClipboardItemDryRunLoadCoordinator()
        let gate = ClipboardDryRunNonCooperativeLoad()
        let first = makeRequest()
        let latest = makeRequest()
        let prepared = makePrepared(itemID: latest.itemID)
        let delivered = expectation(description: "newer result delivered")
        var outcomes: [ClipboardItemDryRunLoadOutcome] = []

        await coordinator.submit(
            first,
            load: {
                await gate.load(
                    requestID: first.id,
                    suspended: true,
                    result: prepared
                )
            },
            deliver: { outcomes.append($0) }
        )
        await gate.waitUntilFirstLoadStarts()
        await coordinator.submit(
            latest,
            load: {
                await gate.load(
                    requestID: latest.id,
                    suspended: false,
                    result: prepared
                )
            },
            deliver: {
                outcomes.append($0)
                delivered.fulfill()
            }
        )

        await coordinator.cancel(requestID: first.id)
        let afterLateCancellation = await coordinator.snapshot()
        await gate.resumeFirstLoad()
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(afterLateCancellation.desiredRequestID, latest.id)
        XCTAssertEqual(
            outcomes,
            [.loaded(requestID: latest.id, prepared)]
        )
    }
}

private func makeRequest() -> ClipboardItemDryRunLoadRequest {
    ClipboardItemDryRunLoadRequest(
        id: UUID(),
        itemID: UUID(),
        expectedItemVersion: ClipboardItemVersion(),
        operation: .use,
        workflowID: nil
    )
}

private func makePrepared(itemID: UUID) -> PreparedClipboardItemDryRun {
    let subject = ClipboardItemDryRunSubject(
        itemID: itemID,
        itemVersion: ClipboardItemVersion(),
        groupID: ClipboardGroup.defaultGroupID,
        contentKind: .text,
        hasTransferableContent: true
    )
    return PreparedClipboardItemDryRun(
        subject: subject,
        receipt: ClipboardItemDryRunReceipt(
            workflowID: nil,
            operation: .use,
            status: .ready,
            reads: [],
            actionEffects: [],
            processingDestinations: []
        )
    )
}
