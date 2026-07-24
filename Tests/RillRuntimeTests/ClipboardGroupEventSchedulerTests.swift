import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor SchedulerReceiptOrderRepository: WorkflowRunReceiptRepository {
    private var storageByRunID: [UUID: WorkflowRunReceipt] = [:]
    private var insertionOrder: [UUID] = []

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        if let existing = storageByRunID[receipt.runID] {
            guard existing == receipt else {
                throw WorkflowRunReceiptRepositoryError.conflictingTerminalReceipt(
                    runID: receipt.runID
                )
            }
            return
        }
        storageByRunID[receipt.runID] = receipt
        insertionOrder.append(receipt.runID)
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        var receipts = insertionOrder.compactMap { storageByRunID[$0] }
        if let runID = query.runID {
            receipts = receipts.filter { $0.runID == runID }
        }
        if let workflowID = query.workflowID {
            receipts = receipts.filter { $0.workflowID == workflowID }
        }
        if let trigger = query.trigger {
            receipts = receipts.filter { $0.trigger == trigger }
        }
        if let outcome = query.outcome {
            receipts = receipts.filter { $0.outcome == outcome }
        }
        return receipts
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int { 0 }
    func deleteAllReceipts() async throws -> Int {
        let count = storageByRunID.count
        storageByRunID.removeAll()
        insertionOrder.removeAll()
        return count
    }

    func insertedReceipts() -> [WorkflowRunReceipt] {
        insertionOrder.compactMap { storageByRunID[$0] }
    }
}

private actor SchedulerRegistrationGate {
    private var hasBlocked = false
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitBeforeReturning(
        _ registrations: [ClipboardGroupWorkflowRegistration]
    ) async -> [ClipboardGroupWorkflowRegistration] {
        guard !hasBlocked else { return registrations }
        hasBlocked = true
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return registrations
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ClipboardGroupDescriptorSinkProbe: ClipboardGroupEventSink {
    private var descriptors: [ClipboardGroupEventDescriptor] = []

    func submit(
        _ descriptor: ClipboardGroupEventDescriptor
    ) async -> ClipboardGroupEventSubmissionResult {
        descriptors.append(descriptor)
        return .accepted
    }

    func snapshot() -> [ClipboardGroupEventDescriptor] {
        descriptors
    }
}

private actor BlockingClipboardGroupDescriptorSink: ClipboardGroupEventSink {
    private var descriptors: [ClipboardGroupEventDescriptor] = []
    private var firstSubmissionWasObserved = false
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSubmissionContinuation: CheckedContinuation<Void, Never>?

    func submit(
        _ descriptor: ClipboardGroupEventDescriptor
    ) async -> ClipboardGroupEventSubmissionResult {
        descriptors.append(descriptor)
        guard !firstSubmissionWasObserved else { return .accepted }
        firstSubmissionWasObserved = true
        let waiters = observationWaiters
        observationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstSubmissionContinuation = continuation
        }
        return .accepted
    }

    func waitUntilFirstSubmission() async {
        guard !firstSubmissionWasObserved else { return }
        await withCheckedContinuation { continuation in
            observationWaiters.append(continuation)
        }
    }

    func releaseFirstSubmission() {
        firstSubmissionContinuation?.resume()
        firstSubmissionContinuation = nil
    }

    func snapshot() -> [ClipboardGroupEventDescriptor] {
        descriptors
    }
}

private actor ClipboardGroupSinkDetachCompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func read() -> Bool {
        isComplete
    }
}

final class ClipboardGroupEventSchedulerTests: XCTestCase {
    func testLoopPreventionPersistsOneContentFreeReceiptBeforeFixedDiagnostic() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let diagnostics = DiagnosticsRecorder()
        let workflowID = UUID()
        let scheduler = makeScheduler(
            repository: repository,
            diagnostics: diagnostics,
            registrations: [
                makeRegistration(
                    workflowID: workflowID,
                    conditions: [.excludingTag(.polishGenerated)]
                )
            ]
        )
        let descriptor = makeDescriptor(captureTags: [.polishGenerated])

        let submission = await scheduler.submit(descriptor)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(submission, .accepted)
        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].workflowID, workflowID)
        XCTAssertEqual(receipts[0].trigger, .clipboardGroupEvent)
        XCTAssertEqual(receipts[0].termination, .skipped(reason: .loopPrevented))
        XCTAssertTrue(receipts[0].actionDetails.isEmpty)

        let events = await diagnostics.snapshot()
        XCTAssertEqual(events.map(\.event), ["clipboard.trigger.loop-prevented"])
        XCTAssertEqual(
            events[0].metadata,
            [
                "eventKind": ClipboardGroupEventKind.itemCreated.rawValue,
                "outcome": WorkflowRunOutcome.skipped.rawValue,
                "reason": WorkflowRunSkipCode.loopPrevented.rawValue,
            ]
        )
        XCTAssertEqual(events[0].runID, receipts[0].runID)
    }

    func testPolishProvenanceIsHardStopWhenLegacyRuleDisablesExclusion() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let scheduler = makeScheduler(
            repository: repository,
            registrations: [makeRegistration(conditions: [])]
        )

        let submission = await scheduler.submit(
            makeDescriptor(captureTags: [.polishGenerated])
        )
        await scheduler.waitUntilIdle()

        XCTAssertEqual(submission, .accepted)
        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(
            receipts.map(\.termination),
            [.skipped(reason: .loopPrevented)]
        )
    }

    func testLineageReentryAndHopLimitAreHardStopsBeforeExecutionSupport() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let workflowID = UUID()
        let scheduler = makeScheduler(
            repository: repository,
            registrations: [
                makeRegistration(
                    workflowID: workflowID,
                    isEnabled: true,
                    isExecutionSupported: true
                )
            ]
        )
        let rootEventID = UUID()
        let root = ClipboardGroupEventLineage(rootEventID: rootEventID)
        guard case .advanced(let repeated) = root.advancing(through: workflowID) else {
            return XCTFail("A root lineage must permit its first workflow.")
        }
        var saturated = root
        for _ in 0..<ClipboardGroupEventLineage.maximumHopCount {
            guard case .advanced(let next) = saturated.advancing(through: UUID()) else {
                return XCTFail("A unique workflow must advance below the hop cap.")
            }
            saturated = next
        }

        let repeatedSubmission = await scheduler.submit(
            makeDescriptor(lineage: repeated)
        )
        let saturatedSubmission = await scheduler.submit(
            makeDescriptor(lineage: saturated)
        )
        XCTAssertEqual(repeatedSubmission, .accepted)
        XCTAssertEqual(saturatedSubmission, .accepted)
        await scheduler.waitUntilIdle()

        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(
            receipts.map(\.termination),
            [
                .skipped(reason: .loopPrevented),
                .skipped(reason: .loopPrevented),
            ]
        )
    }

    func testMatchedEnabledTriggerIsDurablyClassifiedUnsupportedWithoutExecuting() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let diagnostics = DiagnosticsRecorder()
        let scheduler = makeScheduler(
            repository: repository,
            diagnostics: diagnostics,
            registrations: [
                makeRegistration(
                    isEnabled: true,
                    isExecutionSupported: false
                ),
            ]
        )

        let submission = await scheduler.submit(makeDescriptor())
        XCTAssertEqual(submission, .accepted)
        await scheduler.waitUntilIdle()

        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].termination, .skipped(reason: .unsupported))
        XCTAssertTrue(receipts[0].actionDetails.isEmpty)
        let events = await diagnostics.snapshot()
        XCTAssertEqual(
            events.map(\.event),
            ["clipboard.trigger.matched", "clipboard.trigger.skipped"]
        )
        XCTAssertEqual(events.last?.metadata["reason"], "unsupported")
    }

    func testMatchedDisabledTriggerUsesWorkflowDisabledReason() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let scheduler = makeScheduler(
            repository: repository,
            registrations: [
                makeRegistration(
                    isEnabled: false,
                    isExecutionSupported: true
                ),
            ]
        )

        let submission = await scheduler.submit(makeDescriptor())
        XCTAssertEqual(submission, .accepted)
        await scheduler.waitUntilIdle()

        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(
            receipts.map(\.termination),
            [.skipped(reason: .workflowDisabled)]
        )
    }

    func testRoutingMismatchesDoNotCreateAttemptsOrDiagnostics() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let diagnostics = DiagnosticsRecorder()
        let sourceGroupID = UUID()
        let scheduler = makeScheduler(
            repository: repository,
            diagnostics: diagnostics,
            registrations: [makeRegistration(sourceGroupID: sourceGroupID)]
        )

        let wrongKindSubmission = await scheduler.submit(
            makeDescriptor(kind: .itemEdited, groupID: sourceGroupID)
        )
        let wrongGroupSubmission = await scheduler.submit(
            makeDescriptor(groupID: UUID())
        )
        XCTAssertEqual(wrongKindSubmission, .accepted)
        XCTAssertEqual(wrongGroupSubmission, .accepted)
        await scheduler.waitUntilIdle()

        let receipts = try await repository.receipts(matching: .all)
        let events = await diagnostics.snapshot()
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingItemAndGeneralExclusionUseDistinctFixedReasons() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let scheduler = makeScheduler(
            repository: repository,
            registrations: [
                makeRegistration(
                    conditions: [.excludingTag(.excludeFromWorkflowCapture)]
                )
            ]
        )

        let missingItemSubmission = await scheduler.submit(
            makeDescriptor(captureTags: nil)
        )
        let excludedItemSubmission = await scheduler.submit(
            makeDescriptor(captureTags: [.excludeFromWorkflowCapture])
        )
        XCTAssertEqual(missingItemSubmission, .accepted)
        XCTAssertEqual(excludedItemSubmission, .accepted)
        await scheduler.waitUntilIdle()

        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(
            receipts.contains { $0.termination == .skipped(reason: .itemMissing) }
        )
        XCTAssertTrue(
            receipts.contains {
                $0.termination == .skipped(reason: .excludedByCaptureTag)
            }
        )
    }

    func testDuplicateDeliveryIsIgnoredAndRegistrationsUseStableWorkflowOrder() async throws {
        let repository = SchedulerReceiptOrderRepository()
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let upperID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let registrations = [
            makeRegistration(workflowID: upperID),
            makeRegistration(workflowID: lowerID),
            makeRegistration(workflowID: lowerID),
        ]
        let scheduler = ClipboardGroupEventScheduler(
            receiptRecorder: WorkflowRunReceiptRecorder(repository: repository),
            registrationProvider: { registrations }
        )
        let descriptor = makeDescriptor()

        let firstSubmission = await scheduler.submit(descriptor)
        let duplicateSubmission = await scheduler.submit(descriptor)
        XCTAssertEqual(firstSubmission, .accepted)
        XCTAssertEqual(duplicateSubmission, .duplicate)
        await scheduler.waitUntilIdle()

        let receipts = await repository.insertedReceipts()
        XCTAssertEqual(receipts.compactMap(\.workflowID), [lowerID, upperID])
    }

    func testBackpressureAndShutdownAreDeterministicAndDrainAcceptedWork() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let gate = SchedulerRegistrationGate()
        let registration = makeRegistration()
        let scheduler = ClipboardGroupEventScheduler(
            receiptRecorder: WorkflowRunReceiptRecorder(repository: repository),
            queueCapacity: 1,
            registrationProvider: {
                await gate.waitBeforeReturning([registration])
            }
        )

        let firstSubmission = await scheduler.submit(makeDescriptor())
        XCTAssertEqual(firstSubmission, .accepted)
        await gate.waitUntilEntered()
        let queuedSubmission = await scheduler.submit(makeDescriptor())
        XCTAssertEqual(queuedSubmission, .accepted)
        let waitingDescriptor = makeDescriptor()
        let waitingSubmission = Task {
            await scheduler.submit(waitingDescriptor)
        }
        await scheduler.waitUntilCapacityWaiterForTesting()

        let shutdownTask = Task { await scheduler.shutdown() }
        await scheduler.waitUntilShutdownStartedForTesting()
        let rejectedWaitingSubmission = await waitingSubmission.value
        XCTAssertEqual(rejectedWaitingSubmission, .stopped)
        await gate.release()
        await shutdownTask.value

        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(receipts.count, 2)
        let stoppedSubmission = await scheduler.submit(makeDescriptor())
        XCTAssertEqual(stoppedSubmission, .stopped)
    }

    func testMissingDurableRecorderFailsClosedWithoutMatchedOrSkippedClaim() async {
        let diagnostics = DiagnosticsRecorder()
        let registration = makeRegistration()
        let scheduler = ClipboardGroupEventScheduler(
            receiptRecorder: nil,
            diagnostics: diagnostics,
            registrationProvider: { [registration] }
        )

        let submission = await scheduler.submit(makeDescriptor())
        XCTAssertEqual(submission, .accepted)
        await scheduler.waitUntilIdle()

        let events = await diagnostics.snapshot()
        XCTAssertEqual(events.map(\.event), ["clipboard.trigger.receipt-unavailable"])
        XCTAssertEqual(events[0].metadata["reason"], "storage-unavailable")
    }

    func testDeliveryStackHandsSchedulerOnlyDescriptorAtCommittedRevision() async {
        let privateBody = "private-clipboard-body-canary"
        let sink = ClipboardGroupDescriptorSinkProbe()
        let deliveryStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardGroupEventSink: sink
        )

        await deliveryStack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: privateBody,
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )

        let descriptors = await sink.snapshot()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors[0].kind, .itemCreated)
        XCTAssertEqual(descriptors[0].groupID, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(descriptors[0].itemVersion?.revision, 1)
        XCTAssertEqual(descriptors[0].storeRevision, 1)
        XCTAssertNotEqual(descriptors[0].eventID, descriptors[0].itemID)
        XCTAssertFalse(String(describing: descriptors[0]).contains(privateBody))
        let encoded = try? JSONEncoder().encode(descriptors[0])
        XCTAssertFalse(encoded.map { String(decoding: $0, as: UTF8.self) }?.contains(privateBody) ?? true)
    }

    func testExcludedCaptureProducesSkipReceiptWithoutPublishingContentEvent() async throws {
        let repository = InMemoryWorkflowRunReceiptRepository()
        let scheduler = makeScheduler(
            repository: repository,
            registrations: [
                makeRegistration(
                    sourceGroupID: ClipboardGroup.defaultGroupID
                )
            ]
        )
        let eventBus = EventBus()
        let deliveryStack = DeliveryStack(
            eventBus: eventBus,
            clipboardGroupEventSink: scheduler
        )
        let stream = await eventBus.stream()
        let publishedEvents = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                if case .diagnostic(let diagnostic) = event,
                   diagnostic.event == "diagnostic.boundary" {
                    return events
                }
                events.append(event)
            }
            return events
        }

        await deliveryStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "private-excluded-body-canary",
                changeCount: 1,
                captureTags: [.excludeFromWorkflowCapture]
            ),
            context: ClipboardRouteContext(),
            disposition: .historyAndWorkflows
        )
        await eventBus.publish(
            .diagnostic(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: .debug,
                    event: "diagnostic.boundary",
                    message: "boundary"
                )
            )
        )
        await scheduler.waitUntilIdle()

        let receiptsAfterExcludedCapture = try await repository.receipts(matching: .all)
        XCTAssertEqual(
            receiptsAfterExcludedCapture.map(\.termination),
            [.skipped(reason: .excludedByCaptureTag)]
        )
        let eventsBeforeBoundary = await publishedEvents.value
        XCTAssertFalse(eventsBeforeBoundary.contains { event in
            if case .clipboardGroupEvent = event { return true }
            return false
        })

        await deliveryStack.captureSystemClipboard(
            snapshot: ClipboardSnapshot(
                plainText: "history-only-body-canary",
                changeCount: 2
            ),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
        )
        await scheduler.waitUntilIdle()

        let receiptsAfterHistoryOnlyCapture = try await repository.receipts(matching: .all)
        XCTAssertEqual(receiptsAfterHistoryOnlyCapture.count, 1)
    }

    func testReentrantMutationsKeepSchedulerAndEventBusBatchesInRevisionOrder() async {
        let eventBus = EventBus()
        let sink = BlockingClipboardGroupDescriptorSink()
        let deliveryStack = DeliveryStack(
            eventBus: eventBus,
            clipboardGroupEventSink: sink
        )
        let firstItemID = UUID()
        let secondItemID = UUID()
        let stream = await eventBus.stream()
        let publishedGroupEvents = Task { () -> [ClipboardGroupEventDescriptor] in
            var events: [ClipboardGroupEventDescriptor] = []
            for await event in stream {
                if case .diagnostic(let diagnostic) = event,
                   diagnostic.event == "diagnostic.boundary" {
                    return events
                }
                if case .clipboardGroupEvent(let descriptor) = event {
                    events.append(descriptor)
                }
            }
            return events
        }

        let firstPush = Task {
            await deliveryStack.push(
                DeliveryItem(
                    id: firstItemID,
                    workflowID: UUID(),
                    text: "first"
                )
            )
        }
        await sink.waitUntilFirstSubmission()
        let secondPush = Task {
            await deliveryStack.push(
                DeliveryItem(
                    id: secondItemID,
                    workflowID: UUID(),
                    text: "second"
                )
            )
        }
        await deliveryStack.waitUntilPublicationRevisionForTesting(2)

        await sink.releaseFirstSubmission()
        _ = await firstPush.value
        _ = await secondPush.value
        await eventBus.publish(
            .diagnostic(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: .debug,
                    event: "diagnostic.boundary",
                    message: "boundary"
                )
            )
        )

        let scheduled = await sink.snapshot()
        let published = await publishedGroupEvents.value
        XCTAssertEqual(scheduled.map(\.eventID), published.map(\.eventID))
        XCTAssertEqual(scheduled.map(\.itemID), [firstItemID, secondItemID])
        XCTAssertEqual(published.map(\.itemID), [firstItemID, secondItemID])
        XCTAssertEqual(scheduled.map(\.storeRevision), [1, 2])
        XCTAssertEqual(published.map(\.storeRevision), [1, 2])
    }

    func testRemovingSinkWaitsForCapturedPublicationAndDetachesLaterMutations() async {
        let sink = BlockingClipboardGroupDescriptorSink()
        let deliveryStack = DeliveryStack(
            eventBus: EventBus(),
            clipboardGroupEventSink: sink
        )
        let firstItemID = UUID()
        let secondItemID = UUID()

        let firstPush = Task {
            await deliveryStack.push(
                DeliveryItem(
                    id: firstItemID,
                    workflowID: UUID(),
                    text: "first"
                )
            )
        }
        await sink.waitUntilFirstSubmission()

        let completion = ClipboardGroupSinkDetachCompletionProbe()
        let removal = Task {
            await deliveryStack.removeClipboardGroupEventSink()
            await completion.markComplete()
        }
        await deliveryStack.waitUntilClipboardGroupEventSinkDetachedForTesting()

        let didCompleteWhileCapturedPublicationWasBlocked = await completion.read()
        XCTAssertFalse(didCompleteWhileCapturedPublicationWasBlocked)

        let secondPush = Task {
            await deliveryStack.push(
                DeliveryItem(
                    id: secondItemID,
                    workflowID: UUID(),
                    text: "second"
                )
            )
        }

        await sink.releaseFirstSubmission()
        _ = await firstPush.value
        await removal.value
        _ = await secondPush.value

        let didCompleteAfterCapturedPublicationFinished = await completion.read()
        let scheduled = await sink.snapshot()
        XCTAssertTrue(didCompleteAfterCapturedPublicationFinished)
        XCTAssertEqual(scheduled.map(\.itemID), [firstItemID])
        XCTAssertFalse(scheduled.contains { $0.itemID == secondItemID })
    }

    private func makeScheduler(
        repository: any WorkflowRunReceiptRepository,
        diagnostics: DiagnosticsRecorder? = nil,
        registrations: [ClipboardGroupWorkflowRegistration]
    ) -> ClipboardGroupEventScheduler {
        ClipboardGroupEventScheduler(
            receiptRecorder: WorkflowRunReceiptRecorder(repository: repository),
            diagnostics: diagnostics,
            registrationProvider: { registrations }
        )
    }

    private func makeRegistration(
        workflowID: UUID = UUID(),
        eventKind: ClipboardGroupEventKind = .itemCreated,
        sourceGroupID: UUID = ClipboardGroup.voiceGroupID,
        conditions: [ClipboardGroupTriggerCondition] = [],
        isEnabled: Bool = true,
        isExecutionSupported: Bool = false
    ) -> ClipboardGroupWorkflowRegistration {
        ClipboardGroupWorkflowRegistration(
            workflowID: workflowID,
            triggerRule: ClipboardGroupTriggerRule(
                eventKind: eventKind,
                sourceGroupID: sourceGroupID,
                conditions: conditions
            ),
            isEnabled: isEnabled,
            isExecutionSupported: isExecutionSupported
        )
    }

    private func makeDescriptor(
        kind: ClipboardGroupEventKind = .itemCreated,
        groupID: UUID = ClipboardGroup.voiceGroupID,
        captureTags: [ClipboardCaptureTag]? = [],
        lineage: ClipboardGroupEventLineage? = nil
    ) -> ClipboardGroupEventDescriptor {
        ClipboardGroupEventDescriptor(
            kind: kind,
            groupID: groupID,
            itemID: UUID(),
            storeRevision: 1,
            captureTags: captureTags,
            lineage: lineage,
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }
}
