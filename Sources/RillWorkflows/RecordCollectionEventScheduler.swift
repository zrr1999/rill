import Foundation
import RillCore

/// The content-free scheduler projection of one workflow. Action prompts,
/// Record payloads, and source application identities never cross this boundary.
public struct RecordCollectionWorkflowRegistration: Sendable, Equatable {
    public let workflowID: UUID
    public let triggerRule: RecordCollectionTriggerRule
    public let isEnabled: Bool
    public let isExecutionSupported: Bool

    public init(
        workflowID: UUID,
        triggerRule: RecordCollectionTriggerRule,
        isEnabled: Bool,
        isExecutionSupported: Bool
    ) {
        self.workflowID = workflowID
        self.triggerRule = triggerRule
        self.isEnabled = isEnabled
        self.isExecutionSupported = isExecutionSupported
    }
}

/// Serializes exact, content-free collection event decisions. The previous
/// product contract did not execute collection automation actions; unsupported
/// matches continue to fail closed while retaining durable run receipts.
public actor RecordCollectionEventScheduler: RecordCollectionEventSink {
    public typealias RegistrationProvider =
        @Sendable () async -> [RecordCollectionWorkflowRegistration]

    private enum Lifecycle {
        case accepting
        case shuttingDown
        case terminated
    }

    private let receiptRecorder: WorkflowRunReceiptRecorder?
    private let diagnostics: DiagnosticsRecorder?
    private let registrationProvider: RegistrationProvider
    private let queueCapacity: Int
    private let rememberedEventCapacity: Int

    private var lifecycle: Lifecycle = .accepting
    private var pending: [RecordCollectionEventDescriptor] = []
    private var drainTask: Task<Void, Never>?
    private var rememberedEventIDs: Set<UUID> = []
    private var rememberedEventOrder: [UUID] = []
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        receiptRecorder: WorkflowRunReceiptRecorder?,
        diagnostics: DiagnosticsRecorder? = nil,
        queueCapacity: Int = 64,
        rememberedEventCapacity: Int = 1_024,
        registrationProvider: @escaping RegistrationProvider
    ) {
        precondition(queueCapacity > 0)
        precondition(rememberedEventCapacity > queueCapacity)
        self.receiptRecorder = receiptRecorder
        self.diagnostics = diagnostics
        self.queueCapacity = queueCapacity
        self.rememberedEventCapacity = rememberedEventCapacity
        self.registrationProvider = registrationProvider
    }

    @discardableResult
    public func submit(
        _ descriptor: RecordCollectionEventDescriptor
    ) async -> RecordCollectionEventSubmissionResult {
        guard lifecycle == .accepting else { return .stopped }
        guard !rememberedEventIDs.contains(descriptor.eventID) else { return .duplicate }
        while pending.count >= queueCapacity {
            await withCheckedContinuation { capacityWaiters.append($0) }
            guard lifecycle == .accepting else { return .stopped }
            guard !rememberedEventIDs.contains(descriptor.eventID) else { return .duplicate }
        }
        remember(descriptor.eventID)
        pending.append(descriptor)
        startDrainIfNeeded()
        return .accepted
    }

    public func shutdown() async {
        switch lifecycle {
        case .terminated:
            return
        case .shuttingDown:
            await withCheckedContinuation { shutdownWaiters.append($0) }
            return
        case .accepting:
            lifecycle = .shuttingDown
        }
        let blockedSubmitters = capacityWaiters
        capacityWaiters.removeAll()
        blockedSubmitters.forEach { $0.resume() }
        if let drainTask { await drainTask.value }
        lifecycle = .terminated
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilIdleForTesting() async {
        while drainTask != nil || !pending.isEmpty {
            await Task.yield()
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let descriptor = pending.removeFirst()
            if !capacityWaiters.isEmpty { capacityWaiters.removeFirst().resume() }
            await process(descriptor)
        }
        drainTask = nil
        if !pending.isEmpty { startDrainIfNeeded() }
    }

    private func process(_ descriptor: RecordCollectionEventDescriptor) async {
        let registrations = await registrationProvider().sorted {
            $0.workflowID.uuidString < $1.workflowID.uuidString
        }
        var visited: Set<UUID> = []
        for registration in registrations where visited.insert(registration.workflowID).inserted {
            let match = registration.triggerRule.matchResult(for: descriptor)
            if match.skipReason == .eventKindMismatch
                || match.skipReason == .sourceCollectionMismatch
            {
                continue
            }
            let reason: WorkflowRunSkipCode
            if descriptor.captureTags == nil {
                reason = .recordMissing
            } else if descriptor.captureTags?.contains(.polishGenerated) == true {
                reason = .loopPrevented
            } else if descriptor.captureTags?.contains(.excludeFromWorkflowCapture) == true {
                reason = .excludedByCaptureTag
            } else if let skipReason = match.skipReason {
                reason = skipReason.workflowRunSkipCode
            } else if !descriptor.lineage.isValid(for: descriptor.eventID)
                || !descriptor.lineage.advancing(through: registration.workflowID).permitsExecution
            {
                reason = .loopPrevented
            } else if !registration.isExecutionSupported {
                reason = .unsupported
            } else if !registration.isEnabled {
                reason = .workflowDisabled
            } else {
                reason = .unsupported
            }
            await recordDecision(
                workflowID: registration.workflowID,
                descriptor: descriptor,
                reason: reason,
                matched: match.matched
            )
        }
    }

    private func recordDecision(
        workflowID: UUID,
        descriptor: RecordCollectionEventDescriptor,
        reason: WorkflowRunSkipCode,
        matched: Bool
    ) async {
        let runID = UUID()
        do {
            guard let receiptRecorder else { throw RecordCollectionEventSchedulerError.noRecorder }
            try await receiptRecorder.begin(
                runID: runID,
                workflowID: workflowID,
                trigger: .recordCollectionEvent
            )
            _ = try await receiptRecorder.finish(
                runID: runID,
                termination: .skipped(reason: reason)
            )
        } catch {
            await diagnostics?.record(
                DiagnosticEvent(
                    runID: runID,
                    subsystem: .records,
                    level: .error,
                    event: .recordTriggerReceiptUnavailable,
                    message: "A Record collection trigger decision could not be stored.",
                    metadata: ["eventKind": descriptor.kind.rawValue]
                )
            )
            return
        }
        await diagnostics?.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .records,
                level: .info,
                event: reason == .loopPrevented
                    ? .recordTriggerLoopPrevented
                    : .recordTriggerSkipped,
                message: matched
                    ? "A Record collection trigger matched and was skipped."
                    : "A Record collection trigger was skipped.",
                metadata: [
                    "eventKind": descriptor.kind.rawValue,
                    "outcome": WorkflowRunOutcome.skipped.rawValue,
                    "reason": reason.rawValue,
                ]
            )
        )
    }

    private func remember(_ eventID: UUID) {
        rememberedEventIDs.insert(eventID)
        rememberedEventOrder.append(eventID)
        if rememberedEventOrder.count > rememberedEventCapacity {
            rememberedEventIDs.remove(rememberedEventOrder.removeFirst())
        }
    }
}

private enum RecordCollectionEventSchedulerError: Error {
    case noRecorder
}
