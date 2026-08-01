import Foundation
import XCTest
@testable import RillCore

final class ClipboardHistoryItemTests: XCTestCase {
    func testPinnedStateRoundTrips() throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "keep me",
            sourceKind: .system,
            isPinned: true
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardHistoryItem.self, from: encoded)

        XCTAssertTrue(decoded.isPinned)
        XCTAssertEqual(decoded, item)
    }

    func testLegacyItemWithoutPinnedStateDefaultsToUnpinned() throws {
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "legacy",
            sourceKind: .system
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "isPinned")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            ClipboardHistoryItem.self,
            from: legacyData
        )

        XCTAssertFalse(decoded.isPinned)
    }
}
