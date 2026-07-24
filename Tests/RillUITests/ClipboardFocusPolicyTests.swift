import XCTest

@testable import RillUI

final class ClipboardFocusPolicyTests: XCTestCase {
    func testEnteringClipboardPreservesTheNavigationInitiator() {
        XCTAssertNil(
            ClipboardViewFocusPolicy.targetAfterSectionChange(
                current: nil,
                section: .history
            )
        )
    }

    func testLeavingSearchForRoutingMovesFocusToTheSectionPicker() {
        XCTAssertEqual(
            ClipboardViewFocusPolicy.targetAfterSectionChange(
                current: .search,
                section: .routing
            ),
            .sectionPicker
        )
    }

    func testSearchIsOnlyVisibleForClipboardItemSections() {
        XCTAssertTrue(ClipboardViewFocusPolicy.showsSearch(in: .current))
        XCTAssertTrue(ClipboardViewFocusPolicy.showsSearch(in: .history))
        XCTAssertFalse(ClipboardViewFocusPolicy.showsSearch(in: .routing))
    }

    func testSearchFocusSurvivesClipboardItemSectionChanges() {
        for section in [ClipboardViewSection.current, .history] {
            XCTAssertEqual(
                ClipboardViewFocusPolicy.targetAfterSectionChange(
                    current: .search,
                    section: section
                ),
                .search
            )
        }
    }

    func testNonSearchFocusIsNeverClearedByASectionChange() {
        for section in ClipboardViewSection.allCases {
            XCTAssertEqual(
                ClipboardViewFocusPolicy.targetAfterSectionChange(
                    current: .sectionPicker,
                    section: section
                ),
                .sectionPicker
            )
        }
    }

    func testRowFocusMovesToSectionPickerWhenLeavingItemSections() {
        let entryID = UUID()

        XCTAssertEqual(
            ClipboardViewFocusPolicy.targetAfterSectionChange(
                current: .entry(entryID),
                section: .routing
            ),
            .sectionPicker
        )
        XCTAssertEqual(
            ClipboardViewFocusPolicy.targetAfterSectionChange(
                current: .entry(entryID),
                section: .history
            ),
            .entry(entryID)
        )
    }

    func testFocusedRowOwnsSelectionAndMovesWithArrowKeys() throws {
        let entryIDs = [UUID(), UUID(), UUID()]
        let resolution = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: entryIDs[0],
            focusTarget: .entry(entryIDs[1]),
            previousEntryIDs: entryIDs,
            visibleEntryIDs: entryIDs,
            section: .history
        )

        XCTAssertEqual(resolution.selectedEntryID, entryIDs[1])
        XCTAssertEqual(resolution.focusTarget, .entry(entryIDs[1]))
        XCTAssertEqual(
            ClipboardViewFocusPolicy.entryIDByMovingFocus(
                from: resolution.focusTarget,
                direction: 1,
                visibleEntryIDs: entryIDs
            ),
            entryIDs[2]
        )
        XCTAssertEqual(
            ClipboardViewFocusPolicy.entryIDByMovingFocus(
                from: .entry(entryIDs[0]),
                direction: -1,
                visibleEntryIDs: entryIDs
            ),
            entryIDs[0]
        )
        XCTAssertNil(
            ClipboardViewFocusPolicy.entryIDByMovingFocus(
                from: .search,
                direction: 1,
                visibleEntryIDs: entryIDs
            )
        )
    }

    func testRemovingFocusedRowRelocatesToNearestSurvivor() {
        let entryIDs = [UUID(), UUID(), UUID()]

        let middleRemoved = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: entryIDs[1],
            focusTarget: .entry(entryIDs[1]),
            previousEntryIDs: entryIDs,
            visibleEntryIDs: [entryIDs[0], entryIDs[2]],
            section: .history
        )
        XCTAssertEqual(middleRemoved.selectedEntryID, entryIDs[2])
        XCTAssertEqual(middleRemoved.focusTarget, .entry(entryIDs[2]))

        let lastRemoved = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: entryIDs[2],
            focusTarget: .entry(entryIDs[2]),
            previousEntryIDs: entryIDs,
            visibleEntryIDs: [entryIDs[0], entryIDs[1]],
            section: .history
        )
        XCTAssertEqual(lastRemoved.selectedEntryID, entryIDs[1])
        XCTAssertEqual(lastRemoved.focusTarget, .entry(entryIDs[1]))
    }

    func testFilteringAllRowsRehomesRowFocusWithoutStealingSearchFocus() {
        let entryID = UUID()

        let rowFocused = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: entryID,
            focusTarget: .entry(entryID),
            previousEntryIDs: [entryID],
            visibleEntryIDs: [],
            section: .current
        )
        XCTAssertNil(rowFocused.selectedEntryID)
        XCTAssertEqual(rowFocused.focusTarget, .search)

        let searchFocused = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: entryID,
            focusTarget: .search,
            previousEntryIDs: [entryID],
            visibleEntryIDs: [],
            section: .history
        )
        XCTAssertNil(searchFocused.selectedEntryID)
        XCTAssertEqual(searchFocused.focusTarget, .search)
    }

    func testInitialSelectionDoesNotStealFocusFromSidebarNavigation() {
        let entryID = UUID()
        let resolution = ClipboardViewFocusPolicy.resolveEntriesChange(
            selectedEntryID: nil,
            focusTarget: nil,
            previousEntryIDs: [],
            visibleEntryIDs: [entryID],
            section: .history
        )

        XCTAssertEqual(resolution.selectedEntryID, entryID)
        XCTAssertNil(resolution.focusTarget)
    }

    func testPersistenceRetryRehomesOnlyItsOwnFocusToAStableSectionControl() {
        for section in [ClipboardViewSection.current, .history] {
            XCTAssertEqual(
                ClipboardViewFocusPolicy.targetBeforePersistenceRetry(
                    current: .persistenceRetry,
                    section: section
                ),
                .search
            )
        }
        XCTAssertEqual(
            ClipboardViewFocusPolicy.targetBeforePersistenceRetry(
                current: .persistenceRetry,
                section: .routing
            ),
            .sectionPicker
        )

        for existingFocus in [
            ClipboardViewFocusTarget?.none,
            .some(.search),
            .some(.sectionPicker),
            .some(.entry(UUID())),
        ] {
            XCTAssertEqual(
                ClipboardViewFocusPolicy.targetBeforePersistenceRetry(
                    current: existingFocus,
                    section: .history
                ),
                existingFocus,
                "Retry must not steal focus that belongs to the sidebar or another page control."
            )
        }
    }
}
