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
  case enabledSpeechModels = "provider.speech-model-pool.enabled"
  case residentSpeechModels = "provider.speech-model-pool.resident"
  case residentSpeechBudgetConfirmation = "provider.speech-model-pool.budget-confirmation"
  case speechModelMeasuredPeaks = "provider.speech-model-pool.measured-peaks"
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
  case recordRetentionPeriod = "record.history-retention-period"
  case legacyClipboardHistoryRetentionPeriod = "clipboard.history-retention-period"
  case runHistoryRetentionPeriod = "history.run-retention-period"
  case localHistoryMaintenanceState = "history.local-maintenance-state"
  case failedAudioRecoveryEnabled = "audio.failed-recovery-enabled"
  case benchmarkRecordingArchiveEnabled = "audio.benchmark-archive-enabled"
  case builtinPushToTalkOutputMode = "workflow.builtin-push-to-talk.output-mode"
  case longRecordingModeEnabled = "recording.long-mode-enabled"
  case recordingDurationLimit = "recording.duration-limit"
  case legacyClipboardGlobalMode = "clipboard.global-mode"
  case legacyClipboardAppModes = "clipboard.app-modes"
  case legacyClipboardRoutePreferences = "clipboard.route-preferences"
  case legacyClipboardPersistedState = "clipboard.persisted-state"
  case systemClipboardCaptureEnabled = "system-clipboard.capture-enabled"
  case legacyClipboardCaptureEnabled = "clipboard.capture-enabled"
  case recordMergeSimilar = "record.merge-similar-records"
  case legacyClipboardMergeSimilarItems = "clipboard.merge-similar-items"
  case recordHistoryVisibility = "record.history-visibility"
  case legacyClipboardHistoryVisibility = "clipboard.history-visibility"
  case recordPanelHotkey = "record.panel-hotkey"
  case legacyClipboardPanelHotkey = "clipboard.panel-hotkey"
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
  public let approximateDownloadByteCount: UInt64
  public let conservativeRuntimePeakByteCount: UInt64?

  public init(
    id: String,
    engine: LocalSpeechEngine = .mlxAudioSwift,
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
    hardwareRecommendationPriority: Int = 0,
    approximateDownloadByteCount: UInt64 = 0,
    conservativeRuntimePeakByteCount: UInt64? = nil
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
    self.approximateDownloadByteCount = approximateDownloadByteCount
    self.conservativeRuntimePeakByteCount = conservativeRuntimePeakByteCount
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
  public var enabledModelIDs: Set<String>
  public var residentModelIDs: Set<String>
  public var residentBudgetConfirmation: String?

  private enum CodingKeys: String, CodingKey {
    case model
    case modelRepo
    case modelToken
    case modelFolder
    case language
    case downloadIfNeeded
    case prewarm
    case enabledModelIDs
    case residentModelIDs
    case residentBudgetConfirmation
  }

  public init(
    model: String = "",
    modelRepo: String = "",
    modelToken: String = "",
    modelFolder: String = "",
    language: String = "",
    downloadIfNeeded: Bool = true,
    prewarm: Bool = false,
    enabledModelIDs: Set<String> = ["qwen3-asr-0.6b-mlx-8bit"],
    residentModelIDs: Set<String> = ["qwen3-asr-0.6b-mlx-8bit"],
    residentBudgetConfirmation: String? = nil
  ) {
    self.model = model
    self.modelRepo = modelRepo
    self.modelToken = modelToken
    self.modelFolder = modelFolder
    self.language = language
    self.downloadIfNeeded = downloadIfNeeded
    self.prewarm = prewarm
    self.enabledModelIDs = enabledModelIDs
    self.residentModelIDs = residentModelIDs.intersection(enabledModelIDs)
    self.residentBudgetConfirmation = residentBudgetConfirmation
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self()
    self.init(
      model: try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model,
      modelRepo: try container.decodeIfPresent(String.self, forKey: .modelRepo)
        ?? defaults.modelRepo,
      modelToken: try container.decodeIfPresent(String.self, forKey: .modelToken)
        ?? defaults.modelToken,
      modelFolder: try container.decodeIfPresent(String.self, forKey: .modelFolder)
        ?? defaults.modelFolder,
      language: try container.decodeIfPresent(String.self, forKey: .language)
        ?? defaults.language,
      downloadIfNeeded: try container.decodeIfPresent(Bool.self, forKey: .downloadIfNeeded)
        ?? defaults.downloadIfNeeded,
      prewarm: try container.decodeIfPresent(Bool.self, forKey: .prewarm)
        ?? defaults.prewarm,
      enabledModelIDs: try container.decodeIfPresent(Set<String>.self, forKey: .enabledModelIDs)
        ?? defaults.enabledModelIDs,
      residentModelIDs: try container.decodeIfPresent(Set<String>.self, forKey: .residentModelIDs)
        ?? defaults.residentModelIDs,
      residentBudgetConfirmation: try container.decodeIfPresent(
        String.self,
        forKey: .residentBudgetConfirmation
      )
    )
  }
}

public enum SpeechModelCapability: String, Codable, Sendable, Equatable {
  case speechToText = "stt"
  case textToSpeech = "tts"
}

public struct SpeechModelResourceDescriptor: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public let capability: SpeechModelCapability
  public let downloadByteCount: UInt64
  public let conservativeRuntimePeakByteCount: UInt64?
  public var measuredPeakByteCount: UInt64?

  public init(
    id: String,
    capability: SpeechModelCapability,
    downloadByteCount: UInt64,
    conservativeRuntimePeakByteCount: UInt64? = nil,
    measuredPeakByteCount: UInt64? = nil
  ) {
    self.id = id
    self.capability = capability
    self.downloadByteCount = downloadByteCount
    self.conservativeRuntimePeakByteCount = conservativeRuntimePeakByteCount
    self.measuredPeakByteCount = measuredPeakByteCount
  }

  public var estimatedPeakByteCount: UInt64 {
    if let measuredPeakByteCount { return measuredPeakByteCount }
    if let conservativeRuntimePeakByteCount { return conservativeRuntimePeakByteCount }
    let multiplied = downloadByteCount.multipliedReportingOverflow(by: 3)
    guard !multiplied.overflow else { return .max }
    return multiplied.partialValue / 2
  }
}

public struct SpeechModelResourceBudget: Sendable, Equatable {
  public static let warningFraction = 0.2

  public let models: [SpeechModelResourceDescriptor]
  public let physicalMemoryByteCount: UInt64

  public init(
    residentModelIDs: Set<String>,
    catalog: [SpeechModelResourceDescriptor],
    physicalMemoryByteCount: UInt64
  ) {
    let unique = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    models = residentModelIDs.compactMap { unique[$0] }.sorted { $0.id < $1.id }
    self.physicalMemoryByteCount = physicalMemoryByteCount
  }

  public var estimatedPeakByteCount: UInt64 {
    models.reduce(0) { total, model in
      let sum = total.addingReportingOverflow(model.estimatedPeakByteCount)
      return sum.overflow ? .max : sum.partialValue
    }
  }

  public var estimatedFraction: Double {
    guard physicalMemoryByteCount > 0 else { return 1 }
    return Double(estimatedPeakByteCount) / Double(physicalMemoryByteCount)
  }

  public var requiresConfirmation: Bool {
    estimatedFraction > Self.warningFraction
  }

  public var confirmationFingerprint: String {
    models.map { "\($0.id):\($0.estimatedPeakByteCount)" }.joined(separator: "|")
      + "@\(physicalMemoryByteCount)"
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
