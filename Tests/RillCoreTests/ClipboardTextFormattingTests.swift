import XCTest
@testable import RillCore

final class ClipboardTextFormattingTests: XCTestCase {
    func testLikelyMarkdownDetectsStructuredMarkdown() {
        let markdown = """
        # Release Notes

        - Adds image previews
        - Renders [Markdown](https://example.com)
        """

        XCTAssertTrue(ClipboardTextFormatting.isLikelyMarkdown(markdown))
        XCTAssertNotNil(ClipboardTextFormatting.renderedMarkdown(markdown))
        XCTAssertEqual(
            ClipboardTextFormatting.summaryText(markdown),
            "Release Notes Adds image previews Renders Markdown"
        )
    }

    func testLikelyMarkdownDetectsInlineFormatting() {
        let markdown = "Use `swift test` before shipping **clipboard** changes."

        XCTAssertTrue(ClipboardTextFormatting.isLikelyMarkdown(markdown))
        XCTAssertEqual(
            ClipboardTextFormatting.summaryText(markdown),
            "Use swift test before shipping clipboard changes."
        )
    }

    func testLikelyMarkdownRejectsPlainText() {
        let plainText = "Please ship version 2.0 tomorrow after lunch."

        XCTAssertFalse(ClipboardTextFormatting.isLikelyMarkdown(plainText))
        XCTAssertNil(ClipboardTextFormatting.renderedMarkdown(plainText))
        XCTAssertEqual(
            ClipboardTextFormatting.summaryText("  hello\n\nworld  "),
            "hello world"
        )
    }

    func testPreviewTextTruncatesNormalizedSummary() {
        XCTAssertEqual(
            ClipboardTextFormatting.previewText("  hello\n\nworld again  ", limit: 12),
            "hello world…"
        )
    }
}
