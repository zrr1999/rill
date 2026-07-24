import XCTest
@testable import RillCore

final class WorkflowRunFailureSummaryTests: XCTestCase {
    func testNoSpeechIsNeverEligibleForCapturedAudioRecovery() {
        for stage in [
            WorkflowRunStage.preparing,
            .capturingInput,
            .recognizing,
            .resolving,
            .transforming,
        ] {
            let failure = WorkflowRunFailureSummary(
                runID: UUID(),
                stage: stage,
                code: .noSpeech
            )

            XCTAssertFalse(
                failure.isCapturedAudioRecoveryEligible,
                "No-speech audio must not be retained at the \(stage.rawValue) stage."
            )
        }
    }

    func testOrdinaryRecognitionFailureRemainsEligibleForCapturedAudioRecovery() {
        let failure = WorkflowRunFailureSummary(
            runID: UUID(),
            stage: .recognizing,
            code: .processing
        )

        XCTAssertTrue(failure.isCapturedAudioRecoveryEligible)
    }
}
