import XCTest
@testable import VoxTypeCore

final class ClipboardSnapshotTests: XCTestCase {
    func testAppendingCaptureTagsAvoidsDuplicatesAndFlagsWorkflowExclusion() {
        let snapshot = ClipboardSnapshot(plainText: "hello", changeCount: 1)
            .appendingCaptureTags([.excludeFromWorkflowCapture, .excludeFromWorkflowCapture])

        XCTAssertEqual(snapshot.captureTags, [.excludeFromWorkflowCapture])
        XCTAssertTrue(snapshot.excludesWorkflowCapture)
    }

    func testClipboardSnapshotCodableRoundTripsCaptureTags() throws {
        let snapshot = ClipboardSnapshot(
            plainText: "hello",
            fileURLs: [URL(fileURLWithPath: "/tmp/demo.txt")],
            changeCount: 7,
            captureTags: [.excludeFromWorkflowCapture]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClipboardSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.excludesWorkflowCapture)
    }

    func testClipboardHistoryItemSnapshotAvoidsSyntheticPlainTextForImagesAndFiles() {
        let imageItem = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroup.id,
            contentKind: .image,
            text: "Copied image",
            imagePNGData: Data([0x89, 0x50]),
            sourceKind: .system
        )
        let fileItem = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroup.id,
            contentKind: .files,
            text: "alpha.png",
            fileURLs: [URL(fileURLWithPath: "/tmp/alpha.png")],
            sourceKind: .system
        )

        XCTAssertEqual(imageItem.clipboardSnapshot.plainText, "")
        XCTAssertEqual(imageItem.clipboardSnapshot.imagePNGData, imageItem.imagePNGData)
        XCTAssertEqual(fileItem.clipboardSnapshot.plainText, "")
        XCTAssertEqual(fileItem.clipboardSnapshot.fileURLs, fileItem.fileURLs)
    }
}
