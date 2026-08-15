import XCTest
@testable import RillCore

final class RecordTextFormattingTests: XCTestCase {
    func testLikelyMarkdownDetectsStructuredMarkdown() {
        let markdown = """
        # Release Notes

        - Adds image previews
        - Renders [Markdown](https://example.com)
        """

        XCTAssertTrue(RecordTextFormatting.isLikelyMarkdown(markdown))
        XCTAssertNotNil(RecordTextFormatting.renderedMarkdown(markdown))
        XCTAssertEqual(
            RecordTextFormatting.summaryText(markdown),
            "Release Notes Adds image previews Renders Markdown"
        )
    }

    func testLikelyMarkdownDetectsInlineFormatting() {
        let markdown = "Use `swift test` before shipping **clipboard** changes."

        XCTAssertTrue(RecordTextFormatting.isLikelyMarkdown(markdown))
        XCTAssertEqual(
            RecordTextFormatting.summaryText(markdown),
            "Use swift test before shipping clipboard changes."
        )
    }

    func testLikelyMarkdownRejectsPlainText() {
        let plainText = "Please ship version 2.0 tomorrow after lunch."

        XCTAssertFalse(RecordTextFormatting.isLikelyMarkdown(plainText))
        XCTAssertNil(RecordTextFormatting.renderedMarkdown(plainText))
        XCTAssertEqual(
            RecordTextFormatting.summaryText("  hello\n\nworld  "),
            "hello world"
        )
    }

    func testPreviewTextTruncatesNormalizedSummary() {
        XCTAssertEqual(
            RecordTextFormatting.previewText("  hello\n\nworld again  ", limit: 12),
            "hello world…"
        )
    }
}
