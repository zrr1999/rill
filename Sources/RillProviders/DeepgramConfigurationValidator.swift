import Foundation
import RillCore

/// The single trust-boundary check for every Deepgram request path.
public enum DeepgramConfigurationValidator {
    public struct ValidatedConfiguration: Sendable, Equatable {
        public let apiKey: String
        public let baseURL: URL

        fileprivate init(apiKey: String, baseURL: URL) {
            self.apiKey = apiKey
            self.baseURL = baseURL
        }
    }

    public static func validate(
        _ configuration: DeepgramRecognizer.Configuration,
        environmentAPIKey: String? = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]
    ) throws -> ValidatedConfiguration {
        let apiKey = (configuration.apiKey ?? environmentAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else {
            throw DeepgramRecognizer.RecognizerError.missingAPIKey
        }

        let baseURLString = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let baseURL = URL(string: baseURLString),
            SecureTransportPolicy.allowsSensitiveHTTPURL(baseURL)
        else {
            throw DeepgramRecognizer.RecognizerError.invalidBaseURL
        }

        return ValidatedConfiguration(apiKey: apiKey, baseURL: baseURL)
    }
}
