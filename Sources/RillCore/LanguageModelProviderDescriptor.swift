import CryptoKit
import Foundation

public struct LanguageModelProviderDescriptor: Sendable, Equatable {
  public enum Family: Sendable, Equatable { case deepSeek, compatible }
  public let family: Family
  public let supportsReferenceImages: Bool
  public let authorizationFingerprint: String
  public let rewriteTimeout: TimeInterval
  public let disablesThinkingForRewrite: Bool

  public init(settings: OpenAISettings) {
    let endpoint = URLComponents(
      string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    let knownHost = endpoint?.host?.lowercased() == "api.deepseek.com"
    let knownModel =
      settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
      == LLMTextProcessing.deepSeekModel
    family = knownHost || knownModel ? .deepSeek : .compatible
    // Image authorization is a narrower allowlist than text-protocol compatibility.
    supportsReferenceImages =
      endpoint?.scheme == "https" && knownHost && settings.model == LLMTextProcessing.deepSeekModel
    let fields = [settings.baseURL, settings.model, settings.apiKey]
    authorizationFingerprint = SHA256.hash(
      data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
    rewriteTimeout = family == .deepSeek ? LLMTextProcessing.rewriteTimeout : 60
    disablesThinkingForRewrite = family == .deepSeek
  }
}
