
@testable import RillCore
@testable import RillWorkflows
import XCTest

final class CandidateResolverTests: XCTestCase {
    func testAcceptingSelectionsResolvesThePendingCase() async {
        let eventBus = EventBus()
        let resolver = CandidateResolver(eventBus: eventBus)
        let candidateSet = CandidateSet(
            surfaceText: "Jon",
            range: TextRange(lowerBound: 0, upperBound: 3),
            candidates: [
                Candidate(text: "Jon", confidence: 0.45, source: .asr),
                Candidate(text: "John", confidence: 0.43, source: .asr),
            ]
        )
        let caseData = CandidateResolutionCase(
            runID: UUID(),
            recognitionResult: RecognitionResult(
                rawText: "Jon",
                bestText: "Jon",
                candidateSets: [candidateSet]
            ),
            policy: UncertaintyPolicy(mode: .blocking, confidenceThreshold: 0.7, timeoutSeconds: 5)
        )

        let task = Task {
            await resolver.resolve(caseData)
        }
        await waitUntilPending(resolver)
        _ = await resolver.accept(caseID: caseData.id, selections: [candidateSet.id: candidateSet.candidates[1].id])

        let outcome = await task.value
        XCTAssertTrue(outcome.resolvedByUser)
        XCTAssertEqual(outcome.result.bestText, "John")
        let pendingCount = await resolver.pendingCountForTesting
        XCTAssertEqual(pendingCount, 0)
    }

    func testUnknownAndCompletedCasesCannotCreateBufferedDecisions() async {
        let resolver = CandidateResolver(eventBus: EventBus())
        let unknownID = UUID()

        let acceptedUnknown = await resolver.accept(caseID: unknownID, selections: [:])
        let dismissedUnknown = await resolver.dismiss(caseID: unknownID)
        let unknownPendingCount = await resolver.pendingCountForTesting
        XCTAssertFalse(acceptedUnknown)
        XCTAssertFalse(dismissedUnknown)
        XCTAssertEqual(unknownPendingCount, 0)

        let caseData = makeCase(timeoutSeconds: 5)
        let task = Task { await resolver.resolve(caseData) }
        await waitUntilPending(resolver)
        let dismissedPending = await resolver.dismiss(caseID: caseData.id)
        XCTAssertTrue(dismissedPending)
        _ = await task.value

        let dismissedCompleted = await resolver.dismiss(caseID: caseData.id)
        let acceptedCompleted = await resolver.accept(caseID: caseData.id, selections: [:])
        let completedPendingCount = await resolver.pendingCountForTesting
        XCTAssertFalse(dismissedCompleted)
        XCTAssertFalse(acceptedCompleted)
        XCTAssertEqual(completedPendingCount, 0)
    }

    func testTimeoutUsesDefaultsAndRemovesPendingState() async {
        let resolver = CandidateResolver(eventBus: EventBus())
        let caseData = makeCase(timeoutSeconds: 0.01)

        let outcome = await resolver.resolve(caseData)

        XCTAssertFalse(outcome.resolvedByUser)
        XCTAssertEqual(outcome.result.bestText, "Jon")
        let pendingCount = await resolver.pendingCountForTesting
        XCTAssertEqual(pendingCount, 0)
    }

    func testParentCancellationFinishesWithoutWaitingForConfiguredTimeout() async {
        let resolver = CandidateResolver(eventBus: EventBus())
        let caseData = makeCase(timeoutSeconds: 300)
        let clock = ContinuousClock()
        let task = Task { await resolver.resolve(caseData) }
        await waitUntilPending(resolver)

        let startedAt = clock.now
        task.cancel()
        let outcome = await task.value

        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        XCTAssertFalse(outcome.resolvedByUser)
        XCTAssertEqual(outcome.result.bestText, "Jon")
        let pendingCount = await resolver.pendingCountForTesting
        XCTAssertEqual(pendingCount, 0)
    }

    private func waitUntilPending(
        _ resolver: CandidateResolver,
        attempts: Int = 1_000
    ) async {
        for _ in 0..<attempts {
            if await resolver.pendingCountForTesting > 0 { return }
            await Task.yield()
        }
        XCTFail("Candidate resolution did not become pending.")
    }

    private func makeCase(timeoutSeconds: Double) -> CandidateResolutionCase {
        let candidateSet = CandidateSet(
            surfaceText: "Jon",
            range: TextRange(lowerBound: 0, upperBound: 3),
            candidates: [
                Candidate(text: "Jon", confidence: 0.45, source: .asr),
                Candidate(text: "John", confidence: 0.43, source: .asr),
            ]
        )
        return CandidateResolutionCase(
            runID: UUID(),
            recognitionResult: RecognitionResult(
                rawText: "Jon",
                bestText: "Jon",
                candidateSets: [candidateSet]
            ),
            policy: UncertaintyPolicy(
                mode: .blocking,
                confidenceThreshold: 0.7,
                timeoutSeconds: timeoutSeconds
            )
        )
    }
}
