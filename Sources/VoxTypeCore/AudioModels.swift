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

public struct AudioCaptureRequest: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var triggerEvent: WorkflowTriggerEvent?
    public var preferredFormat: AudioFormat?
    public var maxDurationSeconds: Double?
    public var metadata: [String: String]

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        triggerEvent: WorkflowTriggerEvent? = nil,
        preferredFormat: AudioFormat? = nil,
        maxDurationSeconds: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runID = runID
        self.workflow = workflow
        self.triggerEvent = triggerEvent
        self.preferredFormat = preferredFormat
        self.maxDurationSeconds = maxDurationSeconds
        self.metadata = metadata
    }
}

public struct CapturedAudio: Codable, Sendable, Equatable {
    public enum ValidationError: Error, LocalizedError, Equatable {
        case missingPayload

        public var errorDescription: String? {
            switch self {
            case .missingPayload:
                return "Captured audio must include either a file URL or inline audio data."
            }
        }
    }

    public var durationSeconds: Double
    public var format: AudioFormat
    public var fileURL: URL?
    public var inlineData: Data?
    public var metadata: [String: String]

    public init(
        durationSeconds: Double,
        format: AudioFormat,
        fileURL: URL? = nil,
        inlineData: Data? = nil,
        metadata: [String: String] = [:]
    ) throws {
        guard fileURL != nil || inlineData != nil else {
            throw ValidationError.missingPayload
        }
        self.durationSeconds = durationSeconds
        self.format = format
        self.fileURL = fileURL
        self.inlineData = inlineData
        self.metadata = metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        let format = try container.decode(AudioFormat.self, forKey: .format)
        let fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        let inlineData = try container.decodeIfPresent(Data.self, forKey: .inlineData)
        let metadata = try container.decode([String: String].self, forKey: .metadata)

        try self.init(
            durationSeconds: durationSeconds,
            format: format,
            fileURL: fileURL,
            inlineData: inlineData,
            metadata: metadata
        )
    }
}
