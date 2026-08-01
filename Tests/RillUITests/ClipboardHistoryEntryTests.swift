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

    func testPinnedEntriesSortBeforeNewerUnpinnedEntries() {
        let entries = ClipboardHistoryEntryBuilder.build(
            from: [
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "newer",
                    createdAt: Date(timeIntervalSince1970: 20)
                ),
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "older pinned",
                    createdAt: Date(timeIntervalSince1970: 10),
                    isPinned: true
                ),
            ],
            mergeSimilarText: false
        )

        XCTAssertEqual(entries.map(\.representativeItem.text), ["older pinned", "newer"])
        XCTAssertEqual(entries.map(\.isPinned), [true, false])
    }

    func testMergedEntryIsPinnedWhenAnyUnderlyingItemIsPinned() {
        let entries = ClipboardHistoryEntryBuilder.build(
            from: [
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "same",
                    createdAt: Date(timeIntervalSince1970: 20)
                ),
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "same",
                    createdAt: Date(timeIntervalSince1970: 10),
                    isPinned: true
                ),
            ],
            mergeSimilarText: false
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isPinned)
        XCTAssertEqual(entries[0].mergedItemIDs.count, 2)
    }

    func testSearchUsesAndSemanticsAcrossTextAppTagsAndGroup() throws {
        let entries = ClipboardHistoryEntryBuilder.build(
            from: [
                item(
                    id: UUID(),
                    groupID: ClipboardGroup.defaultGroupID,
                    text: "Swift concurrency",
                    createdAt: Date(),
                    tags: ["reference"],
                    sourceApplicationName: "Xcode"
                )
            ],
            mergeSimilarText: false
        )
        let entry = try XCTUnwrap(entries.first)

        XCTAssertTrue(entry.matchesSearchQuery("swift xcode", groupName: "Development"))
        XCTAssertTrue(entry.matchesSearchQuery("development reference", groupName: "Development"))
        XCTAssertFalse(entry.matchesSearchQuery("swift safari", groupName: "Development"))
    }

    func testMergedSearchIndexHasFixedMemoryBound() throws {
        let items = (0..<20).map { index in
            item(
                id: UUID(),
                groupID: ClipboardGroup.defaultGroupID,
                text: "same",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                alternatives: [
                    String(repeating: "\(index % 10)", count: 2_000)
                ]
            )
        }

        let entry = try XCTUnwrap(
            ClipboardHistoryEntryBuilder.build(
                from: items,
                mergeSimilarText: false
            ).first
        )

        XCTAssertLessThanOrEqual(entry.searchIndexText.count, 16_384)
    }

    private func item(
        id: UUID,
        groupID: UUID,
        text: String,
        createdAt: Date,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        alternatives: [String] = [],
        tags: [String] = [],
        sourceApplicationName: String? = nil,
        isPinned: Bool = false
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: id,
            groupID: groupID,
            text: text,
            alternatives: alternatives,
            createdAt: createdAt,
            sourceKind: .system,
            sourceApplicationName: sourceApplicationName,
            useCount: useCount,
            lastUsedAt: lastUsedAt,
            tags: tags,
            isPinned: isPinned
        )
    }
}
