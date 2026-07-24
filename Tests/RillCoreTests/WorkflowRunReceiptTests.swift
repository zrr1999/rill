import Foundation
import XCTest
@testable import RillCore

final class WorkflowRunReceiptTests: XCTestCase {
    func testDurationBucketsHaveStableBoundaries() {
        XCTAssertEqual(WorkflowRunDurationBucket.classify(elapsedNanoseconds: 0), .under250ms)
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 249_999_999),
            .under250ms
        )
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 250_000_000),
            .ms250To999
        )
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 999_999_999),
            .ms250To999
        )
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 1_000_000_000),
            .s1To4
        )
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 5_000_000_000),
            .s5To14
        )
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 15_000_000_000),
            .s15To59
        )
        XCTAssertEqual(
            WorkflowRunDurationBucket.classify(elapsedNanoseconds: 60_000_000_000),
            .m1Plus
        )
    }

    func testTriggerKindsDistinguishExplicitClipboardUse() {
        XCTAssertTrue(WorkflowRunTriggerKind.allCases.contains(.clipboardUse))
        XCTAssertNotEqual(WorkflowRunTriggerKind.clipboardUse, .stackDelivery)
        XCTAssertNotEqual(WorkflowRunTriggerKind.clipboardUse, .clipboardReplay)
    }

    func testOnlyCaptureDerivedTriggersPermitVoiceHistoryBodies() {
        XCTAssertEqual(
            Set(WorkflowRunTriggerKind.allCases.filter(\.isVoiceCapture)),
            Set([.manual, .menuBar, .hotkey, .wakeWord, .failedAudioRecovery])
        )
        XCTAssertEqual(
            Set(WorkflowRunTriggerKind.allCases.filter { !$0.isVoiceCapture }),
            Set([.clipboardGroupEvent, .stackDelivery, .clipboardUse, .clipboardReplay])
        )
    }

    func testReceiptCodableRoundTripCarriesVersionAndClosedClassifications() throws {
        let receipt = try WorkflowRunReceipt(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workflowID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            trigger: .clipboardReplay,
            timestamp: Date(timeIntervalSince1970: 123),
            duration: .s1To4,
            termination: .partiallyCompleted(code: .processing),
            actionDetails: [
                WorkflowActionReceipt(
                    actionIndex: 0,
                    result: .externalOutput,
                    duration: .ms250To999
                ),
                WorkflowActionReceipt(
                    actionIndex: 1,
                    result: .failed,
                    duration: .under250ms
                ),
                WorkflowActionReceipt(
                    actionIndex: 2,
                    result: .cancelled,
                    duration: .under250ms
                ),
            ]
        )

        let data = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(WorkflowRunReceipt.self, from: data)

        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.outcome, .partiallyCompleted)
    }

    func testReceiptJSONCannotRetainAssociatedActionStringsOrContentFields() throws {
        let textCanary = "PRIVATE-RECOGNIZED-TEXT-7B1F"
        let destinationCanary = "PRIVATE-DESTINATION-9D2C"
        let errorCanary = "PRIVATE-PROVIDER-ERROR-4A8E"
        let mappedResults = [
            WorkflowActionResultCode(ActionResult.externalOutput(destinationCanary)),
            WorkflowActionResultCode(ActionResult.skipped(errorCanary)),
            WorkflowActionResultCode(ActionResult.failed(errorCanary)),
        ]
        let receipt = try WorkflowRunReceipt(
            runID: UUID(),
            workflowID: UUID(),
            trigger: .manual,
            timestamp: Date(timeIntervalSince1970: 456),
            duration: .under250ms,
            termination: .partiallyCompleted(code: .processing),
            actionDetails: mappedResults.enumerated().map { index, result in
                WorkflowActionReceipt(
                    actionIndex: index,
                    result: result,
                    duration: .unavailable
                )
            }
        )

        let data = try JSONEncoder().encode(receipt)
        let json = String(decoding: data, as: UTF8.self)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNil(object["startedAt"])
        XCTAssertNil(object["durationMilliseconds"])
        XCTAssertNil(object["workflowName"])
        XCTAssertNil(object["actionID"])
        XCTAssertNil(object["text"])
        XCTAssertFalse(json.contains(textCanary))
        XCTAssertFalse(json.contains(destinationCanary))
        XCTAssertFalse(json.contains(errorCanary))
    }

    func testReceiptRejectsUnsupportedSchemaAndInvalidActionDetailBounds() throws {
        let valid = try WorkflowRunReceipt(
            runID: UUID(),
            workflowID: nil,
            trigger: .hotkey,
            timestamp: Date(),
            duration: .s5To14,
            termination: .completed
        )
        let validData = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        object["schemaVersion"] = 2
        let futureData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(WorkflowRunReceipt.self, from: futureData)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowRunReceiptValidationError,
                .unsupportedSchemaVersion(2)
            )
        }

        let tooMany = (0 ... WorkflowRunReceipt.maximumActionDetails).map { index in
            WorkflowActionReceipt(
                actionIndex: index,
                result: .injected,
                duration: .under250ms
            )
        }
        XCTAssertThrowsError(
            try WorkflowRunReceipt(
                runID: UUID(),
                workflowID: nil,
                trigger: .manual,
                timestamp: Date(),
                duration: .under250ms,
                termination: .completed,
                actionDetails: tooMany,
                detailsTruncated: true
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowRunReceiptValidationError,
                .tooManyActionDetails(WorkflowRunReceipt.maximumActionDetails + 1)
            )
        }

        XCTAssertThrowsError(
            try WorkflowRunReceipt(
                runID: UUID(),
                workflowID: nil,
                trigger: .manual,
                timestamp: Date(),
                duration: .under250ms,
                termination: .completed,
                actionDetails: [
                    WorkflowActionReceipt(
                        actionIndex: 1,
                        result: .injected,
                        duration: .under250ms
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowRunReceiptValidationError,
                .invalidActionSequence
            )
        }

        XCTAssertThrowsError(
            try WorkflowRunReceipt(
                runID: UUID(),
                workflowID: nil,
                trigger: .manual,
                timestamp: Date(),
                duration: .under250ms,
                termination: .completed,
                detailsTruncated: true
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowRunReceiptValidationError,
                .inconsistentTruncationFlag
            )
        }
    }
}
