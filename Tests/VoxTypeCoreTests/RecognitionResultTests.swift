import XCTest
@testable import VoxTypeCore

final class RecognitionResultTests: XCTestCase {
    func testApplyingSelectionsReplacesTheTargetRange() {
        let text = "Send it to Jon tomorrow"
        let range = TextRange(lowerBound: 11, upperBound: 14)
        let primary = Candidate(text: "Jon", confidence: 0.45, source: .asr)
        let replacement = Candidate(text: "John", confidence: 0.43, source: .asr)
        let result = RecognitionResult(
            rawText: text,
            bestText: text,
            candidateSets: [
                CandidateSet(surfaceText: "Jon", range: range, candidates: [primary, replacement])
            ]
        )

        let resolved = result.applyingSelections([result.candidateSets[0].id: replacement.id])

        XCTAssertEqual(resolved.bestText, "Send it to John tomorrow")
        XCTAssertFalse(resolved.requiresResolution)
    }
}
