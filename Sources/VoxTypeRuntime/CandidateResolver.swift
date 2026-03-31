import Foundation
import VoxTypeCore

public actor CandidateResolver {
    public struct ResolutionOutcome: Sendable, Equatable {
        public var result: RecognitionResult
        public var selections: [UUID: UUID]
        public var resolvedByUser: Bool

        public init(result: RecognitionResult, selections: [UUID: UUID], resolvedByUser: Bool) {
            self.result = result
            self.selections = selections
            self.resolvedByUser = resolvedByUser
        }
    }

    private enum BufferedDecision {
        case accept([UUID: UUID])
        case dismiss
    }

    private struct PendingResolution {
        var continuation: CheckedContinuation<[UUID: UUID]?, Never>?
        var bufferedDecision: BufferedDecision?
    }

    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private var pending: [UUID: PendingResolution] = [:]

    public init(eventBus: EventBus, diagnostics: DiagnosticsRecorder? = nil) {
        self.eventBus = eventBus
        self.diagnostics = diagnostics
    }

    public func resolve(_ candidateCase: CandidateResolutionCase) async -> ResolutionOutcome {
        guard candidateCase.recognitionResult.requiresResolution else {
            return ResolutionOutcome(result: candidateCase.recognitionResult, selections: [:], resolvedByUser: false)
        }

        if pending[candidateCase.id] == nil {
            pending[candidateCase.id] = PendingResolution()
        }
        await eventBus.publish(.candidateResolutionRequested(candidateCase))

        let timeoutTask = Task.detached { [weak resolver = self, caseID = candidateCase.id, timeout = candidateCase.policy.timeoutSeconds] in
            try? await Task.sleep(for: .seconds(timeout))
            _ = await resolver?.dismiss(caseID: caseID)
        }

        let selections = await withCheckedContinuation { (continuation: CheckedContinuation<[UUID: UUID]?, Never>) in
            guard var pendingResolution = pending[candidateCase.id] else {
                continuation.resume(returning: nil)
                return
            }

            if let bufferedDecision = pendingResolution.bufferedDecision {
                pending.removeValue(forKey: candidateCase.id)
                switch bufferedDecision {
                case .accept(let selections):
                    continuation.resume(returning: selections)
                case .dismiss:
                    continuation.resume(returning: nil)
                }
                return
            }

            pendingResolution.continuation = continuation
            pending[candidateCase.id] = pendingResolution
        }

        timeoutTask.cancel()
        let appliedSelections = selections ?? candidateCase.defaultSelections()
        let resolved = candidateCase.recognitionResult.applyingSelections(appliedSelections)

        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    runID: candidateCase.runID,
                    subsystem: .resolver,
                    level: selections == nil ? .info : .debug,
                    event: selections == nil ? "candidate.timeout" : "candidate.accepted",
                    message: selections == nil ? "Candidate resolver timed out and used defaults" : "Candidate resolver accepted user selections"
                )
            )
        }

        return ResolutionOutcome(
            result: resolved,
            selections: appliedSelections,
            resolvedByUser: selections != nil
        )
    }

    @discardableResult
    public func accept(caseID: UUID, selections: [UUID: UUID]) -> Bool {
        guard var pendingResolution = pending[caseID] else {
            pending[caseID] = PendingResolution(
                continuation: nil,
                bufferedDecision: .accept(selections)
            )
            return true
        }

        guard let continuation = pendingResolution.continuation else {
            pendingResolution.bufferedDecision = .accept(selections)
            pending[caseID] = pendingResolution
            return true
        }

        pending.removeValue(forKey: caseID)
        continuation.resume(returning: selections)
        return true
    }

    @discardableResult
    public func dismiss(caseID: UUID) -> Bool {
        guard var pendingResolution = pending[caseID] else {
            pending[caseID] = PendingResolution(
                continuation: nil,
                bufferedDecision: .dismiss
            )
            return true
        }

        guard let continuation = pendingResolution.continuation else {
            pendingResolution.bufferedDecision = .dismiss
            pending[caseID] = pendingResolution
            return true
        }

        pending.removeValue(forKey: caseID)
        continuation.resume(returning: nil)
        return true
    }
}
