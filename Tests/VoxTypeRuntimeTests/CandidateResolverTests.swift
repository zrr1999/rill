import XCTest
@testable import VoxTypeCore
@testable import VoxTypeRuntime

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
        await Task.yield()
        _ = await resolver.accept(caseID: caseData.id, selections: [candidateSet.id: candidateSet.candidates[1].id])

        let outcome = await task.value
        XCTAssertTrue(outcome.resolvedByUser)
        XCTAssertEqual(outcome.result.bestText, "John")
    }

    func testAcceptingBeforeContinuationRegistrationIsBuffered() async {
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

        _ = await resolver.accept(caseID: caseData.id, selections: [candidateSet.id: candidateSet.candidates[1].id])

        let outcome = await task.value
        XCTAssertTrue(outcome.resolvedByUser)
        XCTAssertEqual(outcome.result.bestText, "John")
    }
}
