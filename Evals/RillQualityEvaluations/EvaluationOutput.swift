import Foundation
import RillCore
import RillProviders
import Testing

enum EvaluationOutput {
  private struct Envelope<Body: Encodable>: Encodable {
    let model: String
    let providerFingerprint: String
    let observations: Body
  }

  static func save(_ value: some Encodable, settings: OpenAISettings) throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["RILL_EVAL_OUTPUT"],
      "Run quality evaluations through just eval-quality")
    let url = URL(fileURLWithPath: path)
    // The runner creates a fresh 0700 directory before any provider request.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(
      Envelope(
        model: settings.model,
        providerFingerprint: ContextProviderIdentity.fingerprint(settings),
        observations: value)
    ).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }
}
