import Foundation
import RillCore

public struct RecordStoreAction: OutputAction {
    public let id = RecordActionID.store
    private let ingestion: any RecordIngestionSink

    public init(ingestion: any RecordIngestionSink) {
        self.ingestion = ingestion
    }

    public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try await ingestion.ingest(
            RecordCaptureEnvelope(
                draft: record,
                requestedCollectionIDs: context.workflow.targetRecordCollectionIDs
            )
        )
        return .storedRecord
    }
}

public struct WebhookPostAction: OutputAction {
    public let id = ExternalOutputActionID.webhookPost
    private let client: any WebhookHTTPClient
    private let privacyAuthorizationProvider: (@Sendable (ActionContext) async throws -> Void)?

    public init(
        privacyAuthorizationProvider: (@Sendable (ActionContext) async throws -> Void)? = nil
    ) {
        self.client = URLSessionWebhookHTTPClient(session: .shared)
        self.privacyAuthorizationProvider = privacyAuthorizationProvider
    }

    public static func live(
        privacyAuthorizationProvider: (@Sendable (ActionContext) async throws -> Void)? = nil
    ) -> WebhookPostAction {
        WebhookPostAction(
            client: URLSessionWebhookHTTPClient(session: .shared),
            privacyAuthorizationProvider: privacyAuthorizationProvider
        )
    }

    init(
        client: any WebhookHTTPClient,
        privacyAuthorizationProvider: (@Sendable (ActionContext) async throws -> Void)? = nil
    ) {
        self.client = client
        self.privacyAuthorizationProvider = privacyAuthorizationProvider
    }

    public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        do {
            guard case .webhook(let url, let headers) = try context.configuration(for: id) else {
                return .failed("Webhook configuration is invalid.")
            }
            try await privacyAuthorizationProvider?(context)
            let body = try Self.makeRequestBody(text: text)
            let response = try await client.post(
                WebhookHTTPRequest(url: url, headers: headers, body: body)
            )
            guard (200..<300).contains(response.statusCode) else {
                return .failed("Webhook returned HTTP \(response.statusCode).")
            }
            return .externalOutput("Webhook")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func makeRequestBody(text: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["text": text],
            options: [.sortedKeys]
        )
    }
}

struct WebhookHTTPRequest: Equatable, Sendable {
    var url: URL
    var headers: [String: String]
    var body: Data
}

struct WebhookHTTPResponse: Equatable, Sendable {
    var statusCode: Int
}

protocol WebhookHTTPClient: Sendable {
    func post(_ request: WebhookHTTPRequest) async throws -> WebhookHTTPResponse
}

struct URLSessionWebhookHTTPClient: WebhookHTTPClient, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func post(_ request: WebhookHTTPRequest) async throws -> WebhookHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (header, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }
        let (_, response) = try await session.data(for: urlRequest)
        return WebhookHTTPResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
