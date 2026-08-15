import XCTest
@testable import RillCore

final class RecordCollectionEventTests: XCTestCase {
    func testDescriptorRoundTripsExactRecordAndMembershipCoordinate() throws {
        let descriptor = makeDescriptor(kind: .recordEdited)

        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(
            RecordCollectionEventDescriptor.self,
            from: encoded
        )

        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(decoded.recordID, descriptor.recordID)
        XCTAssertEqual(decoded.membershipID, descriptor.membershipID)
        XCTAssertEqual(decoded.membershipRevision, 7)
    }

    func testLegacyItemKindsDecodeButRecordKindsEncode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(RecordCollectionEventKind.self, from: Data("\"itemEdited\"".utf8)),
            .recordEdited
        )
        XCTAssertEqual(
            try decoder.decode(RecordCollectionActionKind.self, from: Data("\"editItem\"".utf8)),
            .editRecord
        )
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(RecordCollectionEventKind.recordEdited), as: UTF8.self),
            "\"recordEdited\""
        )
    }

    func testVoiceInputTriggerMatchesUnmarkedRecord() {
        let descriptor = makeDescriptor(captureTags: [])

        XCTAssertTrue(RecordCollectionTrigger.voiceInputPolish.matches(descriptor: descriptor))
    }

    func testVoiceInputTriggerRejectsGeneratedRecordToPreventLoop() {
        let descriptor = makeDescriptor(captureTags: [.polishGenerated])

        let result = RecordCollectionTrigger.voiceInputPolish.matchResult(for: descriptor)

        XCTAssertFalse(result.matched)
        XCTAssertEqual(result.skipReason, .loopPrevented)
    }

    func testTriggerExplainsCollectionMismatch() {
        let descriptor = makeDescriptor(collectionID: RecordCollection.inboxID)

        let result = RecordCollectionTrigger.voiceInputPolish.matchResult(for: descriptor)

        XCTAssertFalse(result.matched)
        XCTAssertEqual(result.skipReason, .sourceCollectionMismatch)
        XCTAssertEqual(result.skipReason?.workflowRunSkipCode, .sourceCollectionMismatch)
    }

    private func makeDescriptor(
        kind: RecordCollectionEventKind = .recordCreated,
        collectionID: RecordCollectionID = RecordCollection.voiceInputID,
        captureTags: [SystemClipboardCaptureTag]? = []
    ) -> RecordCollectionEventDescriptor {
        RecordCollectionEventDescriptor(
            kind: kind,
            collectionID: collectionID,
            recordID: RecordID(),
            membershipID: RecordMembershipID(),
            membershipRevision: 7,
            storeRevision: 11,
            captureTags: captureTags
        )
    }
}
