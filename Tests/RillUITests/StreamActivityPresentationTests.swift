import XCTest

@testable import RillUI

final class StreamActivityPresentationTests: XCTestCase {
    func testIdleStatesHideTheCard() {
        XCTAssertNil(
            StreamActivityPresentation.make(
                isRunning: false,
                workflowAudioRunState: .idle,
                isAudioProcessingQueueVisible: false,
                language: .english
            )
        )
        XCTAssertNil(
            StreamActivityPresentation.make(
                isRunning: false,
                workflowAudioRunState: .idle,
                isAudioProcessingQueueVisible: false,
                language: .simplifiedChinese
            )
        )
    }

    func testGenericRunningReusesMenuBarStatusCopy() {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let presentation = StreamActivityPresentation.make(
                isRunning: true,
                workflowAudioRunState: .idle,
                isAudioProcessingQueueVisible: false,
                language: language
            )
            XCTAssertEqual(presentation?.phase, .running)
            XCTAssertEqual(
                presentation?.title,
                L10n.string(.menuStatusRunning, language: language)
            )
            XCTAssertEqual(
                presentation?.detail,
                L10n.string(.menuStatusRunningDetail, language: language)
            )
            XCTAssertEqual(presentation?.symbol, .waveformCircleFill)
        }
    }

    func testInteractiveRunPhasesTakePrecedenceOverGenericRunning() {
        let workflowID = UUID()

        let preparing = StreamActivityPresentation.make(
            isRunning: true,
            workflowAudioRunState: .preparing(workflowID: workflowID),
            isAudioProcessingQueueVisible: false,
            language: .english
        )
        XCTAssertEqual(preparing?.phase, .preparing)
        XCTAssertEqual(
            preparing?.title,
            UIStrings.text(.workflowPreparingAudio, language: .english)
        )
        XCTAssertEqual(preparing?.symbol, .hourglass)

        let recording = StreamActivityPresentation.make(
            isRunning: true,
            workflowAudioRunState: .recording(workflowID: workflowID),
            isAudioProcessingQueueVisible: false,
            language: .english
        )
        XCTAssertEqual(recording?.phase, .recording)
        XCTAssertEqual(
            recording?.title,
            UIStrings.text(.streamActivityRecording, language: .english)
        )
        XCTAssertEqual(recording?.symbol, .micFill)

        let transcribing = StreamActivityPresentation.make(
            isRunning: true,
            workflowAudioRunState: .transcribing(workflowID: workflowID),
            isAudioProcessingQueueVisible: false,
            language: .english
        )
        XCTAssertEqual(transcribing?.phase, .transcribing)
        XCTAssertEqual(
            transcribing?.title,
            UIStrings.text(.workflowTranscribing, language: .english)
        )
        XCTAssertEqual(transcribing?.symbol, .waveform)
    }

    func testQueuedAudioWithoutTrackedRunPresentsTranscribing() {
        let presentation = StreamActivityPresentation.make(
            isRunning: false,
            workflowAudioRunState: .idle,
            isAudioProcessingQueueVisible: true,
            language: .english
        )
        XCTAssertEqual(presentation?.phase, .transcribing)
        XCTAssertEqual(
            presentation?.title,
            UIStrings.text(.workflowTranscribing, language: .english)
        )
    }

    func testPhaseCopyIsBilingualAndDistinct() {
        let workflowID = UUID()
        let inputs: [WorkflowAudioRunState] = [
            .preparing(workflowID: workflowID),
            .recording(workflowID: workflowID),
            .transcribing(workflowID: workflowID),
        ]
        for state in inputs {
            let english = StreamActivityPresentation.make(
                isRunning: true,
                workflowAudioRunState: state,
                isAudioProcessingQueueVisible: false,
                language: .english
            )
            let simplifiedChinese = StreamActivityPresentation.make(
                isRunning: true,
                workflowAudioRunState: state,
                isAudioProcessingQueueVisible: false,
                language: .simplifiedChinese
            )
            XCTAssertNotNil(english)
            XCTAssertNotNil(simplifiedChinese)
            XCTAssertFalse(english?.title.isEmpty ?? true)
            XCTAssertFalse(simplifiedChinese?.title.isEmpty ?? true)
            XCTAssertNotEqual(english?.title, simplifiedChinese?.title)
        }
    }
}
