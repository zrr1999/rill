import XCTest
@testable import RillCore

final class SecureWebhookConfigurationTests: XCTestCase {
    func testReferenceHasCanonicalStableIdentityAndSingleValueCodableForm() throws {
        let workflowID = try XCTUnwrap(UUID(uuidString: "A0F99D93-7E4D-46CE-A188-8B713EF229DA"))
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 3)
        )

        XCTAssertEqual(
            reference.rawValue,
            "workflow.webhook.v1:a0f99d93-7e4d-46ce-a188-8b713ef229da:3"
        )
        XCTAssertEqual(WebhookConfigurationReference(rawValue: reference.rawValue), reference)
        XCTAssertNil(WebhookConfigurationReference(workflowID: workflowID, actionIndex: -1))
        XCTAssertNil(
            WebhookConfigurationReference(
                rawValue: "workflow.webhook.v1:A0F99D93-7E4D-46CE-A188-8B713EF229DA:3"
            )
        )
        XCTAssertNil(
            WebhookConfigurationReference(
                rawValue: "workflow.webhook.v1:a0f99d93-7e4d-46ce-a188-8b713ef229da:03"
            )
        )

        let encoded = try JSONEncoder().encode(reference)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""workflow.webhook.v1:a0f99d93-7e4d-46ce-a188-8b713ef229da:3""#)
        XCTAssertEqual(try JSONDecoder().decode(WebhookConfigurationReference.self, from: encoded), reference)
    }

    func testProtectedPayloadPreservesPlaintextValuesExactly() throws {
        let rawURL = "  https://example.com/hook?token=a%2Bb  "
        let rawHeaders = "{\n  \"X-Exact\" : \"  keep spaces  \"\n}"
        let configuration = [
            ExternalOutputActionConfigurationKey.webhookURL: rawURL,
            ExternalOutputActionConfigurationKey.webhookHeadersJSON: rawHeaders,
            "unrelated": "keep outside Keychain",
        ]

        let protected = try XCTUnwrap(
            WebhookProtectedConfiguration.extractingPlaintext(from: configuration)
        )

        XCTAssertEqual(protected.schemaVersion, WebhookProtectedConfiguration.currentSchemaVersion)
        XCTAssertEqual(protected.values, [
            ExternalOutputActionConfigurationKey.webhookURL: rawURL,
            ExternalOutputActionConfigurationKey.webhookHeadersJSON: rawHeaders,
        ])
        let encoded = try JSONEncoder().encode(protected)
        XCTAssertEqual(
            try JSONDecoder().decode(WebhookProtectedConfiguration.self, from: encoded),
            protected
        )
    }

    func testProtectedPayloadRejectsInvalidShapeAndVersion() throws {
        XCTAssertThrowsError(try WebhookProtectedConfiguration(values: [:])) { error in
            XCTAssertEqual(error as? WebhookProtectedConfigurationError, .emptyPayload)
        }
        XCTAssertThrowsError(
            try WebhookProtectedConfiguration(values: ["unrelated": "value"])
        ) { error in
            XCTAssertEqual(
                error as? WebhookProtectedConfigurationError,
                .unsupportedKey
            )
        }
        XCTAssertThrowsError(
            try WebhookProtectedConfiguration(
                schemaVersion: 2,
                values: [ExternalOutputActionConfigurationKey.webhookURL: "https://example.com"]
            )
        ) { error in
            XCTAssertEqual(
                error as? WebhookProtectedConfigurationError,
                .unsupportedSchemaVersion(2)
            )
        }
    }
}
