import Foundation
import XCTest
@testable import RillCore
@testable import RillProviders

final class ExternalOutputActionsTests: XCTestCase {
    func testWebhookPostActionBuildsJSONRequest() async throws {
        let client = WebhookHTTPClientSpy(statusCode: 202)
        let action = WebhookPostAction(client: client)
        let context = makeActionContext(
            actionID: ExternalOutputActionID.webhookPost,
            configuration: [
                ExternalOutputActionConfigurationKey.webhookURL: "https://example.com/hook",
                ExternalOutputActionConfigurationKey.webhookHeadersJSON: #"{"X-Project":"Rill"}"#,
            ]
        )

        let result = try await action.execute(text: "hello webhook", context: context)

        XCTAssertEqual(result, .externalOutput("Webhook"))
        let requests = await client.requestsSnapshot()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://example.com/hook")
        XCTAssertEqual(request.headers["X-Project"], "Rill")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(payload["text"] as? String, "hello webhook")
        XCTAssertEqual(payload.count, 1)
    }

    func testWebhookPostActionRejectsPublicHTTPAndAllowsLoopbackHTTP() async throws {
        let client = WebhookHTTPClientSpy(statusCode: 204)
        let action = WebhookPostAction(client: client)

        let publicHTTPResult = try await action.execute(
            text: "secret",
            context: makeActionContext(
                actionID: ExternalOutputActionID.webhookPost,
                configuration: [ExternalOutputActionConfigurationKey.webhookURL: "http://example.com/hook"]
            )
        )
        assertFailed(publicHTTPResult, contains: "HTTPS")
        let requestsAfterPublicHTTP = await client.requestsSnapshot()
        XCTAssertTrue(requestsAfterPublicHTTP.isEmpty)

        let loopbackResult = try await action.execute(
            text: "local",
            context: makeActionContext(
                actionID: ExternalOutputActionID.webhookPost,
                configuration: [ExternalOutputActionConfigurationKey.webhookURL: "http://127.0.0.1:8787/hook"]
            )
        )
        XCTAssertEqual(loopbackResult, .externalOutput("Webhook"))
        let requestsAfterLoopback = await client.requestsSnapshot()
        XCTAssertEqual(requestsAfterLoopback.count, 1)
    }

    func testWebhookPostActionAuthorizesPrivacyBeforeNetworkRequest() async throws {
        let client = WebhookHTTPClientSpy(statusCode: 204)
        let action = WebhookPostAction(
            client: client,
            privacyAuthorizationProvider: { _ in
                throw WebhookPrivacyTestError.blocked
            }
        )

        let result = try await action.execute(
            text: "must stay local",
            context: makeActionContext(
                actionID: ExternalOutputActionID.webhookPost,
                configuration: [ExternalOutputActionConfigurationKey.webhookURL: "https://example.com/hook"]
            )
        )

        assertFailed(result, contains: "blocked by privacy policy")
        let requests = await client.requestsSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testWebhookPostActionReportsMissingAndNonSuccessConfiguration() async throws {
        let action = WebhookPostAction(client: WebhookHTTPClientSpy(statusCode: 500))
        let missingURL = try await action.execute(
            text: "hello",
            context: makeActionContext(actionID: ExternalOutputActionID.webhookPost)
        )
        assertFailed(missingURL, contains: "Webhook URL is required")

        let serverFailure = try await action.execute(
            text: "hello",
            context: makeActionContext(
                actionID: ExternalOutputActionID.webhookPost,
                configuration: [ExternalOutputActionConfigurationKey.webhookURL: "https://example.com/hook"]
            )
        )
        assertFailed(serverFailure, contains: "HTTP 500")
    }

}

private actor WebhookHTTPClientSpy: WebhookHTTPClient {
    private let statusCode: Int
    private var requests: [WebhookHTTPRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func post(_ request: WebhookHTTPRequest) async throws -> WebhookHTTPResponse {
        requests.append(request)
        return WebhookHTTPResponse(statusCode: statusCode)
    }

    func requestsSnapshot() -> [WebhookHTTPRequest] {
        requests
    }
}

private enum WebhookPrivacyTestError: LocalizedError, Sendable {
    case blocked

    var errorDescription: String? { "Webhook blocked by privacy policy." }
}

private func makeActionContext(
    actionID: String,
    configuration: [String: String] = [:]
) -> ActionContext {
    let workflow = WorkflowDefinition(
        name: "External Output Test",
        pipeline: PipelineDeclaration(
            recognizerID: "test.recognizer",
            outputActions: [OutputActionReference(id: actionID, configuration: configuration)]
        ),
        ui: WorkflowUIConfig(symbolName: "square.and.arrow.up", accentColorName: "green")
    )
    return ActionContext(
        runID: UUID(),
        workflow: workflow,
        contextSnapshot: .empty,
        recognitionResult: RecognitionResult(rawText: "hello", bestText: "hello"),
        finalText: "hello",
        startedAt: Date(timeIntervalSince1970: 1),
        finishedAt: Date(timeIntervalSince1970: 2)
    )
}

private func assertFailed(
    _ result: ActionResult,
    contains expectedSubstring: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed(let reason) = result else {
        return XCTFail("Expected failed result, got \(result)", file: file, line: line)
    }
    XCTAssertTrue(
        reason.contains(expectedSubstring),
        "Expected failure reason to contain \(expectedSubstring), got \(reason)",
        file: file,
        line: line
    )
}
