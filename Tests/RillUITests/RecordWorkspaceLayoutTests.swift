import XCTest

@testable import RillUI

final class RecordWorkspaceLayoutTests: XCTestCase {
    func testUsableDesktopWidthKeepsRecordListAndInspectorVisible() {
        XCTAssertEqual(
            RecordWorkspaceLayoutPolicy.presentation(
                availableWidth: RecordWorkspaceLayoutPolicy.splitMinimumWidth,
                hasSelectedRecord: false
            ),
            .split
        )
        XCTAssertEqual(
            RecordWorkspaceLayoutPolicy.presentation(
                availableWidth: 900,
                hasSelectedRecord: true
            ),
            .split
        )
    }

    func testCompactWidthShowsTheListUntilARecordIsSelected() {
        let compactWidth = RecordWorkspaceLayoutPolicy.splitMinimumWidth - 1

        XCTAssertEqual(
            RecordWorkspaceLayoutPolicy.presentation(
                availableWidth: compactWidth,
                hasSelectedRecord: false
            ),
            .list
        )
        XCTAssertEqual(
            RecordWorkspaceLayoutPolicy.presentation(
                availableWidth: compactWidth,
                hasSelectedRecord: true
            ),
            .inspector
        )
    }
}
