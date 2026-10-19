import Foundation

public struct WorkflowOutputParameters: Codable, Sendable, Equatable {
  public var collections: [UUID]
  public var buffer: String?
  public var excludeFromCapture: Bool
  public var voice: String?
  public var language: String?
  public var shortcutName: String?
  public var markdownPath: String?
  public var webhookReference: String?
  public var webhookURL: String?
  public var webhookHeadersJSON: String?
  public init(
    collections: [UUID] = [], buffer: String? = nil, excludeFromCapture: Bool = true,
    voice: String? = nil, language: String? = nil, shortcutName: String? = nil, markdownPath: String? = nil,
    webhookReference: String? = nil, webhookURL: String? = nil, webhookHeadersJSON: String? = nil
  ) {
    self.collections = collections
    self.buffer = buffer
    self.excludeFromCapture = excludeFromCapture
    self.voice = voice
    self.language = language
    self.shortcutName = shortcutName
    self.markdownPath = markdownPath
    self.webhookReference = webhookReference
    self.webhookURL = webhookURL
    self.webhookHeadersJSON = webhookHeadersJSON
  }
}

public struct SpeechActionConfiguration: Sendable, Equatable {
  public let voice: String
  public let language: String?
}

public enum WorkflowActionConfiguration: Sendable, Equatable {
  case none
  case webhook(url: URL, headers: [String: String])
  case shortcut(name: String)
  case markdown(file: URL)
  case speech(SpeechActionConfiguration)
  case record(collections: [RecordCollectionID], buffer: Bool)

  public init(_ reference: OutputActionReference) throws {
    let values = reference.configuration
    switch reference.id {
    case RecordActionID.store:
      self = .record(collections: values.collections.map { RecordCollectionID($0) }, buffer: values.buffer == "speech")
    case RecordActionID.systemClipboardCopy,
      RecordActionID.focusedApplicationInsert:
      self = .none
    case ExternalOutputActionID.webhookPost:
      let raw = (values.webhookURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !raw.isEmpty else { throw WorkflowActionConfigurationError("Webhook URL is required.", isMissing: true) }
      guard let url = URL(string: raw), SecureTransportPolicy.allowsSensitiveHTTPURL(url) else {
        throw WorkflowActionConfigurationError(
          "Webhook URL must use HTTPS; HTTP is allowed only for localhost.")
      }
      self = .webhook(
        url: url,
        headers: try Self.webhookHeaders(
          values.webhookHeadersJSON ?? ""))
    case ExternalOutputActionID.shortcutsRun:
      let name = (values.shortcutName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw WorkflowActionConfigurationError("Shortcut name is required.", isMissing: true)
      }
      self = .shortcut(name: name)
    case ExternalOutputActionID.markdownAppend:
      let path = (values.markdownPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty else {
        throw WorkflowActionConfigurationError("Markdown append path is required.", isMissing: true)
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
      self = .speech(
        .init(
          voice: values.voice ?? Qwen3TTSVoice.vivian.rawValue,
          language: values.language))
    default: self = .none
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
  let isMissing: Bool
  init(_ message: String, isMissing: Bool = false) {
    self.message = message
    self.isMissing = isMissing
  }
  public var errorDescription: String? { message }
}

public enum WorkflowOutputConfigurationRequirement: Sendable {
  case none, webhook, shortcut, markdownFile

  public enum Stage: Sendable {
    case declaration, resolved
  }

  public func state(
    of configuration: WorkflowOutputParameters, stage: Stage
  ) -> WorkflowExplanationConfigurationState {
    let actionID: String
    switch self {
    case .none: return .notRequired
    case .webhook:
      if stage == .declaration,
        let reference = configuration.webhookReference?
          .trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty
      {
        return WebhookConfigurationReference(rawValue: reference) == nil ? .invalid : .configured
      }
      actionID = ExternalOutputActionID.webhookPost
    case .shortcut: actionID = ExternalOutputActionID.shortcutsRun
    case .markdownFile: actionID = ExternalOutputActionID.markdownAppend
    }
    do {
      _ = try WorkflowActionConfiguration(.init(id: actionID, configuration: configuration))
      return .configured
    } catch let error as WorkflowActionConfigurationError where error.isMissing {
      return .missing
    } catch {
      return .invalid
    }
  }
}
