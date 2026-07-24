import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private enum SchedulerPersistenceFailurePoint: CaseIterable {
    case query
    case insert
}

private struct SchedulerPersistenceCanaryError: Error, CustomStringConvertible {
    let description: String
}

private actor SchedulerFailingReceiptRepository: WorkflowRunReceiptRepository {
    private let failurePoint: SchedulerPersistenceFailurePoint
    private let privateErrorCanary: String

    init(
        failurePoint: SchedulerPersistenceFailurePoint,
        privateErrorCanary: String
    ) {
        self.failurePoint = failurePoint
        self.privateErrorCanary = privateErrorCanary
    }

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        if failurePoint == .insert {
            throw SchedulerPersistenceCanaryError(description: privateErrorCanary)
        }
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        if failurePoint == .query {
            throw SchedulerPersistenceCanaryError(description: privateErrorCanary)
        }
        return []
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int { 0 }
    func deleteAllReceipts() async throws -> Int { 0 }
}

private actor SchedulerReceiptSequenceRepository: WorkflowRunReceiptRepository {
    private var receiptsByRunID: [UUID: WorkflowRunReceipt] = [:]
    private var insertionOrder: [UUID] = []

    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws {
        if let existing = receiptsByRunID[receipt.runID] {
            guard existing == receipt else {
                throw WorkflowRunReceiptRepositoryError.conflictingTerminalReceipt(
                    runID: receipt.runID
                )
            }
            return
        }
        receiptsByRunID[receipt.runID] = receipt
        insertionOrder.append(receipt.runID)
    }

    func receipts(
        matching query: WorkflowRunReceiptQuery
    ) async throws -> [WorkflowRunReceipt] {
        var values = insertionOrder.compactMap { receiptsByRunID[$0] }
        if let runID = query.runID {
            values = values.filter { $0.runID == runID }
        }
        return values
    }

    func deleteReceipts(olderThan cutoff: Date) async throws -> Int { 0 }

    func deleteAllReceipts() async throws -> Int {
        let count = receiptsByRunID.count
        receiptsByRunID.removeAll()
        insertionOrder.removeAll()
        return count
    }

    func insertedReceipts() -> [WorkflowRunReceipt] {
        insertionOrder.compactMap { receiptsByRunID[$0] }
    }
}

private actor SchedulerDescriptorProbe: ClipboardGroupEventSink {
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

final class ClipboardGroupEventSchedulerReliabilityTests: XCTestCase {
    func testRepositoryFailuresNeverClaimMatchedOrSkippedAndRedactErrors() async {
        for failurePoint in SchedulerPersistenceFailurePoint.allCases {
            let privateErrorCanary = "private-storage-error-\(failurePoint)"
            let repository = SchedulerFailingReceiptRepository(
                failurePoint: failurePoint,
                privateErrorCanary: privateErrorCanary
            )
            let diagnostics = DiagnosticsRecorder()
            let recorder = WorkflowRunReceiptRecorder(
                repository: repository,
                diagnostics: diagnostics,
                maximumPersistenceAttempts: 1,
                persistenceRetryDelay: { _ in }
            )
            let registration = makeRegistration()
            let scheduler = ClipboardGroupEventScheduler(
                receiptRecorder: recorder,
                diagnostics: diagnostics,
                registrationProvider: { [registration] }
            )

            let submission = await scheduler.submit(makeDescriptor())
            XCTAssertEqual(submission, .accepted)
            await scheduler.waitUntilIdle()

            let events = await diagnostics.snapshot()
            XCTAssertEqual(
                events.filter { $0.event == "clipboard.trigger.receipt-unavailable" }.count,
                1
            )
            XCTAssertFalse(events.contains { event in
                [
                    "clipboard.trigger.matched",
                    "clipboard.trigger.skipped",
                    "clipboard.trigger.loop-prevented",
                ].contains(event.event)
            })
            XCTAssertFalse(String(describing: events).contains(privateErrorCanary))
        }
    }

    func testDescriptorsAndWorkflowCandidatesRemainFIFOAcrossEventKinds() async {
        let repository = SchedulerReceiptSequenceRepository()
        let createdWorkflowID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let editedWorkflowID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let registrations = [
            makeRegistration(
                workflowID: editedWorkflowID,
                eventKind: .itemEdited
            ),
            makeRegistration(
                workflowID: createdWorkflowID,
                eventKind: .itemCreated
            ),
        ]
        let scheduler = ClipboardGroupEventScheduler(
            receiptRecorder: WorkflowRunReceiptRecorder(repository: repository),
            registrationProvider: { registrations }
        )

        let createdSubmission = await scheduler.submit(
            makeDescriptor(eventID: UUID(), kind: .itemCreated)
        )
        let editedSubmission = await scheduler.submit(
            makeDescriptor(eventID: UUID(), kind: .itemEdited)
        )
        XCTAssertEqual(createdSubmission, .accepted)
        XCTAssertEqual(editedSubmission, .accepted)
        await scheduler.waitUntilIdle()

        let receipts = await repository.insertedReceipts()
        XCTAssertEqual(
            receipts.compactMap(\.workflowID),
            [createdWorkflowID, editedWorkflowID]
        )
        XCTAssertEqual(
            receipts.map(\.termination),
            [
                .skipped(reason: .unsupported),
                .skipped(reason: .unsupported),
            ]
        )
    }

    func testDedupeSurvivesIdleAndUsesBoundedOldestFirstEviction() async throws {
        let repository = SchedulerReceiptSequenceRepository()
        let registration = makeRegistration()
        let scheduler = ClipboardGroupEventScheduler(
            receiptRecorder: WorkflowRunReceiptRecorder(repository: repository),
            queueCapacity: 1,
            rememberedEventCapacity: 2,
            registrationProvider: { [registration] }
        )
        let firstEventID = UUID()
        let firstDescriptor = makeDescriptor(eventID: firstEventID)

        let firstSubmission = await scheduler.submit(firstDescriptor)
        XCTAssertEqual(firstSubmission, .accepted)
        await scheduler.waitUntilIdle()
        let duplicateSubmission = await scheduler.submit(firstDescriptor)
        XCTAssertEqual(duplicateSubmission, .duplicate)

        let secondSubmission = await scheduler.submit(
            makeDescriptor(eventID: UUID())
        )
        XCTAssertEqual(secondSubmission, .accepted)
        await scheduler.waitUntilIdle()
        let thirdSubmission = await scheduler.submit(
            makeDescriptor(eventID: UUID())
        )
        XCTAssertEqual(thirdSubmission, .accepted)
        await scheduler.waitUntilIdle()

        let resubmissionAfterEviction = await scheduler.submit(firstDescriptor)
        XCTAssertEqual(resubmissionAfterEviction, .accepted)
        await scheduler.waitUntilIdle()
        let receipts = try await repository.receipts(matching: .all)
        XCTAssertEqual(receipts.count, 4)
    }

    func testHistoryOnlyCaptureStoresItemWithoutSchedulingOrGroupEventFanout() async {
        let privateBodyCanary = "history-only-private-body-canary"
        let eventBus = EventBus()
        let sink = SchedulerDescriptorProbe()
        let deliveryStack = DeliveryStack(
            eventBus: eventBus,
            clipboardGroupEventSink: sink
        )
        let stream = await eventBus.stream()
        let eventsBeforeBoundary = Task { () -> [RillEvent] in
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
                plainText: privateBodyCanary,
                changeCount: 1
            ),
            context: ClipboardRouteContext(),
            disposition: .historyOnly
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

        let clipboardSnapshot = await deliveryStack.clipboardSnapshot()
        let scheduledDescriptors = await sink.snapshot()
        let publishedEvents = await eventsBeforeBoundary.value
        XCTAssertTrue(
            clipboardSnapshot.items.contains { $0.text == privateBodyCanary }
        )
        XCTAssertTrue(scheduledDescriptors.isEmpty)
        XCTAssertFalse(publishedEvents.contains { event in
            if case .clipboardGroupEvent = event { return true }
            return false
        })
    }

    private func makeRegistration(
        workflowID: UUID = UUID(),
        eventKind: ClipboardGroupEventKind = .itemCreated
    ) -> ClipboardGroupWorkflowRegistration {
        ClipboardGroupWorkflowRegistration(
            workflowID: workflowID,
            triggerRule: ClipboardGroupTriggerRule(
                eventKind: eventKind,
                sourceGroupID: ClipboardGroup.voiceGroupID
            ),
            isEnabled: false,
            isExecutionSupported: false
        )
    }

    private func makeDescriptor(
        eventID: UUID,
        kind: ClipboardGroupEventKind = .itemCreated
    ) -> ClipboardGroupEventDescriptor {
        ClipboardGroupEventDescriptor(
            eventID: eventID,
            kind: kind,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: UUID(),
            storeRevision: 1,
            captureTags: [],
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeDescriptor() -> ClipboardGroupEventDescriptor {
        makeDescriptor(eventID: UUID())
    }
}
