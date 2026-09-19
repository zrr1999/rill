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
