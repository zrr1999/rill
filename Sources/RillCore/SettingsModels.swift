import Foundation

public enum AppSettingKey: String, Codable, Sendable, Equatable {
  case interfaceLanguage = "ui.language"
  case selectedWorkflowID = "workflow.selected-id"
  case customWorkflows = "workflow.custom-library"
  case workflowLibrary = "workflow.library"
  case workflowEnabledStates = "workflow.enabled-states"
  case webhookConfigurationProtectionState = "security.webhook-configuration-protection-state"
  case preferredSpeechEngine = "provider.preferred-engine"
  case localSpeechModel = "provider.local-speech.model"
  case localSpeechDownloadedModels = "provider.local-speech.downloaded-models"
  case localSpeechPrewarm = "provider.local-speech.prewarm"
  case ttsModel = "provider.tts.model"
  // Read-only compatibility keys for settings written before the sherpa-onnx cutover.
  case legacyWhisperKitModel = "provider.whisperkit.model"
  case legacyWhisperKitDownloadedModels = "provider.whisperkit.downloaded-models"
  case legacyWhisperKitCustomModel = "provider.whisperkit.custom-model"
  case legacyWhisperKitModelRepo = "provider.whisperkit.model-repo"
  // Retained only as the lookup key for one-way migration from legacy SQLite storage.
  case legacyWhisperKitModelToken = "provider.whisperkit.model-token"
  case legacyWhisperKitModelFolder = "provider.whisperkit.model-folder"
  case legacyWhisperKitLanguage = "provider.whisperkit.language"
  case legacyWhisperKitDownloadIfNeeded = "provider.whisperkit.download-if-needed"
  case legacyWhisperKitPrewarm = "provider.whisperkit.prewarm"
  // Retired Deepgram keys are cleanup-only. They are not product settings and
  // remain typed solely so upgrades can delete values written by older builds.
  case retiredDeepgramAPIKey = "provider.deepgram.api-key"
  case retiredDeepgramBaseURL = "provider.deepgram.base-url"
  case retiredDeepgramModel = "provider.deepgram.model"
  case retiredDeepgramLanguage = "provider.deepgram.language"
  // Retained only as the lookup key for one-way migration from legacy SQLite storage.
  case openAIAPIKey = "provider.openai.api-key"
  case openAIBaseURL = "provider.openai.base-url"
  case openAIModel = "provider.openai.model"
  case vocabularyRules = "vocabulary.rules"
  case vocabularyLibrary = "vocabulary.library"
  case privacySensitiveAppRules = "privacy.sensitive-app-rules"
  case privacyCloudConfirmationRequired = "privacy.cloud-confirmation-required"
  case privacyCloudProcessingAuthorizations = "privacy.cloud-processing-authorizations"
  case privacyHistoryPreviewMode = "privacy.history-preview-mode"
  case privacySecureInputConservativeMode = "privacy.secure-input-conservative-mode"
  case clipboardHistoryRetentionPeriod = "clipboard.history-retention-period"
  case runHistoryRetentionPeriod = "history.run-retention-period"
  case localHistoryMaintenanceState = "history.local-maintenance-state"
  case failedAudioRecoveryEnabled = "audio.failed-recovery-enabled"
  case builtinPushToTalkOutputMode = "workflow.builtin-push-to-talk.output-mode"
  case longRecordingModeEnabled = "recording.long-mode-enabled"
  case recordingDurationLimit = "recording.duration-limit"
  case clipboardGlobalMode = "clipboard.global-mode"
  case clipboardAppModes = "clipboard.app-modes"
  case clipboardRoutePreferences = "clipboard.route-preferences"
  case clipboardPersistedState = "clipboard.persisted-state"
  case clipboardCaptureEnabled = "clipboard.capture-enabled"
  case clipboardMergeSimilarItems = "clipboard.merge-similar-items"
  case clipboardHistoryVisibility = "clipboard.history-visibility"
  case clipboardPanelHotkey = "clipboard.panel-hotkey"
}

public enum PreferredSpeechEngine: String, Codable, CaseIterable, Identifiable, Sendable, Equatable
{
  case local

  public var id: String { rawValue }
}

public enum RecordingDurationLimit: String, Codable, CaseIterable, Identifiable, Sendable,
  Equatable
{
  case twoMinutes = "2-minutes"
  case fiveMinutes = "5-minutes"
  case unlimited

  public var id: String { rawValue }

  public var durationSeconds: Double? {
    switch self {
    case .twoMinutes:
      2 * 60
    case .fiveMinutes:
      5 * 60
    case .unlimited:
      nil
    }
  }
}

/// Product-facing availability of the release-owned local speech capability.
///
/// Keep unavailable reasons distinct so a runtime compatibility boundary is
/// never presented as missing or damaged trust material.
public enum LocalSpeechAvailability: String, Sendable, Equatable {
  case available
  case architectureUnsupported = "architecture-unsupported"
  case trustMaterialUnavailable = "trust-material-unavailable"

  public var isAvailable: Bool {
    self == .available
  }
}

public enum LegacyWhisperModelOption: String, Codable, CaseIterable, Identifiable, Sendable,
  Equatable
{
  case automatic = ""
  case tiny = "openai_whisper-tiny"
  case distilLargeV3Compact = "distil-whisper_distil-large-v3_594MB"
  case largeV320240930Compact = "openai_whisper-large-v3-v20240930_626MB"
  case custom = "__custom__"

  public var id: String { rawValue }

  public var modelIdentifier: String? {
    switch self {
    case .automatic:
      return nil
    case .custom:
      return nil
    default:
      return rawValue
    }
  }

  public init(storedModelValue: String?) {
    let trimmed = storedModelValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch trimmed.lowercased() {
    case "":
      self = .automatic
    default:
      self = Self(rawValue: trimmed) ?? .custom
    }
  }
}

/// Release-owned presentation metadata for one exact trusted local model.
///
/// This value is not a trust anchor. Production composition creates it only
/// after the corresponding packaged manifest has passed validation; UI and
/// workflows use the resulting snapshot instead of inventing model IDs.
public enum LocalSpeechModelCategory: String, Codable, Sendable, Equatable {
  case performance
  case intelligent
  case multilingual
}

public enum LocalSpeechModelQuantization: String, Codable, Sendable, Equatable {
  case int8 = "INT8"
  case fp16 = "FP16"
}

public enum LocalSpeechEngine: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
  case sherpaOnnx = "sherpa-onnx"
  case mlxAudioSwift = "mlx-audio-swift"

  public var id: String { rawValue }
}

public struct LocalSpeechModelDescriptor: Identifiable, Equatable, Sendable {
  public let id: String
  public let engine: LocalSpeechEngine
  public let englishName: String
  public let simplifiedChineseName: String
  public let englishDetail: String
  public let simplifiedChineseDetail: String
  public let forcesAutomaticLanguageDetection: Bool
  public let category: LocalSpeechModelCategory
  public let parameterCountMillions: Int
  public let quantization: LocalSpeechModelQuantization
  public let minimumSystemMemoryGiB: Int
  public let recommendedSystemMemoryGiB: Int
  public let hardwareRecommendationPriority: Int

  public init(
    id: String,
    engine: LocalSpeechEngine = .sherpaOnnx,
    englishName: String,
    simplifiedChineseName: String,
    englishDetail: String = "",
    simplifiedChineseDetail: String = "",
    forcesAutomaticLanguageDetection: Bool = false,
    category: LocalSpeechModelCategory = .intelligent,
    parameterCountMillions: Int = 0,
    quantization: LocalSpeechModelQuantization = .int8,
    minimumSystemMemoryGiB: Int = 8,
    recommendedSystemMemoryGiB: Int = 16,
    hardwareRecommendationPriority: Int = 0
  ) {
    self.id = id
    self.engine = engine
    self.englishName = englishName
    self.simplifiedChineseName = simplifiedChineseName
    self.englishDetail = englishDetail
    self.simplifiedChineseDetail = simplifiedChineseDetail
    self.forcesAutomaticLanguageDetection = forcesAutomaticLanguageDetection
    self.category = category
    self.parameterCountMillions = parameterCountMillions
    self.quantization = quantization
    self.minimumSystemMemoryGiB = minimumSystemMemoryGiB
    self.recommendedSystemMemoryGiB = recommendedSystemMemoryGiB
    self.hardwareRecommendationPriority = hardwareRecommendationPriority
  }
}

public enum BuiltinPushToTalkOutputMode: String, Codable, CaseIterable, Identifiable, Sendable,
  Equatable
{
  case pasteIntoApp = "inject"
  case saveToVoiceGroup = "voice-group"

  public var id: String { rawValue }
}

public struct LocalSpeechSettings: Codable, Sendable, Equatable {
  public var model: String
  public var modelRepo: String
  public var modelToken: String
  public var modelFolder: String
  public var language: String
  public var downloadIfNeeded: Bool
  public var prewarm: Bool

  public init(
    model: String = "",
    modelRepo: String = "",
    modelToken: String = "",
    modelFolder: String = "",
    language: String = "",
    downloadIfNeeded: Bool = true,
    prewarm: Bool = false
  ) {
    self.model = model
    self.modelRepo = modelRepo
    self.modelToken = modelToken
    self.modelFolder = modelFolder
    self.language = language
    self.downloadIfNeeded = downloadIfNeeded
    self.prewarm = prewarm
  }
}

public enum OpenAIModelOption: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case luna = "gpt-5.6-luna"
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"

    public var id: String { rawValue }
}

public enum OpenAIVerificationFailure: String, Sendable, Equatable {
    case credentialUnavailable
    case configurationInvalid
    case authenticationFailed
    case rateLimited
    case timedOut
    case networkFailed
    case refused
    case incomplete
    case invalidResponse
    case unknown
}

public protocol OpenAIVerificationFailureProviding: Error {
    var openAIVerificationFailure: OpenAIVerificationFailure { get }
}

public struct OpenAISettings: Codable, Sendable, Equatable {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = OpenAIModelOption.luna.rawValue
    public static let maximumBaseURLLength = 2_048
    public static let maximumModelIdentifierLength = 256

    public var apiKey: String
    public var baseURL: String
    public var model: String

    public init(
        apiKey: String = "",
        baseURL: String = Self.defaultBaseURL,
        model: String = Self.defaultModel
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    public static func isValidBaseURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.unicodeScalars.count <= maximumBaseURLLength,
            let components = URLComponents(string: trimmed),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && isLoopbackHost(host)
    }

    public static func isValidModelIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.unicodeScalars.count <= maximumModelIdentifierLength
        else {
            return false
        }
        return !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.first == "127" else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }
}

public enum ExportKind: String, Codable, Sendable, Equatable {
  case history
  case diagnostics
  case supportBundle
}

public struct ExportMetadata: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var kind: ExportKind
  public var destinationPath: String
  public var itemCount: Int
  public var createdAt: Date
  public var metadata: [String: String]

  public init(
    id: UUID = UUID(),
    kind: ExportKind,
    destinationPath: String,
    itemCount: Int,
    createdAt: Date = Date(),
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.destinationPath = destinationPath
    self.itemCount = itemCount
    self.createdAt = createdAt
    self.metadata = metadata
  }
}
