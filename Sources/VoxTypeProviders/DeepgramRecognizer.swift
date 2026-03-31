import Foundation
import VoxTypeCore

public struct DeepgramRecognizer: SpeechRecognizer {
    public enum RecognizerError: Error, LocalizedError, Equatable {
        case missingCapturedAudio
        case fileBackedAudioRequired
        case missingAPIKey
        case invalidBaseURL
        case requestFailed(statusCode: Int, bodyPreview: String)

        public var errorDescription: String? {
            switch self {
            case .missingCapturedAudio:
                return "Deepgram recognition requires captured audio."
            case .fileBackedAudioRequired:
                return "Deepgram recognition currently requires a file-backed audio capture."
            case .missingAPIKey:
                return "Deepgram API key is missing. Set DEEPGRAM_API_KEY before using the cloud recognizer."
            case .invalidBaseURL:
                return "Deepgram base URL is invalid."
            case .requestFailed(let statusCode, let bodyPreview):
                return "Deepgram request failed with status \(statusCode): \(bodyPreview)"
            }
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var apiKey: String?
        public var baseURL: String
        public var model: String
        public var language: String?
        public var smartFormat: Bool

        public init(
            apiKey: String? = nil,
            baseURL: String = "https://api.deepgram.com",
            model: String = "nova-3",
            language: String? = nil,
            smartFormat: Bool = true
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.model = model
            self.language = language
            self.smartFormat = smartFormat
        }
    }

    public let id: String
    private let configuration: Configuration
    private let session: URLSession
    private let configurationProvider: (@Sendable () async -> Configuration?)?

    public init(
        id: String = "deepgram.prerecorded",
        configuration: Configuration = Configuration(),
        session: URLSession = .shared,
        configurationProvider: (@Sendable () async -> Configuration?)? = nil
    ) {
        self.id = id
        self.configuration = configuration
        self.session = session
        self.configurationProvider = configurationProvider
    }

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        let resolvedConfiguration = await configurationProvider?() ?? configuration
        guard let capturedAudio = request.capturedAudio else {
            throw RecognizerError.missingCapturedAudio
        }
        guard let audioFileURL = capturedAudio.fileURL else {
            throw RecognizerError.fileBackedAudioRequired
        }

        let startedAt = Date()
        let apiKey = resolvedConfiguration.apiKey ?? ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]
        guard let apiKey, !apiKey.isEmpty else {
            throw RecognizerError.missingAPIKey
        }

        guard let url = requestURL(for: request, configuration: resolvedConfiguration) else {
            throw RecognizerError.invalidBaseURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.contentType(for: audioFileURL), forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: urlRequest, fromFile: audioFileURL)
        guard let response = response as? HTTPURLResponse else {
            throw RecognizerError.requestFailed(statusCode: -1, bodyPreview: "Missing HTTP response")
        }
        guard (200..<300).contains(response.statusCode) else {
            let preview = String(decoding: data.prefix(300), as: UTF8.self)
            throw RecognizerError.requestFailed(statusCode: response.statusCode, bodyPreview: preview)
        }

        let decoded = try JSONDecoder().decode(DeepgramListenResponse.self, from: data)
        let alternative = decoded.results.channels.first?.alternatives.first
        let transcript = alternative?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let durationMillis = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let resolvedModel = resolvedConfiguration.model.nonEmpty
            ?? request.workflow.metadata["deepgram.model"]
            ?? Configuration().model

        return RecognitionResult(
            rawText: transcript,
            bestText: transcript,
            metadata: [
                "provider": id,
                "provider.kind": "deepgram",
                "provider.model": resolvedModel,
                "audio.file": audioFileURL.lastPathComponent,
            ],
            processingDurationMillis: durationMillis
        )
    }

    public static func startupDiagnostic(configuration: Configuration = Configuration()) -> DiagnosticEvent {
        let apiKey = configuration.apiKey ?? ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]
        if let apiKey, !apiKey.isEmpty {
            return DiagnosticEvent(
                subsystem: .providers,
                level: .info,
                event: "provider.deepgram.available",
                message: "Deepgram recognizer is configured and ready for prerecorded cloud transcription.",
                metadata: ["recognizerID": "deepgram.prerecorded"]
            )
        }

        return DiagnosticEvent(
            subsystem: .providers,
            level: .warning,
            event: "provider.deepgram.missing_key",
            message: "Deepgram recognizer is registered, but DEEPGRAM_API_KEY is not configured yet.",
            metadata: ["recognizerID": "deepgram.prerecorded"]
        )
    }

    private func requestURL(for request: RecognitionRequest, configuration: Configuration) -> URL? {
        guard let baseURL = URL(string: configuration.baseURL) else { return nil }
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("listen"),
            resolvingAgainstBaseURL: false
        )
        let resolvedModel = configuration.model.nonEmpty
            ?? request.workflow.metadata["deepgram.model"]
            ?? Configuration().model
        components?.queryItems = [
            URLQueryItem(name: "model", value: resolvedModel),
            URLQueryItem(name: "smart_format", value: configuration.smartFormat ? "true" : "false"),
        ]

        if let language = configuration.language?.nonEmpty ?? request.workflow.metadata["recognizer.language"]?.nonEmpty {
            components?.queryItems?.append(URLQueryItem(name: "language", value: language))
        }

        return components?.url
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
