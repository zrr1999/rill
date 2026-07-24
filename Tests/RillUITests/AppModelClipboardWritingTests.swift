import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
extension AppModelTests {
    func testCopyTextToClipboardUsesInjectedWriter() {
        var writtenTexts: [String] = []
        let harness = makeHarness(writeClipboardTextAction: { text in
            writtenTexts.append(text)
        })

        harness.model.copyTextToClipboard("copied by Rill")

        XCTAssertEqual(writtenTexts, ["copied by Rill"])
    }

    func testCopyDiagnosticEventDoesNotExportCodeShapedSecrets() throws {
        var writtenTexts: [String] = []
        let harness = makeHarness(writeClipboardTextAction: { text in
            writtenTexts.append(text)
        })
        let alphanumericCanary = "CANARYSECRET123456789"
        let base64Canary = "Q0FOQVJZU0VDUkVUMTIzNDU2Nzg5"
        let hexadecimalCanary = "43414e415259534543524554313233343536373839"
        let event = DiagnosticEventSanitizer.sanitize(
            DiagnosticEvent(
                subsystem: .session,
                level: .error,
                event: "session.action",
                message: alphanumericCanary,
                metadata: [
                    "actionID": alphanumericCanary,
                    "provider.model": base64Canary,
                    "recognizerID": hexadecimalCanary,
                    "resultCode": "failed",
                ]
            )
        )

        harness.model.copyDiagnosticEvent(event)

        let payload = try XCTUnwrap(writtenTexts.first)
        XCTAssertEqual(writtenTexts.count, 1)
        XCTAssertTrue(payload.contains("event: session.action"))
        XCTAssertTrue(payload.contains("resultCode=failed"))
        XCTAssertFalse(payload.contains(alphanumericCanary))
        XCTAssertFalse(payload.contains(base64Canary))
        XCTAssertFalse(payload.contains(hexadecimalCanary))
    }
}
