import Foundation
import XCTest

@testable import RillCore

final class RecordModelsTests: XCTestCase {
    func testCollectionPresetsMapToOrthogonalPolicies() {
        XCTAssertEqual(RecordCollectionPreset.stack.selectionPolicy, .newestFirst)
        XCTAssertEqual(
            RecordCollectionPreset.stack.consumptionPolicy,
            .consumeAfterSuccessfulDelivery
        )
        XCTAssertEqual(RecordCollectionPreset.queue.selectionPolicy, .oldestFirst)
        XCTAssertEqual(
            RecordCollectionPreset.queue.consumptionPolicy,
            .consumeAfterSuccessfulDelivery
        )
        XCTAssertEqual(RecordCollectionPreset.list.selectionPolicy, .manual)
        XCTAssertEqual(RecordCollectionPreset.list.consumptionPolicy, .retain)
    }

    func testCollectionCanUseNonPresetPolicyCombination() {
        let collection = RecordCollection(
            name: "Review",
            selectionPolicy: .oldestFirst,
            consumptionPolicy: .retain
        )

        XCTAssertNil(collection.matchingPreset)
    }

    func testRecordPayloadAndIdentityRoundTrip() throws {
        let record = Record(
            payload: .files([
                URL(fileURLWithPath: "/tmp/one"),
                URL(fileURLWithPath: "/tmp/two"),
            ]),
            provenance: RecordProvenance(
                source: RecordSourceIdentity(kind: .systemClipboard),
                sourceBundleIdentifier: "com.example.Source"
            )
        )

        let decoded = try JSONDecoder().decode(
            Record.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.payload.kind, .files)
    }
}
