import Foundation
import RillCore

public enum ClipboardGroupEventSubmissionResult: Sendable, Equatable {
    case accepted
    case duplicate
    case stopped
}

/// A narrow hand-off boundary for clipboard mutations that may match a group
/// trigger. Implementations receive only the content-free descriptor; the
/// clipboard item payload remains owned by `DeliveryStack`.
public protocol ClipboardGroupEventSink: Sendable {
    @discardableResult
    func submit(
        _ descriptor: ClipboardGroupEventDescriptor
    ) async -> ClipboardGroupEventSubmissionResult
}

/// The scheduler-facing portion of a workflow definition.
///
/// Action configuration, prompts, workflow names, and clipboard content are
/// deliberately absent. Group action execution remains disabled; this value
/// is only sufficient to classify and durably record a trigger decision.
public struct ClipboardGroupWorkflowRegistration: Sendable, Equatable {
    public let workflowID: UUID
    public let triggerRule: ClipboardGroupTriggerRule
    public let isEnabled: Bool
    /// Whether this runtime can execute the workflow for a clipboard group
    /// event. This is independent from the user's enabled state so an
    /// unavailable execution surface is never reported as a user choice.
    public let isExecutionSupported: Bool

    public init(
        workflowID: UUID,
        triggerRule: ClipboardGroupTriggerRule,
        isEnabled: Bool,
        isExecutionSupported: Bool
    ) {
        self.workflowID = workflowID
        self.triggerRule = triggerRule
        self.isEnabled = isEnabled
        self.isExecutionSupported = isExecutionSupported
    }
}

/// Serializes content-free group trigger decisions and records their terminal
/// receipts before emitting diagnostics.
///
/// This first product slice intentionally has no action executor. A routed and
/// otherwise matching trigger ends as `.unsupported`; disabled and condition
/// failures retain their more specific closed reasons. Routing mismatches are
/// not attempts and therefore do not create high-volume run receipts.
public actor ClipboardGroupEventScheduler: ClipboardGroupEventSink {
    public typealias RegistrationProvider = @Sendable () async -> [
        ClipboardGroupWorkflowRegistration
    ]
    public typealias RunIDProvider = @Sendable () -> UUID

    private enum Lifecycle: Sendable, Equatable {
        case accepting
        case shuttingDown
        case terminated
    }

    private struct Decision: Sendable, Equatable {
        let ruleMatched: Bool
        let skipCode: WorkflowRunSkipCode
    }

    private let receiptRecorder: WorkflowRunReceiptRecorder?
    private let diagnostics: DiagnosticsRecorder?
    private let registrationProvider: RegistrationProvider
    private let runIDProvider: RunIDProvider
    private let queueCapacity: Int
    private let rememberedEventCapacity: Int

    private var pendingDescriptors: [ClipboardGroupEventDescriptor] = []
    private var drainTask: Task<Void, Never>?
    private var drainGeneration: UInt64 = 0
    private var activeDescriptorID: UUID?
    private var rememberedEventIDs: Set<UUID> = []
    private var rememberedEventIDOrder: [UUID] = []
    private var lifecycle: Lifecycle = .accepting
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    private var capacityWaiterObservationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        receiptRecorder: WorkflowRunReceiptRecorder?,
        diagnostics: DiagnosticsRecorder? = nil,
        queueCapacity: Int = 64,
        rememberedEventCapacity: Int = 1_024,
        registrationProvider: @escaping RegistrationProvider,
        runIDProvider: @escaping RunIDProvider = { UUID() }
    ) {
        precondition(queueCapacity > 0)
        precondition(rememberedEventCapacity > 0)
        precondition(rememberedEventCapacity > queueCapacity)
        self.receiptRecorder = receiptRecorder
        self.diagnostics = diagnostics
        self.queueCapacity = queueCapacity
        self.rememberedEventCapacity = rememberedEventCapacity
        self.registrationProvider = registrationProvider
        self.runIDProvider = runIDProvider
    }

    @discardableResult
    public func submit(
        _ descriptor: ClipboardGroupEventDescriptor
    ) async -> ClipboardGroupEventSubmissionResult {
        guard lifecycle == .accepting else {
            return .stopped
        }
        guard !rememberedEventIDs.contains(descriptor.eventID) else {
            return .duplicate
        }
        while pendingDescriptors.count >= queueCapacity {
            await withCheckedContinuation { continuation in
                capacityWaiters.append(continuation)
                let observers = capacityWaiterObservationWaiters
                capacityWaiterObservationWaiters.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
            guard lifecycle == .accepting else {
                return .stopped
            }
            guard !rememberedEventIDs.contains(descriptor.eventID) else {
                return .duplicate
            }
        }

        rememberEventID(descriptor.eventID)
        pendingDescriptors.append(descriptor)
        ensureDrainTask()
        return .accepted
    }

    /// Waits until all currently queued work has reached a terminal decision.
    /// This is also the deterministic synchronization boundary used by tests.
    public func waitUntilIdle() async {
        guard pendingDescriptors.isEmpty,
              activeDescriptorID == nil,
              drainTask == nil,
              capacityWaiters.isEmpty else {
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
            return
        }
    }

    /// Stops accepting work and drains every accepted descriptor before
    /// returning. It never cancels a receipt write midway through its
    /// persistence boundary.
    public func shutdown() async {
        switch lifecycle {
        case .terminated:
            return
        case .shuttingDown:
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        case .accepting:
            lifecycle = .shuttingDown
        }
        let startedWaiters = shutdownStartedWaiters
        shutdownStartedWaiters.removeAll()
        for waiter in startedWaiters {
            waiter.resume()
        }
        let waitingForCapacity = capacityWaiters
        capacityWaiters.removeAll()
        for waiter in waitingForCapacity {
            waiter.resume()
        }

        let activeDrainTask = drainTask
        if let activeDrainTask {
            await activeDrainTask.value
        }
        lifecycle = .terminated
        resumeIdleWaitersIfNeeded()
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    var pendingCountForTesting: Int {
        pendingDescriptors.count + (activeDescriptorID == nil ? 0 : 1)
    }

    var isShuttingDownForTesting: Bool {
        lifecycle == .shuttingDown
    }

    func waitUntilShutdownStartedForTesting() async {
        guard lifecycle == .accepting else { return }
        await withCheckedContinuation { continuation in
            shutdownStartedWaiters.append(continuation)
        }
    }

    func waitUntilCapacityWaiterForTesting() async {
        guard capacityWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            capacityWaiterObservationWaiters.append(continuation)
        }
    }

    private func ensureDrainTask() {
        guard lifecycle == .accepting,
              drainTask == nil,
              !pendingDescriptors.isEmpty else {
            return
        }
        drainGeneration &+= 1
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drainQueue()
            await self?.drainDidFinish(generation: generation)
        }
    }

    private func drainQueue() async {
        while lifecycle != .terminated, !pendingDescriptors.isEmpty {
            let descriptor = pendingDescriptors.removeFirst()
            resumeOneCapacityWaiter()
            activeDescriptorID = descriptor.eventID
            await process(descriptor)
            activeDescriptorID = nil
        }
    }

    private func drainDidFinish(generation: UInt64) {
        guard generation == drainGeneration else { return }
        drainTask = nil
        activeDescriptorID = nil
        resumeIdleWaitersIfNeeded()
        ensureDrainTask()
    }

    private func process(_ descriptor: ClipboardGroupEventDescriptor) async {
        let registrations = await registrationProvider()
            .sorted { lhs, rhs in
                lhs.workflowID.uuidString < rhs.workflowID.uuidString
            }
        var visitedWorkflowIDs: Set<UUID> = []

        for registration in registrations {
            guard visitedWorkflowIDs.insert(registration.workflowID).inserted else {
                continue
            }
            let matchResult = registration.triggerRule.matchResult(for: descriptor)
            if matchResult.skipReason == .eventKindMismatch ||
                matchResult.skipReason == .sourceGroupMismatch {
                continue
            }

            let decision: Decision
            if descriptor.captureTags == nil {
                decision = Decision(ruleMatched: false, skipCode: .itemMissing)
            } else if descriptor.captureTags?.contains(.polishGenerated) == true {
                // Provenance is a scheduler hard stop, not a user-disableable
                // condition. The lineage check below supplies the independent
                // cross-workflow re-entry and hop-limit layer.
                decision = Decision(ruleMatched: false, skipCode: .loopPrevented)
            } else if descriptor.captureTags?.contains(.excludeFromWorkflowCapture) == true {
                decision = Decision(
                    ruleMatched: false,
                    skipCode: .excludedByCaptureTag
                )
            } else if let skipReason = matchResult.skipReason {
                decision = Decision(
                    ruleMatched: false,
                    skipCode: skipReason.workflowRunSkipCode
                )
            } else if !descriptor.lineage.isValid(for: descriptor.eventID) ||
                !descriptor.lineage
                    .advancing(through: registration.workflowID)
                    .permitsExecution {
                decision = Decision(ruleMatched: false, skipCode: .loopPrevented)
            } else if !registration.isExecutionSupported {
                decision = Decision(ruleMatched: true, skipCode: .unsupported)
            } else if !registration.isEnabled {
                decision = Decision(ruleMatched: true, skipCode: .workflowDisabled)
            } else {
                // Group action execution remains intentionally closed until
                // a revision-bound grant, one-shot group action lease, and
                // effect-adjacent revalidation are available.
                decision = Decision(ruleMatched: true, skipCode: .unsupported)
            }

            await record(
                decision,
                for: descriptor,
                workflowID: registration.workflowID
            )
        }
    }

    private func record(
        _ decision: Decision,
        for descriptor: ClipboardGroupEventDescriptor,
        workflowID: UUID
    ) async {
        let runID = runIDProvider()
        guard let receiptRecorder else {
            await recordReceiptUnavailable(
                runID: runID,
                eventKind: descriptor.kind
            )
            return
        }

        do {
            try await receiptRecorder.begin(
                runID: runID,
                workflowID: workflowID,
                trigger: .clipboardGroupEvent
            )
            _ = try await receiptRecorder.finish(
                runID: runID,
                termination: .skipped(reason: decision.skipCode)
            )
        } catch {
            await recordReceiptUnavailable(
                runID: runID,
                eventKind: descriptor.kind
            )
            return
        }

        if decision.ruleMatched {
            await diagnostics?.record(
                DiagnosticEvent(
                    runID: runID,
                    subsystem: .clipboard,
                    level: .info,
                    event: "clipboard.trigger.matched",
                    message: "A clipboard group trigger matched.",
                    metadata: [
                        "eventKind": descriptor.kind.rawValue,
                        "outcome": WorkflowRunOutcome.skipped.rawValue,
                    ]
                )
            )
        }

        let eventCode = decision.skipCode == .loopPrevented
            ? "clipboard.trigger.loop-prevented"
            : "clipboard.trigger.skipped"
        await diagnostics?.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .clipboard,
                level: .info,
                event: eventCode,
                message: "A clipboard group trigger was skipped.",
                metadata: [
                    "eventKind": descriptor.kind.rawValue,
                    "outcome": WorkflowRunOutcome.skipped.rawValue,
                    "reason": decision.skipCode.rawValue,
                ]
            )
        )
    }

    private func recordReceiptUnavailable(
        runID: UUID,
        eventKind: ClipboardGroupEventKind
    ) async {
        await diagnostics?.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .clipboard,
                level: .error,
                event: "clipboard.trigger.receipt-unavailable",
                message: "A clipboard group trigger decision could not be durably recorded.",
                metadata: [
                    "eventKind": eventKind.rawValue,
                    "outcome": WorkflowRunOutcome.failed.rawValue,
                    "reason": "storage-unavailable",
                ]
            )
        )
    }

    private func rememberEventID(_ eventID: UUID) {
        rememberedEventIDs.insert(eventID)
        rememberedEventIDOrder.append(eventID)
        if rememberedEventIDOrder.count > rememberedEventCapacity {
            let evicted = rememberedEventIDOrder.removeFirst()
            rememberedEventIDs.remove(evicted)
        }
    }

    private func resumeOneCapacityWaiter() {
        guard !capacityWaiters.isEmpty else { return }
        capacityWaiters.removeFirst().resume()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard pendingDescriptors.isEmpty,
              activeDescriptorID == nil,
              drainTask == nil,
              capacityWaiters.isEmpty else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
