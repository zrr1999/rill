import Foundation
import RillCore

public struct DeepgramRecognizer: SpeechRecognizer {
    static let liveProviderID = "deepgram.live"
    static let liveBestTextMetadataKey = "deepgram.live.best-text"
    static let liveRawTextMetadataKey = "deepgram.live.raw-text"
    static let liveRequestIDMetadataKey = "deepgram.live.request-id"
    static let liveModelMetadataKey = "deepgram.live.model"

    public enum RecognizerError: Error, LocalizedError, Equatable {
        case missingCapturedAudio
        case fileBackedAudioRequired
        case missingAPIKey
        case invalidBaseURL
        case transportFailed
        case requestFailed(statusCode: Int)

        public var errorDescription: String? {
            switch self {
            case .missingCapturedAudio:
                return "Deepgram recognition requires captured audio."
            case .fileBackedAudioRequired:
                return "Deepgram recognition currently requires a file-backed audio capture."
            case .missingAPIKey:
                return "Deepgram API key is missing. Set DEEPGRAM_API_KEY before using the cloud recognizer."
            case .invalidBaseURL:
                return "Deepgram base URL must use HTTPS; HTTP is allowed only for localhost."
            case .transportFailed:
                return "Deepgram request could not be completed."
            case .requestFailed(let statusCode):
                return "Deepgram request failed with status \(statusCode)."
            }
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var apiKey: String?
        public var baseURL: String
        public var model: String
        public var language: String?
        public var smartFormat: Bool
        public var endpointingMillis: Int?
        public var utteranceEndMillis: Int?
        public var vadEvents: Bool

        public init(
            apiKey: String? = nil,
            baseURL: String = "https://api.deepgram.com",
            model: String = "nova-3",
            language: String? = nil,
            smartFormat: Bool = true,
            endpointingMillis: Int? = 250,
            utteranceEndMillis: Int? = 1_000,
            vadEvents: Bool = true
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.model = model
            self.language = language
            self.smartFormat = smartFormat
            self.endpointingMillis = endpointingMillis
            self.utteranceEndMillis = utteranceEndMillis
            self.vadEvents = vadEvents
        }
    }

    public let id: String
    public let capabilities = SpeechRecognizerCapabilities(supportedHintKinds: [.keyterm])
    private let configuration: Configuration
    private let session: URLSession
    private let configurationProvider: (@Sendable () async -> Configuration?)?
    private let hintDiagnosticReporter: DeepgramHintDiagnosticReporter

    public init(
        id: String = "deepgram.prerecorded",
        configuration: Configuration = Configuration(),
        session: URLSession = .shared,
        configurationProvider: (@Sendable () async -> Configuration?)? = nil,
        hintDiagnosticReporter: @escaping DeepgramHintDiagnosticReporter = { _ in }
    ) {
        self.id = id
        self.configuration = configuration
        self.session = session
        self.configurationProvider = configurationProvider
        self.hintDiagnosticReporter = hintDiagnosticReporter
    }

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        try Task.checkCancellation()
        let resolvedConfiguration = await configurationProvider?() ?? configuration
        guard let capturedAudio = request.capturedAudio else {
            throw RecognizerError.missingCapturedAudio
        }
        if let liveRecognition = Self.liveRecognitionResult(
            from: capturedAudio,
            request: request,
            fallbackModel: resolvedConfiguration.model
        ) {
            return liveRecognition
        }
        guard let audioFileURL = capturedAudio.fileURL else {
            throw RecognizerError.fileBackedAudioRequired
        }

        let startedAt = Date()
        let validatedConfiguration = try DeepgramConfigurationValidator.validate(resolvedConfiguration)

        let plan = DeepgramRequestPlanner.plan(
            options: request.options,
            workflow: request.workflow,
            configuration: resolvedConfiguration,
            source: .prerecorded
        )
        guard let url = requestURL(
            for: plan,
            configuration: resolvedConfiguration,
            baseURL: validatedConfiguration.baseURL
        ) else {
            throw RecognizerError.invalidBaseURL
        }
        await hintDiagnosticReporter(plan.hintDiagnosticReport)
        try Task.checkCancellation()

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Token \(validatedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.contentType(for: audioFileURL), forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, fromFile: audioFileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RecognizerError.transportFailed
        }
        guard let response = response as? HTTPURLResponse else {
            throw RecognizerError.requestFailed(statusCode: -1)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RecognizerError.requestFailed(statusCode: response.statusCode)
        }

        let decoded = try JSONDecoder().decode(DeepgramListenResponse.self, from: data)
        let alternative = decoded.results.channels.first?.alternatives.first
        let transcript = alternative?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let durationMillis = Int(Date().timeIntervalSince(startedAt) * 1_000)

        return RecognitionResult(
            rawText: transcript,
            bestText: transcript,
            metadata: [
                "provider": id,
                "provider.kind": "deepgram",
                "provider.model": plan.model,
                "audio.file": audioFileURL.lastPathComponent,
            ],
            processingDurationMillis: durationMillis
        )
    }

    public static func startupDiagnostic(configuration: Configuration = Configuration()) -> DiagnosticEvent {
        do {
            _ = try DeepgramConfigurationValidator.validate(configuration)
            return DiagnosticEvent(
                subsystem: .providers,
                level: .info,
                event: "provider.deepgram.configured_unverified",
                message: "Deepgram credentials are configured but have not been verified by a speech check in this app session.",
                metadata: ["recognizerID": "deepgram.prerecorded"]
            )
        } catch RecognizerError.invalidBaseURL {
            return DiagnosticEvent(
                subsystem: .providers,
                level: .warning,
                event: "provider.deepgram.configuration_invalid",
                message: "Deepgram configuration is unavailable because its endpoint is not allowed.",
                metadata: ["recognizerID": "deepgram.prerecorded"]
            )
        } catch {
            return DiagnosticEvent(
                subsystem: .providers,
                level: .warning,
                event: "provider.deepgram.credential_unavailable",
                message: "No usable Deepgram API key was loaded. Add one in Settings or check Keychain access.",
                metadata: ["recognizerID": "deepgram.prerecorded"]
            )
        }
    }

    private func requestURL(
        for plan: DeepgramRequestPlan,
        configuration: Configuration,
        baseURL: URL
    ) -> URL? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("listen"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "model", value: plan.model),
            URLQueryItem(name: "smart_format", value: configuration.smartFormat ? "true" : "false"),
        ]

        if let language = plan.language {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        DeepgramRequestPlanner.appendKeyterms(from: plan, to: &queryItems)
        components?.queryItems = queryItems

        return components?.url
    }

    private static func liveRecognitionResult(
        from capturedAudio: CapturedAudio,
        request: RecognitionRequest,
        fallbackModel: String
    ) -> RecognitionResult? {
        guard let bestText = capturedAudio.metadata[liveBestTextMetadataKey]?.nonEmpty else {
            return nil
        }

        let rawText = capturedAudio.metadata[liveRawTextMetadataKey]?.nonEmpty ?? bestText
        let model = capturedAudio.metadata[liveModelMetadataKey]?.nonEmpty
            ?? request.workflow.metadata[WorkflowMetadataKey.deepgramModelOverride]?.nonEmpty
            ?? fallbackModel.nonEmpty
            ?? Configuration().model

        var metadata = capturedAudio.metadata
        metadata["provider"] = liveProviderID
        metadata["provider.kind"] = "deepgram.live"
        metadata["provider.model"] = model
        if let requestID = capturedAudio.metadata[liveRequestIDMetadataKey]?.nonEmpty {
            metadata["provider.request_id"] = requestID
        }

        return RecognitionResult(
            rawText: rawText,
            bestText: bestText,
            metadata: metadata
        )
    }

    private static func contentType(for audioFileURL: URL) -> String {
        switch audioFileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/m4a"
        case "flac":
            return "audio/flac"
        case "caf":
            return "audio/x-caf"
        default:
            return "application/octet-stream"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct DeepgramListenResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                let transcript: String
            }

            let alternatives: [Alternative]
        }

        let channels: [Channel]
    }

    let results: Results
}
