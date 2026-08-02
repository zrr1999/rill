import Foundation
import XCTest
@testable import RillCore

final class ClipboardItemDryRunModelsTests: XCTestCase {
    func testClipboardItemVersionAdvancesWithoutABAOrWraparound() {
        let generationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let initial = ClipboardItemVersion(generationID: generationID, revision: 1)
        let advanced = initial.advanced()
        let exhausted = ClipboardItemVersion(
            generationID: generationID,
            revision: UInt64.max
        ).advanced()

        XCTAssertEqual(advanced.generationID, generationID)
        XCTAssertEqual(advanced.revision, 2)
        XCTAssertNotEqual(exhausted.generationID, generationID)
        XCTAssertEqual(exhausted.revision, 1)
    }

    func testClipboardItemVersionDecodeRejectsZeroRevision() throws {
        let data = Data(
            #"{"generationID":"11111111-2222-3333-4444-555555555555","revision":0}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipboardItemVersion.self, from: data)
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testLegacyClipboardItemDecodeCreatesAndPersistsExactVersion() throws {
        let item = ClipboardHistoryItem(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            groupID: ClipboardGroup.defaultGroupID,
            text: "legacy",
            sourceKind: .system
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "version")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipboardHistoryItem.self, from: legacyData)
        let upgradedData = try JSONEncoder().encode(decoded)
        let upgradedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upgradedData) as? [String: Any]
        )

        XCTAssertEqual(decoded.version.revision, 1)
        XCTAssertNotNil(upgradedObject["version"])
    }

    func testSubjectIsNonCodableAndHasOnlyContentFreeStoredMetadata() {
        let subject = ClipboardItemDryRunSubject(
            itemID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            itemVersion: ClipboardItemVersion(
                generationID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
                revision: 7
            ),
            groupID: ClipboardGroup.defaultGroupID,
            contentKind: .text,
            captureTags: [
                .excludeFromWorkflowCapture,
                .excludeFromWorkflowCapture,
                .polishGenerated,
            ],
            hasTransferableContent: true
        )

        XCTAssertFalse(ClipboardItemDryRunSubject.self is any Encodable.Type)
        XCTAssertFalse(ClipboardItemDryRunSubject.self is any Decodable.Type)
        XCTAssertEqual(
            Set(Mirror(reflecting: subject).children.compactMap(\.label)),
            [
                "itemID",
                "itemVersion",
                "groupID",
                "contentKind",
                "captureTags",
                "hasTransferableContent",
            ]
        )
        XCTAssertEqual(
            subject.captureTags,
            [.excludeFromWorkflowCapture, .polishGenerated]
        )
        XCTAssertTrue(subject.excludesWorkflowCapture)
    }

    func testVersionedReceiptRoundTripsEveryClosedValueWithoutPayloadFields() throws {
        let receipt = ClipboardItemDryRunReceipt(
            workflowID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            operation: .replace,
            status: .blocked,
            reason: .ambiguousSourceReplacement,
            reads: ClipboardItemDryRunReadCategory.allCases.map {
                ClipboardItemDryRunRead(category: $0, usage: .conditional)
            },
            transforms: WorkflowExplanationTransformKind.allCasesForDryRunTest.map {
                WorkflowExplanationTransform(
                    kind: $0,
                    availability: .available,
                    usage: .required,
                    processingDestination: .onDevice
                )
            },
            actionEffects: ClipboardItemDryRunEffect.allCases.map {
                ClipboardItemDryRunActionEffect(
                    sourceActionIndex: 0,
                    effect: $0,
                    configurationState: .configured,
                    processingDestination: .localStorage
                )
            },
            processingDestinations: [
                .onDevice,
                .cloudService,
                .clipboard,
                .focusedApplication,
                .localStorage,
                .localAutomation,
                .localFile,
                .remoteEndpoint,
                .unclassified,
            ],
            sourceReplacementPlan: .ambiguous,
            privacyReasons: PrivacyRunEvaluationReason.allCases,
            redactedInputCategories: [.focusedSelection, .clipboardText],
            issues: ClipboardItemDryRunIssueKind.allCases.map {
                ClipboardItemDryRunIssue(kind: $0, component: .outputAction, componentIndex: 0)
            }
        )

        let data = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(ClipboardItemDryRunReceipt.self, from: data)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.version, .v1)
        XCTAssertTrue(json.contains("\"version\":1"))
        for forbiddenField in [
            "text",
            "imagePNGData",
            "fileURLs",
            "alternatives",
            "sourceApplicationName",
            "sourceBundleIdentifier",
            "prompt",
            "endpoint",
            "credential",
        ] {
            XCTAssertFalse(json.contains("\"(forbiddenField)\""), forbiddenField)
        }
    }

    func testEveryDryRunClosedEnumCaseRoundTrips() throws {
        try assertRoundTrips(ClipboardItemDryRunReceiptVersion.allCases)
        try assertRoundTrips(ClipboardItemDryRunOperation.allCases)
        try assertRoundTrips(ClipboardItemDryRunStatus.allCases)
        try assertRoundTrips(ClipboardItemDryRunReason.allCases)
        try assertRoundTrips(ClipboardItemDryRunReadCategory.allCases)
        try assertRoundTrips(ClipboardItemDryRunEffect.allCases)
        try assertRoundTrips(ClipboardItemDryRunSourceReplacementPlan.allCases)
        try assertRoundTrips(ClipboardItemDryRunIssueKind.allCases)
    }

    private func assertRoundTrips<Value: Codable & Equatable>(_ value: Value) throws {
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: encoded), value)
    }
}

private extension WorkflowExplanationTransformKind {
    static let allCasesForDryRunTest: [WorkflowExplanationTransformKind] = [
        .vocabularyMapping,
        .snippetReplacement,
        .languageModelRewrite,
        .languageModelAnswer,
        .whitespaceNormalization,
    ]
}
