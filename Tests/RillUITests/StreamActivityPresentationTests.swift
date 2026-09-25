import XCTest
import RillCore

@testable import RillUI

final class StreamActivityPresentationTests: XCTestCase {
    func testActualProcessingStageReplacesGenericTranscribing() {
        let presentation = StreamActivityPresentation.make(
            isRunning: true, workflowAudioRunState: .transcribing(workflowID: UUID()),
            isAudioProcessingQueueVisible: true, language: .simplifiedChinese,
            activeStage: .saving)
        XCTAssertEqual(presentation?.phase, .saving)
        XCTAssertEqual(presentation?.title, "保存中")
        let recording = StreamActivityPresentation.make(
            isRunning: true, workflowAudioRunState: .recording(workflowID: UUID()),
            isAudioProcessingQueueVisible: true, language: .english, activeStage: .delivering)
        XCTAssertEqual(recording?.phase, .recording)
    }

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
            L10n.text(.workflowPreparingAudio, language: .english)
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
            L10n.text(.streamActivityRecording, language: .english)
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
            L10n.text(.workflowTranscribing, language: .english)
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
            L10n.text(.workflowTranscribing, language: .english)
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
