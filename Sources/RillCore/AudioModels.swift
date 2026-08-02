import Foundation

public enum AudioEncoding: String, Codable, Sendable, Equatable {
    case pcm16
    case float32
    case aac
    case opus
}

public struct AudioFormat: Codable, Sendable, Equatable {
    public var sampleRateHz: Double
    public var channelCount: Int
    public var encoding: AudioEncoding

    public init(sampleRateHz: Double, channelCount: Int, encoding: AudioEncoding) {
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.encoding = encoding
    }
}

/// Declares who is responsible for the lifetime of a file-backed audio payload.
public enum CapturedAudioFileOwnership: String, Codable, Sendable, Equatable {
    /// The file is owned by the caller and must never be removed by Rill's processing pipeline.
    case callerManaged

    /// The file is a Rill-created temporary artifact transferred to the processing pipeline.
    case managedTemporary
}

/// Names isolated recognition payloads so startup cleanup can distinguish a
/// previous process's crash residue from work owned by the current process.
public enum RecognitionTemporaryAudioNamespace {
    public static let filenamePrefix = "rill-recognition-"
    public static let currentProcessFilenamePrefix =
        filenamePrefix + UUID().uuidString.lowercased() + "-"
}

public struct AudioCaptureRequest: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var triggerEvent: WorkflowTriggerEvent?
    public var preferredFormat: AudioFormat?
    public var maxDurationSeconds: Double?
    /// Whether the finite product-owned duration limit may be removed while
    /// this capture is active. Provider hard limits are never removable.
    public var canRemoveMaxDurationLimit: Bool
    public var metadata: [String: String]
    public var options: SpeechRecognitionRequestOptions
    /// Run-scoped policy and terminal coordination between the capture
    /// mechanism and its workflow owner. It carries no audio or transcript.
    public var endpointControl: AudioCaptureEndpointControl?
    /// Run-scoped authorization for any live audio transmission.
    ///
    /// Optional for source compatibility. Cloud live providers must reject a
    /// request that does not carry a matching active lifetime.
    public var audioLifetime: AudioCaptureLifetime?
    /// Frozen disclosure for the live recording surface. This is derived from
    /// the complete workflow rather than inferred from the speech provider.
    public var liveSubtitleNetworkUsage: LiveSubtitleNetworkUsage?

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        triggerEvent: WorkflowTriggerEvent? = nil,
        preferredFormat: AudioFormat? = nil,
        maxDurationSeconds: Double? = nil,
        canRemoveMaxDurationLimit: Bool = false,
        options: SpeechRecognitionRequestOptions = .empty,
        metadata: [String: String] = [:],
        endpointControl: AudioCaptureEndpointControl? = nil,
        audioLifetime: AudioCaptureLifetime? = nil,
        liveSubtitleNetworkUsage: LiveSubtitleNetworkUsage? = nil
    ) {
        self.runID = runID
        self.workflow = workflow
        self.triggerEvent = triggerEvent
        self.preferredFormat = preferredFormat
        self.maxDurationSeconds = maxDurationSeconds
        self.canRemoveMaxDurationLimit = canRemoveMaxDurationLimit
        self.metadata = metadata
        self.options = options
        self.endpointControl = endpointControl
        self.audioLifetime = audioLifetime
        self.liveSubtitleNetworkUsage = liveSubtitleNetworkUsage
    }
}

public struct CapturedAudio: Codable, Sendable, Equatable {
    public enum ValidationError: Error, LocalizedError, Equatable {
        case missingPayload
        case invalidManagedTemporaryFileURL

        public var errorDescription: String? {
            switch self {
            case .missingPayload:
                return "Captured audio must include either a file URL or inline audio data."
            case .invalidManagedTemporaryFileURL:
                return "Managed temporary audio must use a Rill-owned file in the system temporary directory."
            }
        }
    }

    public var durationSeconds: Double
    public var format: AudioFormat
    public var fileURL: URL?
    public var inlineData: Data?
    public var fileOwnership: CapturedAudioFileOwnership
    public var metadata: [String: String]

    public init(
        durationSeconds: Double,
        format: AudioFormat,
        fileURL: URL? = nil,
        inlineData: Data? = nil,
        fileOwnership: CapturedAudioFileOwnership = .callerManaged,
        metadata: [String: String] = [:]
    ) throws {
        guard fileURL != nil || inlineData != nil else {
            throw ValidationError.missingPayload
        }
        if fileOwnership == .managedTemporary {
            guard let fileURL, Self.isManagedTemporaryFileURL(fileURL) else {
                throw ValidationError.invalidManagedTemporaryFileURL
            }
        }
        self.durationSeconds = durationSeconds
        self.format = format
        self.fileURL = fileURL
        self.inlineData = inlineData
        self.fileOwnership = fileOwnership
        self.metadata = metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        let format = try container.decode(AudioFormat.self, forKey: .format)
        let fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        let inlineData = try container.decodeIfPresent(Data.self, forKey: .inlineData)
        let fileOwnership = try container.decodeIfPresent(
            CapturedAudioFileOwnership.self,
            forKey: .fileOwnership
        ) ?? .callerManaged
        let metadata = try container.decode([String: String].self, forKey: .metadata)

        try self.init(
            durationSeconds: durationSeconds,
            format: format,
            fileURL: fileURL,
            inlineData: inlineData,
            fileOwnership: fileOwnership,
            metadata: metadata
        )
    }

    /// Removes a file only when its ownership was explicitly transferred to Rill.
    @discardableResult
    public func removeManagedTemporaryFile(
        using fileManager: FileManager = .default
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard
            fileOwnership == .managedTemporary,
            let fileURL,
            Self.isManagedTemporaryFileURL(fileURL, using: fileManager),
            fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return false
        }

        try fileManager.removeItem(at: fileURL)
        return true
    }

    public static func isManagedTemporaryFileURL(
        _ fileURL: URL,
        using fileManager: FileManager = .default
    ) -> Bool {
        guard fileURL.isFileURL else { return false }
        let standardizedURL = fileURL.standardizedFileURL
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        return standardizedURL.deletingLastPathComponent() == temporaryDirectory
            && standardizedURL.lastPathComponent.hasPrefix("rill-")
    }
}
