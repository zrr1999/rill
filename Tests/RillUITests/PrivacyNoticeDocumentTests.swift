import Foundation
import XCTest
@testable import RillUI

final class PrivacyNoticeDocumentTests: XCTestCase {
    func testRepositoryPrivacyNoticeSatisfiesTheProductionDocumentContract() throws {
        _ = try PrivacyNoticeDocument(markdown: repositoryMarkdown())
    }

    func testBundleLoaderReturnsTheValidatedPrivacyNoticeShownBySettings() throws {
        let markdown = try repositoryMarkdown()
        let bundle = try makeBundle(privacyNoticeData: Data(markdown.utf8))

        let document = try PrivacyNoticeDocument.load(from: bundle)

        XCTAssertEqual(document.markdown, markdown)
    }

    func testBundleLoaderDistinguishesMissingInvalidAndOversizedResources() throws {
        XCTAssertThrowsError(
            try PrivacyNoticeDocument.load(from: makeBundle(privacyNoticeData: nil))
        ) { error in
            XCTAssertEqual(error as? PrivacyNoticeDocumentError, .missingResource)
        }
        XCTAssertThrowsError(
            try PrivacyNoticeDocument.load(
                from: makeBundle(privacyNoticeData: Data([0xFF]))
            )
        ) { error in
            XCTAssertEqual(error as? PrivacyNoticeDocumentError, .invalidEncoding)
        }
        XCTAssertThrowsError(
            try PrivacyNoticeDocument.load(
                from: makeBundle(
                    privacyNoticeData: Data(
                        repeating: 0x61,
                        count: PrivacyNoticeDocument.maximumByteCount + 1
                    )
                )
            )
        ) { error in
            XCTAssertEqual(error as? PrivacyNoticeDocumentError, .documentTooLarge)
        }
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

    private func repositoryMarkdown() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("PRIVACY.md"),
            encoding: .utf8
        )
    }

    private func makeBundle(privacyNoticeData: Data?) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.rill.tests.privacy-notice.\(UUID().uuidString)",
            "CFBundleName": "PrivacyNoticeFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        if let privacyNoticeData {
            try privacyNoticeData.write(
                to: resourcesURL.appendingPathComponent("PRIVACY.md")
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: bundleURL)
        }
        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}
