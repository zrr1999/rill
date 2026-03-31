import Foundation
import VoxTypeCore

#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

public struct WhisperKitRecognizer: SpeechRecognizer {
    public enum RecognizerError: Error, LocalizedError, Equatable {
        case missingCapturedAudio
        case fileBackedAudioRequired
        case integrationUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingCapturedAudio:
                return "WhisperKit recognition requires captured audio."
            case .fileBackedAudioRequired:
                return "WhisperKit currently requires a file-backed audio capture."
            case .integrationUnavailable:
                return "Local speech is not available in this build yet."
            }
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var model: String?
        public var modelRepo: String?
        public var modelToken: String?
        public var modelFolder: String?
        public var language: String?
        public var downloadIfNeeded: Bool
        public var prewarm: Bool?
        public var verbose: Bool

        public init(
            model: String? = nil,
            modelRepo: String? = nil,
            modelToken: String? = nil,
            modelFolder: String? = nil,
            language: String? = nil,
            downloadIfNeeded: Bool = true,
            prewarm: Bool? = nil,
            verbose: Bool = false
        ) {
            self.model = model
            self.modelRepo = modelRepo
            self.modelToken = modelToken
            self.modelFolder = modelFolder
            self.language = language
            self.downloadIfNeeded = downloadIfNeeded
            self.prewarm = prewarm
            self.verbose = verbose
        }
    }

    public let id: String
    private let defaultConfiguration: Configuration
    private let configurationProvider: (@Sendable () async -> Configuration)?
    #if canImport(WhisperKit)
    private let runtime: WhisperKitRuntime
    #endif

    public init(
        id: String = "whisperkit.local",
        configuration: Configuration = Configuration(),
        configurationProvider: (@Sendable () async -> Configuration)? = nil
    ) {
        self.id = id
        self.defaultConfiguration = configuration
        self.configurationProvider = configurationProvider
        #if canImport(WhisperKit)
        self.runtime = WhisperKitRuntime()
        #endif
    }

    public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        guard let capturedAudio = request.capturedAudio else {
            throw RecognizerError.missingCapturedAudio
        }
        guard let audioFileURL = capturedAudio.fileURL else {
            throw RecognizerError.fileBackedAudioRequired
        }

        let startedAt = Date()
        var configuration = await resolvedConfiguration()
        if let workflowModel = request.workflow.metadata["recognizer.whisperkit.model"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !workflowModel.isEmpty
        {
            configuration.model = workflowModel
        }
        let text = try await transcribeText(
            audioFileURL: audioFileURL,
            language: request.workflow.metadata["recognizer.language"] ?? configuration.language,
            preferVoiceActivityChunking: capturedAudio.durationSeconds > 30,
            configuration: configuration
        )
        let durationMillis = Int(Date().timeIntervalSince(startedAt) * 1_000)
        return RecognitionResult(
            rawText: text,
            bestText: text,
            metadata: [
                "provider": id,
                "provider.kind": "whisperkit",
                "audio.file": audioFileURL.lastPathComponent,
                "audio.durationSeconds": String(capturedAudio.durationSeconds),
            ],
            processingDurationMillis: durationMillis
        )
    }

    public static func startupDiagnostic() -> DiagnosticEvent {
        #if canImport(WhisperKit)
        return DiagnosticEvent(
            subsystem: .providers,
            level: .info,
            event: "provider.whisperkit.available",
            message: "WhisperKit is linked into this build and local transcription can be prepared from Settings.",
            metadata: ["recognizerID": "whisperkit.local"]
        )
        #else
            return DiagnosticEvent(
                subsystem: .providers,
                level: .warning,
                event: "provider.whisperkit.unavailable",
                message: "WhisperKit support is not included in this build yet.",
                metadata: ["recognizerID": "whisperkit.local"]
            )
        #endif
    }

    private func transcribeText(
        audioFileURL: URL,
        language: String?,
        preferVoiceActivityChunking: Bool,
        configuration: Configuration
    ) async throws -> String {
        #if canImport(WhisperKit)
        return try await runtime.transcribe(
            audioFileURL: audioFileURL,
            language: language,
            preferVoiceActivityChunking: preferVoiceActivityChunking,
            configuration: configuration
        )
        #else
        throw RecognizerError.integrationUnavailable
        #endif
    }

    public func prepareModel() async throws {
        let configuration = await resolvedConfiguration()
        _ = try await prepareModel(using: configuration, progressCallback: nil)
    }

    public func prepareModel(
        progressCallback: @escaping @Sendable (Progress) -> Void
    ) async throws -> String {
        let configuration = await resolvedConfiguration()
        return try await prepareModel(using: configuration, progressCallback: progressCallback)
    }

    public func prepareModel(using configuration: Configuration) async throws {
        _ = try await prepareModel(using: configuration, progressCallback: nil)
    }

    public func prepareModel(
        using configuration: Configuration,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        #if canImport(WhisperKit)
        return try await runtime.prepare(configuration: configuration, progressCallback: progressCallback)
        #else
        throw RecognizerError.integrationUnavailable
        #endif
    }

    private func resolvedConfiguration() async -> Configuration {
        if let configurationProvider {
            return await configurationProvider()
        }

        return defaultConfiguration
    }
}

#if canImport(WhisperKit)
private actor WhisperKitRuntime {
    private struct LoadedWhisperKit {
        let whisperKit: WhisperKit
        let modelIdentifier: String
    }

    private var whisperKit: WhisperKit?
    private var loadedConfiguration: WhisperKitRecognizer.Configuration?
    private var loadedModelIdentifier: String?

    func transcribe(
        audioFileURL: URL,
        language: String?,
        preferVoiceActivityChunking: Bool,
        configuration: WhisperKitRecognizer.Configuration
    ) async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let loadedWhisperKit = try await ensureWhisperKit(configuration: configuration)
        let results = try await loadedWhisperKit.whisperKit.transcribe(
            audioPath: audioFileURL.path,
            decodeOptions: DecodingOptions(
                verbose: configuration.verbose,
                language: language ?? configuration.language ?? environment["WHISPERKIT_LANGUAGE"],
                withoutTimestamps: true,
                chunkingStrategy: preferVoiceActivityChunking ? .vad : ChunkingStrategy.none
            )
        )

        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func prepare(
        configuration: WhisperKitRecognizer.Configuration,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        let loadedWhisperKit = try await ensureWhisperKit(
            configuration: configuration,
            progressCallback: progressCallback
        )
        return loadedWhisperKit.modelIdentifier
    }

    private func ensureWhisperKit(
        configuration: WhisperKitRecognizer.Configuration,
        progressCallback: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> LoadedWhisperKit {
        if
            let whisperKit,
            loadedConfiguration == configuration,
            let loadedModelIdentifier
        {
            return LoadedWhisperKit(whisperKit: whisperKit, modelIdentifier: loadedModelIdentifier)
        }

        let loadedWhisperKit = try await loadWhisperKit(
            configuration: configuration,
            progressCallback: progressCallback
        )
        self.whisperKit = loadedWhisperKit.whisperKit
        self.loadedConfiguration = configuration
        self.loadedModelIdentifier = loadedWhisperKit.modelIdentifier
        return loadedWhisperKit
    }

    private func loadWhisperKit(
        configuration: WhisperKitRecognizer.Configuration,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> LoadedWhisperKit {
        let environment = ProcessInfo.processInfo.environment
        let modelRepo = configuration.modelRepo ?? environment["WHISPERKIT_MODEL_REPO"] ?? "argmaxinc/whisperkit-coreml"
        let modelToken = configuration.modelToken ?? environment["WHISPERKIT_MODEL_TOKEN"]
        let explicitModelFolder = configuration.modelFolder ?? environment["WHISPERKIT_MODEL_FOLDER"]
        let resolvedModel = try await resolveModelIdentifier(
            configuration: configuration,
            modelRepo: modelRepo,
            modelToken: modelToken
        )
        let prewarm = configuration.prewarm ?? Self.boolEnvironment("WHISPERKIT_PREWARM")
        let shouldDownload = Self.boolEnvironment("WHISPERKIT_DOWNLOAD", defaultValue: configuration.downloadIfNeeded)

        let modelFolder: String?
        if let explicitModelFolder, !explicitModelFolder.isEmpty {
            modelFolder = explicitModelFolder
        } else if shouldDownload {
            let downloadedFolder = try await WhisperKit.download(
                variant: resolvedModel,
                from: modelRepo,
                token: modelToken,
                progressCallback: progressCallback
            )
            modelFolder = downloadedFolder.path
        } else {
            modelFolder = nil
        }

        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                model: resolvedModel,
                modelRepo: modelRepo,
                modelToken: modelToken,
                modelFolder: modelFolder,
                verbose: configuration.verbose,
                prewarm: prewarm,
                load: true,
                download: false
            )
        )
        if let progressCallback {
            progressCallback(Self.completedProgress())
        }
        return LoadedWhisperKit(whisperKit: whisperKit, modelIdentifier: resolvedModel)
    }

    private static func boolEnvironment(_ key: String, defaultValue: Bool? = nil) -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[key] else {
            return defaultValue ?? false
        }

        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue ?? false
        }
    }

    private func resolveModelIdentifier(
        configuration: WhisperKitRecognizer.Configuration,
        modelRepo: String,
        modelToken: String?
    ) async throws -> String {
        let configuredModel = configuration.model ?? ProcessInfo.processInfo.environment["WHISPERKIT_MODEL"]
        if let configuredModel, !configuredModel.isEmpty {
            return configuredModel
        }

        let modelSupportConfig = await WhisperKit.fetchModelSupportConfig(
            from: modelRepo,
            token: modelToken
        )
        return modelSupportConfig.modelSupport().default
    }

    private static func completedProgress() -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}
#endif
