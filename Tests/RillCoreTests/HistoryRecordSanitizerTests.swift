import Foundation
import XCTest
@testable import RillCore

final class HistoryRecordSanitizerTests: XCTestCase {
    func testUnknownFailureContentIsReplacedInsteadOfTruncatedOrRetained() {
        let unsafe = "POST https://speech.example.test/private returned token=secret and body=transcript"

        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(unsafe),
            HistoryFailureSanitizer.genericMessage
        )
        XCTAssertFalse(HistoryFailureSanitizer.genericMessage.contains("speech.example.test"))
        XCTAssertFalse(HistoryFailureSanitizer.genericMessage.contains("secret"))
    }

    func testKnownRecoveryCategoriesUseFixedContentFreeMessages() {
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize("Deepgram API key is missing: dg-secret"),
            "The Deepgram API key is unavailable. Open Settings, save a key, and retry."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize("Microphone permission denied at /private/input.wav"),
            "Microphone access is required. Grant access in System Settings and retry."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize("Cloud run blocked by privacy approval for selected text"),
            "The run was blocked by the current privacy policy. Review Privacy settings and retry."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(HistoryFailureSanitizer.noSpeechMessage),
            HistoryFailureSanitizer.noSpeechMessage
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(HistoryFailureSanitizer.noSpeechMessage + " private"),
            HistoryFailureSanitizer.genericMessage,
            "Only the exact content-free no-speech message may cross the history boundary."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(
                HistoryFailureSanitizer.globalInputUnavailableMessage
            ),
            HistoryFailureSanitizer.globalInputUnavailableMessage
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(
                HistoryFailureSanitizer.globalInputUnavailableMessage + " private"
            ),
            HistoryFailureSanitizer.genericMessage,
            "Only the exact content-free global-input message may cross the history boundary."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(
                HistoryFailureSanitizer.recognitionTimeoutMessage
            ),
            HistoryFailureSanitizer.recognitionTimeoutMessage
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(
                HistoryFailureSanitizer.recognitionTimeoutMessage + " transcript-canary"
            ),
            HistoryFailureSanitizer.genericMessage,
            "Only the exact content-free recognition-timeout message may cross the history boundary."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(
                HistoryFailureSanitizer.recognitionRecoveryPendingMessage
            ),
            HistoryFailureSanitizer.recognitionRecoveryPendingMessage
        )
    }

    func testCommittedOutputFailurePreservesOnlyExactNonRetryableMessage() {
        let failure = CommittedOutputFailure.clipboardRestorationFailedAfterInjection

        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(failure.message),
            failure.message
        )
        XCTAssertTrue(failure.message.contains("Do not repeat the injection"))
        XCTAssertFalse(failure.message.lowercased().contains("then retry"))
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(failure.message + " payload-canary"),
            HistoryFailureSanitizer.genericMessage,
            "Only the exact closed failure message may cross the history boundary."
        )
        XCTAssertEqual(
            HistoryFailureSanitizer.sanitize(failure.message.lowercased()),
            HistoryFailureSanitizer.genericMessage,
            "Case variants are not the exact closed failure message."
        )
    }

    func testRecordSanitizerPreservesRunIdentityAndDeliveredText() {
        let correctionSource = RecognitionCorrectionSource(
            preMappingText: "recognized text",
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                clipboardGroupID: UUID(),
                locale: "en-US"
            )
        )
        let record = HistoryRecord(
            runID: UUID(),
            workflowID: UUID(),
            workflow: WorkflowPresentation(fallbackName: "Dictation"),
            finalText: "delivered text",
            failureMessage: "provider body must not persist",
            timestamp: Date(timeIntervalSince1970: 42),
            isStackRelated: true,
            outcome: .failed,
            correctionSource: correctionSource,
            trigger: .failedAudioRecovery
        )

        let sanitized = HistoryRecordSanitizer.sanitize(record)

        XCTAssertEqual(sanitized.id, record.id)
        XCTAssertEqual(sanitized.runID, record.runID)
        XCTAssertEqual(sanitized.workflowID, record.workflowID)
        XCTAssertEqual(sanitized.finalText, "delivered text")
        XCTAssertEqual(sanitized.failureMessage, HistoryFailureSanitizer.genericMessage)
        XCTAssertEqual(sanitized.correctionSource, correctionSource)
        XCTAssertEqual(sanitized.trigger, .failedAudioRecovery)
    }

    func testAuthoritativeTriggerRoundTripsWhileLegacyPayloadRemainsUnclassified() throws {
        let record = HistoryRecord(
            runID: UUID(),
            workflowID: UUID(),
            workflow: WorkflowPresentation(fallbackName: "Custom Dictation"),
            finalText: "body",
            outcome: .completed,
            trigger: .hotkey
        )
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(record)

        XCTAssertEqual(try JSONDecoder().decode(HistoryRecord.self, from: encoded), record)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "trigger")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyRecord = try JSONDecoder().decode(HistoryRecord.self, from: legacyData)

        XCTAssertNil(legacyRecord.trigger)
        XCTAssertEqual(legacyRecord.finalText, record.finalText)
    }
}
