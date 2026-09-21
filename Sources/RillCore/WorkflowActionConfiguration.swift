import Foundation

public struct SpeechActionConfiguration: Sendable, Equatable {
  public let provider: SpeechSynthesisProvider
  public let model: String?
  public let voice: String
  public let language: String?
}

public enum WorkflowActionConfiguration: Sendable, Equatable {
  case none
  case webhook(url: URL, headers: [String: String])
  case shortcut(name: String)
  case markdown(file: URL)
  case speech(SpeechActionConfiguration)
  case custom([String: String])

  public init(_ reference: OutputActionReference) throws {
    let values = reference.configuration
    func text(_ key: String) -> String {
      values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    switch reference.id {
    case RecordActionID.store, RecordActionID.systemClipboardCopy,
      RecordActionID.focusedApplicationInsert:
      self = .none
    case ExternalOutputActionID.webhookPost:
      let raw = text(ExternalOutputActionConfigurationKey.webhookURL)
      guard !raw.isEmpty else { throw WorkflowActionConfigurationError("Webhook URL is required.") }
      guard let url = URL(string: raw), SecureTransportPolicy.allowsSensitiveHTTPURL(url) else {
        throw WorkflowActionConfigurationError(
          "Webhook URL must use HTTPS; HTTP is allowed only for localhost.")
      }
      self = .webhook(
        url: url,
        headers: try Self.webhookHeaders(
          values[ExternalOutputActionConfigurationKey.webhookHeadersJSON] ?? ""))
    case ExternalOutputActionID.shortcutsRun:
      let name = text(ExternalOutputActionConfigurationKey.shortcutName)
      guard !name.isEmpty else {
        throw WorkflowActionConfigurationError("Shortcut name is required.")
      }
      self = .shortcut(name: name)
    case ExternalOutputActionID.markdownAppend:
      let path = text(ExternalOutputActionConfigurationKey.markdownAppendPath)
      guard !path.isEmpty else {
        throw WorkflowActionConfigurationError("Markdown append path is required.")
      }
      guard path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
        throw WorkflowActionConfigurationError("Markdown append path is invalid.")
      }
      let file = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
      guard ["md", "markdown"].contains(file.pathExtension.lowercased()) else {
        throw WorkflowActionConfigurationError("Markdown append path must end in .md or .markdown.")
      }
      self = .markdown(file: file)
    case SpeechOutputActionID.speak:
      let model = text(SpeechOutputActionConfigurationKey.model)
      self = .speech(
        .init(
          provider: values[SpeechOutputActionConfigurationKey.provider].flatMap(
            SpeechSynthesisProvider.init(rawValue:)) ?? .automatic,
          model: model.isEmpty ? nil : model,
          voice: values[SpeechOutputActionConfigurationKey.voice] ?? Qwen3TTSVoice.vivian.rawValue,
          language: values[SpeechOutputActionConfigurationKey.language]))
    default: self = .custom(values)
    }
  }

  public static func webhookHeaders(_ value: String) throws -> [String: String] {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
    guard
      let headers = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String]
    else {
      throw WorkflowActionConfigurationError(
        "Webhook headers must be a JSON object of string values.")
    }
    return headers
  }
}

public struct WorkflowActionConfigurationError: Error, LocalizedError, Sendable {
  private let message: String
  init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
