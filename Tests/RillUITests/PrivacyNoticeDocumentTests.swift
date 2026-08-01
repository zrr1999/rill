import Foundation
import XCTest
@testable import RillUI

final class PrivacyNoticeDocumentTests: XCTestCase {
    func testRepositoryPrivacyNoticeIsValidAndBilingual() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let markdown = try String(
            contentsOf: projectRoot.appendingPathComponent("PRIVACY.md"),
            encoding: .utf8
        )

        let document = try PrivacyNoticeDocument(markdown: markdown)

        XCTAssertEqual(document.markdown, markdown)
        XCTAssertFalse(markdown.localizedCaseInsensitiveContains("deepgram"))
        XCTAssertTrue(markdown.contains("OpenAI Responses API"))
        XCTAssertTrue(markdown.contains("store: false"))
        XCTAssertTrue(markdown.contains("does not silently fall back"))
        XCTAssertTrue(markdown.contains("不会静默回退"))
        XCTAssertTrue(markdown.contains("github.com"))
        XCTAssertTrue(markdown.contains("release-assets.githubusercontent.com"))
        XCTAssertFalse(markdown.contains("huggingface.co"))
        XCTAssertFalse(markdown.contains("cas-bridge.xethub.hf.co"))
        XCTAssertFalse(markdown.contains("WhisperKit local speech"))
        XCTAssertFalse(markdown.contains("WhisperKit 本地语音"))
        XCTAssertTrue(
            markdown.contains("Model download sends no microphone audio or recognized text")
        )
        XCTAssertTrue(
            markdown.contains("模型下载不会发送麦克风音频或识别文本")
        )
        XCTAssertTrue(markdown.contains("Qwen3-ASR 0.6B INT8"))
        XCTAssertTrue(markdown.contains("SenseVoiceSmall INT8"))
        XCTAssertTrue(markdown.contains("Apple Shortcuts"))
        XCTAssertTrue(markdown.contains("Apple 快捷指令"))
    }

    func testDocumentRejectsMissingRequiredSection() {
        XCTAssertThrowsError(try PrivacyNoticeDocument(markdown: "# incomplete")) { error in
            XCTAssertEqual(
                error as? PrivacyNoticeDocumentError,
                .missingRequiredSection("# Rill Technical Privacy and Data Flow Notice")
            )
        }
    }

    func testDocumentRejectsEmptyAndOversizedInput() {
        XCTAssertThrowsError(try PrivacyNoticeDocument(markdown: "")) { error in
            XCTAssertEqual(error as? PrivacyNoticeDocumentError, .emptyDocument)
        }
        XCTAssertThrowsError(
            try PrivacyNoticeDocument(
                markdown: String(repeating: "x", count: PrivacyNoticeDocument.maximumByteCount + 1)
            )
        ) { error in
            XCTAssertEqual(error as? PrivacyNoticeDocumentError, .documentTooLarge)
        }
    }
}
