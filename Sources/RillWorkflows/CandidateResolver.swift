import Foundation
import RillCore

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

    private enum ResolutionDecision {
        case accept([UUID: UUID])
        case dismissed
        case timedOut
        case cancelled
    }

    private struct PendingResolution {
        var continuation: CheckedContinuation<ResolutionDecision, Never>?
        var bufferedDecision: ResolutionDecision?
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

        let timeout = Self.boundedTimeout(candidateCase.policy.timeoutSeconds)
        let timeoutTask = Task { [weak resolver = self, caseID = candidateCase.id] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            _ = await resolver?.complete(caseID: caseID, decision: .timedOut)
        }

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ResolutionDecision, Never>) in
                guard var pendingResolution = pending[candidateCase.id] else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                if let bufferedDecision = pendingResolution.bufferedDecision {
                    pending.removeValue(forKey: candidateCase.id)
                    continuation.resume(returning: bufferedDecision)
                    return
                }

                pendingResolution.continuation = continuation
                pending[candidateCase.id] = pendingResolution
            }
        } onCancel: {
            Task { [weak resolver = self, caseID = candidateCase.id] in
                _ = await resolver?.complete(caseID: caseID, decision: .cancelled)
            }
        }

        timeoutTask.cancel()
        await timeoutTask.value
        let selections: [UUID: UUID]?
        let diagnosticEvent: DiagnosticEventName
        let diagnosticMessage: String
        switch decision {
        case .accept(let acceptedSelections):
            selections = acceptedSelections
            diagnosticEvent = .candidateAccepted
            diagnosticMessage = "Candidate resolver accepted user selections"
        case .dismissed:
            selections = nil
            diagnosticEvent = .candidateDismissed
            diagnosticMessage = "Candidate resolver was dismissed and used defaults"
        case .timedOut:
            selections = nil
            diagnosticEvent = .candidateTimeout
            diagnosticMessage = "Candidate resolver timed out and used defaults"
        case .cancelled:
            selections = nil
            diagnosticEvent = .candidateCancelled
            diagnosticMessage = "Candidate resolver was cancelled and used defaults"
        }
        let appliedSelections = selections ?? candidateCase.defaultSelections()
        let resolved = candidateCase.recognitionResult.applyingSelections(appliedSelections)

        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    runID: candidateCase.runID,
                    subsystem: .resolver,
                    level: selections == nil ? .info : .debug,
                    event: diagnosticEvent,
                    message: diagnosticMessage
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
        complete(caseID: caseID, decision: .accept(selections))
    }

    @discardableResult
    public func dismiss(caseID: UUID) -> Bool {
        complete(caseID: caseID, decision: .dismissed)
    }

    @discardableResult
    private func complete(caseID: UUID, decision: ResolutionDecision) -> Bool {
        guard var pendingResolution = pending[caseID] else { return false }
        guard let continuation = pendingResolution.continuation else {
            pendingResolution.bufferedDecision = decision
            pending[caseID] = pendingResolution
            return true
        }

        pending.removeValue(forKey: caseID)
        continuation.resume(returning: decision)
        return true
    }

    private static func boundedTimeout(_ seconds: Double) -> Duration {
        guard seconds.isFinite else { return .seconds(5) }
        return .seconds(min(max(seconds, 0), 300))
    }

    var pendingCountForTesting: Int {
        pending.count
    }
}
