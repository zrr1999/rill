import XCTest
@testable import RillCore
@testable import RillUI

final class ClipboardHistoryEntryTests: XCTestCase {
    func testCurrentEntriesUseRemainingItemsInsteadOfConsumedHistoryRepresentative() {
        let groupID = ClipboardGroup.defaultGroupID
        let consumedID = UUID()
        let remainingID = UUID()
        let consumed = item(
            id: consumedID,
            groupID: groupID,
            text: "same text",
            createdAt: Date(timeIntervalSince1970: 20),
            useCount: 1,
            lastUsedAt: Date(timeIntervalSince1970: 30)
        )
        let remaining = item(
            id: remainingID,
            groupID: groupID,
            text: "same text",
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let historyEntries = ClipboardHistoryEntryBuilder.build(
            from: [consumed, remaining],
            mergeSimilarText: false
        )
        let currentEntries = ClipboardHistoryEntryBuilder.buildCurrent(
            from: [consumed, remaining],
            remainingItemIDs: [remainingID],
            mergeSimilarText: false
        )

        XCTAssertEqual(historyEntries.first?.representativeItem.id, consumedID)
        XCTAssertEqual(historyEntries.first?.mergedItemIDs, [consumedID, remainingID])
        XCTAssertEqual(historyEntries.first?.copyCount, 2)
        XCTAssertEqual(historyEntries.first?.pasteCount, 1)
        XCTAssertEqual(currentEntries.first?.representativeItem.id, remainingID)
        XCTAssertEqual(currentEntries.first?.mergedItemIDs, [remainingID])
        XCTAssertEqual(currentEntries.first?.copyCount, 1)
        XCTAssertEqual(currentEntries.first?.pasteCount, 0)
    }

    func testHistoryEntriesAggregateCopyUseCountsAndLastUsedAt() {
        let firstUse = Date(timeIntervalSince1970: 30)
        let latestUse = Date(timeIntervalSince1970: 60)
        let entries = ClipboardHistoryEntryBuilder.build(
            from: [
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "reused text",
                    createdAt: Date(timeIntervalSince1970: 10),
                    useCount: 1,
                    lastUsedAt: firstUse
                ),
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "reused text",
                    createdAt: Date(timeIntervalSince1970: 20),
                    useCount: 2,
                    lastUsedAt: latestUse
                ),
            ],
            mergeSimilarText: false
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.copyCount, 2)
        XCTAssertEqual(entries.first?.pasteCount, 3)
        XCTAssertEqual(entries.first?.lastUsedAt, latestUse)
    }

    private func item(
        id: UUID,
        groupID: UUID,
        text: String,
        createdAt: Date,
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: id,
            groupID: groupID,
            text: text,
            createdAt: createdAt,
            sourceKind: .system,
            useCount: useCount,
            lastUsedAt: lastUsedAt
        )
    }
}
