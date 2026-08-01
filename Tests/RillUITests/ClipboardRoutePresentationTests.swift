import XCTest
@testable import RillCore
@testable import RillUI

final class ClipboardRoutePresentationTests: XCTestCase {
    func testClipboardDeliveryFailurePresentationUsesFixedBilingualCopy() {
        let sentinel = "DO_NOT_LEAK_/Users/private/clipboard_API_KEY_123"
        let english = ClipboardDeliveryFailurePresentation.message(language: .english)
        let simplifiedChinese = ClipboardDeliveryFailurePresentation.message(
            language: .simplifiedChinese
        )

        XCTAssertEqual(
            english,
            "This clipboard item could not be delivered. Return to the target app and retry."
        )
        XCTAssertEqual(simplifiedChinese, "无法投递此剪贴板条目。请返回目标 App 后重试。")
        XCTAssertFalse(english.contains(sentinel))
        XCTAssertFalse(simplifiedChinese.contains(sentinel))
    }

    func testPreviewContextShowsAssignedFallbackAndDefaultGroupsOnly() {
        let assignedGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000001"),
                name: "Assigned",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let hiddenGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000002"),
                name: "Hidden",
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
        let fallbackLaterGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000003"),
                name: "Fallback Later",
                allowsCrossGroupPaste: true,
                fallbackPriority: 1,
                createdAt: Date(timeIntervalSince1970: 30)
            ),
            candidateCreatedAt: Date(timeIntervalSince1970: 30)
        )
        let fallbackSoonerGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000004"),
                name: "Fallback Sooner",
                allowsCrossGroupPaste: true,
                fallbackPriority: 2,
                createdAt: Date(timeIntervalSince1970: 40)
            ),
            candidateCreatedAt: Date(timeIntervalSince1970: 40)
        )

        let presentation = ClipboardRoutePresentation.make(
            explicitGroups: [assignedGroup, hiddenGroup, fallbackLaterGroup, fallbackSoonerGroup],
            defaultGroup: summary(group: .defaultGroup),
            appAssignments: [
                ClipboardAppAssignment(
                    bundleIdentifier: "com.apple.Safari",
                    applicationName: "Safari",
                    groupID: assignedGroup.group.id
                )
            ],
            previewContext: ClipboardRouteContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            )
        )

        XCTAssertEqual(
            presentation.orderedRoutingGroups.map(\.group.id),
            [
                assignedGroup.group.id,
                fallbackLaterGroup.group.id,
                fallbackSoonerGroup.group.id,
                ClipboardGroup.defaultGroup.id,
            ]
        )
        XCTAssertFalse(presentation.visibleGroupIDs.contains(hiddenGroup.group.id))
    }

    func testPreviewContextWithoutAssignmentShowsFallbackAndDefaultOnly() {
        let hiddenGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000011"),
                name: "Hidden",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let fallbackLaterGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000012"),
                name: "Fallback Later",
                allowsCrossGroupPaste: true,
                fallbackPriority: 1,
                createdAt: Date(timeIntervalSince1970: 20)
            ),
            candidateCreatedAt: Date(timeIntervalSince1970: 20)
        )
        let fallbackSoonerGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000013"),
                name: "Fallback Sooner",
                allowsCrossGroupPaste: true,
                fallbackPriority: 2,
                createdAt: Date(timeIntervalSince1970: 30)
            ),
            candidateCreatedAt: Date(timeIntervalSince1970: 30)
        )

        let presentation = ClipboardRoutePresentation.make(
            explicitGroups: [hiddenGroup, fallbackLaterGroup, fallbackSoonerGroup],
            defaultGroup: summary(group: .defaultGroup),
            appAssignments: [],
            previewContext: ClipboardRouteContext(
                applicationName: "Xcode",
                bundleIdentifier: "com.apple.dt.Xcode"
            )
        )

        XCTAssertEqual(
            presentation.orderedRoutingGroups.map(\.group.id),
            [
                ClipboardGroup.defaultGroup.id,
                fallbackLaterGroup.group.id,
                fallbackSoonerGroup.group.id,
            ]
        )
        XCTAssertFalse(presentation.visibleGroupIDs.contains(hiddenGroup.group.id))
    }

    func testMissingPreviewContextKeepsAllExplicitGroupsVisible() {
        let firstGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000021"),
                name: "First",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let secondGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000022"),
                name: "Second",
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )

        let presentation = ClipboardRoutePresentation.make(
            explicitGroups: [firstGroup, secondGroup],
            defaultGroup: summary(group: .defaultGroup),
            appAssignments: [],
            previewContext: nil
        )

        XCTAssertEqual(
            presentation.orderedRoutingGroups.map(\.group.id),
            [firstGroup.group.id, secondGroup.group.id, ClipboardGroup.defaultGroup.id]
        )
        XCTAssertEqual(
            presentation.visibleGroupIDs,
            Set([firstGroup.group.id, secondGroup.group.id, ClipboardGroup.defaultGroup.id])
        )
    }

    func testVisibleEntriesExcludeHiddenGroupsInPreviewContext() {
        let assignedGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000031"),
                name: "Assigned",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let hiddenGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000032"),
                name: "Hidden",
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
        let fallbackGroup = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000033"),
                name: "Fallback",
                allowsCrossGroupPaste: true,
                createdAt: Date(timeIntervalSince1970: 30)
            ),
            candidateCreatedAt: Date(timeIntervalSince1970: 30)
        )

        let presentation = ClipboardRoutePresentation.make(
            explicitGroups: [assignedGroup, hiddenGroup, fallbackGroup],
            defaultGroup: summary(group: .defaultGroup),
            appAssignments: [
                ClipboardAppAssignment(
                    bundleIdentifier: "com.apple.Safari",
                    applicationName: "Safari",
                    groupID: assignedGroup.group.id
                )
            ],
            previewContext: ClipboardRouteContext(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari"
            )
        )

        let visibleEntries = presentation.visibleEntries(
            from: [
                entry(groupID: assignedGroup.group.id, text: "assigned"),
                entry(groupID: hiddenGroup.group.id, text: "hidden"),
                entry(groupID: fallbackGroup.group.id, text: "fallback"),
                entry(groupID: ClipboardGroup.defaultGroup.id, text: "default"),
            ]
        )

        XCTAssertEqual(
            visibleEntries.map(\.representativeItem.groupID),
            [
                assignedGroup.group.id,
                fallbackGroup.group.id,
                ClipboardGroup.defaultGroup.id,
            ]
        )
    }

    func testVisibleEntriesCanLimitHistoryToRemainingItems() {
        let group = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000041"),
                name: "Assigned",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let keptID = uuid("00000000-0000-0000-0000-000000000042")
        let hiddenConsumedID = uuid("00000000-0000-0000-0000-000000000043")

        let presentation = ClipboardRoutePresentation.make(
            explicitGroups: [group],
            defaultGroup: summary(group: .defaultGroup),
            appAssignments: [],
            previewContext: nil
        )

        let visibleEntries = presentation.visibleEntries(
            from: [
                entry(id: keptID, groupID: group.group.id, text: "kept"),
                entry(id: hiddenConsumedID, groupID: group.group.id, text: "consumed"),
            ],
            historyVisibility: .remainingOnly,
            remainingItemIDs: [keptID]
        )

        XCTAssertEqual(visibleEntries.map(\.representativeItem.id), [keptID])
    }

    func testVisibleEntriesKeepMergedRowWhenAnyMergedItemRemains() {
        let group = summary(
            group: ClipboardGroup(
                id: uuid("00000000-0000-0000-0000-000000000051"),
                name: "Assigned",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let representativeID = uuid("00000000-0000-0000-0000-000000000052")
        let remainingMergedID = uuid("00000000-0000-0000-0000-000000000053")

        let presentation = ClipboardRoutePresentation.make(
            explicitGroups: [group],
            defaultGroup: summary(group: .defaultGroup),
            appAssignments: [],
            previewContext: nil
        )

        let visibleEntries = presentation.visibleEntries(
            from: [
                entry(
                    id: representativeID,
                    groupID: group.group.id,
                    text: "merged",
                    mergedItemIDs: [representativeID, remainingMergedID]
                )
            ],
            historyVisibility: .remainingOnly,
            remainingItemIDs: [remainingMergedID]
        )

        XCTAssertEqual(visibleEntries.map(\.representativeItem.id), [representativeID])
    }

    private func summary(
        group: ClipboardGroup,
        count: Int = 0,
        candidateCreatedAt: Date? = nil
    ) -> ClipboardGroupSummary {
        ClipboardGroupSummary(
            group: group,
            count: count,
            previewText: nil,
            candidateCreatedAt: candidateCreatedAt
        )
    }

    private func entry(
        id: UUID = UUID(),
        groupID: UUID,
        text: String,
        mergedItemIDs: [UUID]? = nil
    ) -> ClipboardHistoryEntry {
        ClipboardHistoryEntry(
            representativeItem: ClipboardHistoryItem(
                id: id,
                groupID: groupID,
                text: text,
                sourceKind: .system
            ),
            mergedItemIDs: mergedItemIDs ?? [id],
            copyCount: 1,
            pasteCount: 0,
            lastUsedAt: nil,
            alternatives: [],
            tags: [],
            searchIndexText: ClipboardHistoryEntry.normalizeSearchText(text),
            includesSimilarText: false,
            isPinned: false
        )
    }

    private func uuid(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            XCTFail("Invalid UUID: \(value)")
            return UUID()
        }
        return uuid
    }
}
