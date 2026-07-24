import XCTest
@testable import RillCore

final class ClipboardSnapshotTests: XCTestCase {
    func testEmptyImageDataIsNotTransferableContent() {
        let emptyImage = ClipboardSnapshot(
            plainText: "",
            imagePNGData: Data(),
            changeCount: 1
        )
        let textWithEmptyImage = ClipboardSnapshot(
            plainText: "text",
            imagePNGData: Data(),
            changeCount: 2
        )

        XCTAssertFalse(emptyImage.hasTransferableContent)
        XCTAssertTrue(textWithEmptyImage.hasTransferableContent)
    }

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
            captureTags: [.excludeFromWorkflowCapture],
            protections: [.concealed, .transient]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClipboardSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.excludesWorkflowCapture)
    }

    func testClipboardSnapshotDecodesLegacyPayloadWithoutProtections() throws {
        let legacyJSON = """
        {
          "plainText": "legacy",
          "fileURLs": [],
          "changeCount": 3,
          "captureTags": []
        }
        """

        let decoded = try JSONDecoder().decode(
            ClipboardSnapshot.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.plainText, "legacy")
        XCTAssertEqual(decoded.protections, [])
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

    func testClipboardDeliveryFailureCodeReplacesEveryUntrustedDescription() {
        let sentinel = "DO_NOT_LEAK_/Users/private/clipboard_API_KEY_123"

        XCTAssertNil(ClipboardDeliveryFailureCode.sanitizedStoredValue(nil))
        XCTAssertEqual(
            ClipboardDeliveryFailureCode.sanitizedStoredValue(sentinel),
            ClipboardDeliveryFailureCode.deliveryFailed.rawValue
        )
        XCTAssertFalse(
            ClipboardDeliveryFailureCode.sanitizedStoredValue(sentinel)?.contains(sentinel) ?? true
        )
    }
}
