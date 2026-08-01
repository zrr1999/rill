import Foundation
import XCTest
@testable import RillUI

final class HistoryRetryFocusPolicyTests: XCTestCase {
    func testRetryOwnedFocusMovesToStableSummaryWithoutKeyboardRing() {
        XCTAssertEqual(
            HistoryInitialLoadRetryFocusPolicy.transition(
                keyboardFocus: .initialLoadRetry,
                accessibilityFocus: .initialLoadRetry
            ),
            HistoryInitialLoadRetryFocusTransition(
                keyboardFocus: nil,
                accessibilityFocus: .scopeSummary
            )
        )
    }

    func testRetryRehomesOnlyTheFocusChannelItOwns() {
        let entryID = UUID()
        let keyboardEntryID = UUID()

        XCTAssertEqual(
            HistoryInitialLoadRetryFocusPolicy.transition(
                keyboardFocus: .initialLoadRetry,
                accessibilityFocus: .entry(entryID)
            ),
            HistoryInitialLoadRetryFocusTransition(
                keyboardFocus: nil,
                accessibilityFocus: .entry(entryID)
            )
        )
        XCTAssertEqual(
            HistoryInitialLoadRetryFocusPolicy.transition(
                keyboardFocus: .entry(keyboardEntryID),
                accessibilityFocus: .initialLoadRetry
            ),
            HistoryInitialLoadRetryFocusTransition(
                keyboardFocus: .entry(keyboardEntryID),
                accessibilityFocus: .scopeSummary
            )
        )
    }

    func testMouseRetryPreservesUnrelatedOrAbsentFocus() {
        let entryID = UUID()

        XCTAssertEqual(
            HistoryInitialLoadRetryFocusPolicy.transition(
                keyboardFocus: .entry(entryID),
                accessibilityFocus: .scopeSummary
            ),
            HistoryInitialLoadRetryFocusTransition(
                keyboardFocus: .entry(entryID),
                accessibilityFocus: .scopeSummary
            )
        )
        XCTAssertEqual(
            HistoryInitialLoadRetryFocusPolicy.transition(
                keyboardFocus: nil,
                accessibilityFocus: nil
            ),
            HistoryInitialLoadRetryFocusTransition(
                keyboardFocus: nil,
                accessibilityFocus: nil
            )
        )
    }
}
