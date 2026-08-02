import Foundation

public enum LiveSubtitlePhase: String, Codable, Sendable, Equatable {
    case hidden
    case preparing
    case recording
    case listening
    case transcribing
    case finalizing
    case processing
    case failed
}

/// A run-scoped disclosure of whether the selected workflow can complete
/// without contacting a network service. The runtime freezes this value from
/// the same destination classifier used by the privacy gate.
public enum LiveSubtitleNetworkUsage: String, Codable, Sendable, Equatable {
    case offline
    case online
    case unknown
}

public struct LiveSubtitleSnapshot: Codable, Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowPresentation?
    public var phase: LiveSubtitlePhase
    public var confirmedText: String
    public var hypothesisText: String
    public var statusText: String?
    public var levelMeter: [Float]
    public var providerID: String?
    public var networkUsage: LiveSubtitleNetworkUsage?
    public var livePreviewPlacement: LivePreviewPlacement
    public var queuedRunCount: Int
    public var prefersCompactLayout: Bool
    public var recordingStartedAt: Date?
    public var maximumRecordingDurationSeconds: Double?
    public var recordingDurationIsUnlimited: Bool?
    public var canRemoveRecordingDurationLimit: Bool?
    public var updatedAt: Date

    public init(
        runID: UUID,
        workflow: WorkflowPresentation? = nil,
        phase: LiveSubtitlePhase,
        confirmedText: String = "",
        hypothesisText: String = "",
        statusText: String? = nil,
        levelMeter: [Float] = [],
        providerID: String? = nil,
        networkUsage: LiveSubtitleNetworkUsage? = nil,
        livePreviewPlacement: LivePreviewPlacement = .overlay,
        queuedRunCount: Int = 0,
        prefersCompactLayout: Bool = false,
        recordingStartedAt: Date? = nil,
        maximumRecordingDurationSeconds: Double? = nil,
        recordingDurationIsUnlimited: Bool? = nil,
        canRemoveRecordingDurationLimit: Bool? = nil,
        updatedAt: Date = Date()
    ) {
        self.runID = runID
        self.workflow = workflow
        self.phase = phase
        self.confirmedText = confirmedText
        self.hypothesisText = hypothesisText
        self.statusText = statusText
        self.levelMeter = levelMeter
        self.providerID = providerID
        self.networkUsage = networkUsage
        self.livePreviewPlacement = livePreviewPlacement
        self.queuedRunCount = queuedRunCount
        self.prefersCompactLayout = prefersCompactLayout
        self.recordingStartedAt = recordingStartedAt
        self.maximumRecordingDurationSeconds = maximumRecordingDurationSeconds
        self.recordingDurationIsUnlimited = recordingDurationIsUnlimited
        self.canRemoveRecordingDurationLimit = canRemoveRecordingDurationLimit
        self.updatedAt = updatedAt
    }
}

public extension LiveSubtitleSnapshot {
    var displayText: String {
        Self.joinedDisplayText([confirmedText, hypothesisText])
    }

    var isVisible: Bool {
        phase != .hidden
    }

    static func joinedDisplayText(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
