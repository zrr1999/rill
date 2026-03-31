import Foundation

public enum AppSettingKey: String, Codable, Sendable, Equatable {
    case interfaceLanguage = "ui.language"
    case selectedWorkflowID = "workflow.selected-id"
    case customWorkflows = "workflow.custom-library"
    case workflowEnabledStates = "workflow.enabled-states"
    case preferredSpeechEngine = "provider.preferred-engine"
    case whisperKitModel = "provider.whisperkit.model"
    case whisperKitDownloadedModels = "provider.whisperkit.downloaded-models"
    case whisperKitCustomModel = "provider.whisperkit.custom-model"
    case whisperKitModelRepo = "provider.whisperkit.model-repo"
    case whisperKitModelToken = "provider.whisperkit.model-token"
    case whisperKitModelFolder = "provider.whisperkit.model-folder"
    case whisperKitLanguage = "provider.whisperkit.language"
    case whisperKitDownloadIfNeeded = "provider.whisperkit.download-if-needed"
    case whisperKitPrewarm = "provider.whisperkit.prewarm"
    case deepgramAPIKey = "provider.deepgram.api-key"
    case deepgramBaseURL = "provider.deepgram.base-url"
    case deepgramModel = "provider.deepgram.model"
    case deepgramLanguage = "provider.deepgram.language"
    case clipboardGlobalMode = "clipboard.global-mode"
    case clipboardAppModes = "clipboard.app-modes"
    case clipboardRoutePreferences = "clipboard.route-preferences"
    case clipboardPersistedState = "clipboard.persisted-state"
    case clipboardMergeSimilarItems = "clipboard.merge-similar-items"
    case clipboardPanelHotkey = "clipboard.panel-hotkey"
}

public enum PreferredSpeechEngine: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case local
    case cloud

    public var id: String { rawValue }
}

public enum WhisperKitModelOption: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case automatic = ""
    case tiny = "openai_whisper-tiny"
    case tinyEnglish = "openai_whisper-tiny.en"
    case base = "openai_whisper-base"
    case baseEnglish = "openai_whisper-base.en"
    case small = "openai_whisper-small"
    case smallEnglish = "openai_whisper-small.en"
    case largeV2 = "openai_whisper-large-v2"
    case largeV2Compact = "openai_whisper-large-v2_949MB"
    case largeV2Turbo = "openai_whisper-large-v2_turbo"
    case largeV2TurboCompact = "openai_whisper-large-v2_turbo_955MB"
    case largeV3 = "openai_whisper-large-v3"
    case largeV3Compact = "openai_whisper-large-v3_947MB"
    case largeV3Turbo = "openai_whisper-large-v3_turbo"
    case largeV3TurboCompact = "openai_whisper-large-v3_turbo_954MB"
    case distilLargeV3 = "distil-whisper_distil-large-v3"
    case distilLargeV3Compact = "distil-whisper_distil-large-v3_594MB"
    case distilLargeV3Turbo = "distil-whisper_distil-large-v3_turbo"
    case distilLargeV3TurboCompact = "distil-whisper_distil-large-v3_turbo_600MB"
    case largeV3_20240930 = "openai_whisper-large-v3-v20240930"
    case largeV3_20240930Turbo = "openai_whisper-large-v3-v20240930_turbo"
    case largeV3_20240930Compact = "openai_whisper-large-v3-v20240930_626MB"
    case largeV3_20240930TurboCompact = "openai_whisper-large-v3-v20240930_turbo_632MB"
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

public struct WhisperKitSettings: Codable, Sendable, Equatable {
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

public struct DeepgramSettings: Codable, Sendable, Equatable {
    public var apiKey: String
    public var baseURL: String
    public var model: String
    public var language: String

    public init(
        apiKey: String = "",
        baseURL: String = "https://api.deepgram.com",
        model: String = "nova-3",
        language: String = "en-US"
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.language = language
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
