import Foundation
import Observation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

@MainActor @Observable
public final class VoiceRunModel {
  public internal(set) var measuredSpeechModelPeakByteCounts: [String: UInt64] = [:]
  public internal(set) var pendingResidentSpeechModelIDs: Set<String>?
  public internal(set) var speechModelPoolDegradedByMemoryPressure = false
  var workflowAudioRunState: WorkflowAudioRunState = .idle
  public internal(set) var localSpeechPreparationState: LocalSpeechPreparationState = .idle
  public internal(set) var localSpeechPreparationProgress: Double = 0
  public internal(set) var localSpeechPreparationCompletedUnitCount: Int64 = 0
  public internal(set) var localSpeechPreparationTotalUnitCount: Int64 = 0
  public internal(set) var localSpeechPreparedModelIdentifier: String?
  public internal(set) var downloadedLocalSpeechModels: [String] = []
  public internal(set) var downloadedLocalSpeechModelsAvailability:
    StoredSettingsDomainAvailability = .available
  public internal(set) var downloadedLocalSpeechModelsError: String?
  public var localSpeechPreparationError: String?
  public internal(set) var wakeWordResourceState: VoiceAssistantResourceState = .notInstalled
  public internal(set) var wakeWordRuntimeState: WakeWordRuntimePresentationState = .disabled
  public internal(set) var downloadedTTSModelIdentifiers: Set<String> = []
  public internal(set) var ttsResourceState: VoiceAssistantResourceState = .notInstalled
  public internal(set) var isSpeechPlaybackActive = false
  public var pendingResolution: CandidateResolutionCase?
  public internal(set) var failedAudioRecoveryReceipts: [FailedAudioRecoveryReceipt] = []
  public internal(set) var failedAudioRecoveryEnabled = false
  public internal(set) var isUpdatingFailedAudioRecovery = false
  public internal(set) var retryingFailedAudioRecoveryIDs: Set<UUID> = []
  public internal(set) var failedAudioRecoveryUnavailableReasonsByRunID:
    [UUID: FailedAudioRecoveryError] = [:]
  public var failedAudioRecoveryError: String?
  var pendingInteractiveWorkflowTask: Task<Void, Never>?
  var interactiveWorkflowTaskGeneration = 0
  var workflowAudioActionTasks: [UUID: Task<Void, Never>] = [:]
  var localSpeechPreparationGeneration = 0
  let localSpeechPreparationTaskOwner = LocalSpeechPreparationTaskOwner()
  var residentSpeechModelSynchronizationTask: Task<Void, Never>?
  var residentSpeechModelSynchronizationTasks: [UUID: Task<Void, Never>] = [:]
  var enabledSpeechModelPreparationTasks: [String: Task<Void, Never>] = [:]
  var shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
  var failedAudioRecoveryRetryTasks: [UUID: Task<Void, Never>] = [:]
  var failedAudioRecoveryLoadTask: Task<Void, Never>?
  var failedAudioRecoveryLoadGeneration = 0

  public internal(set) var isRunning = false
  public internal(set) var lastCompletedText: String?
  var activeRunID: UUID?
  private(set) var runs: [UUID: RunSnapshot] = [:]

  private var stages: [UUID: WorkflowRunStage] = [:]

  public var activeStage: WorkflowRunStage? {
    switch workflowAudioRunState {
    case .preparing: return .preparing
    case .recording: return .capturingInput
    case .transcribing: return activeRunID.flatMap { stages[$0] } ?? .recognizing
    case .idle: return activeRunID.flatMap { stages[$0] }
    }
  }

  func updateStage(_ stage: WorkflowRunStage, from identity: WorkflowRunIdentity) {
    guard runs[identity.runID]?.lane == identity.lane else { return }
    stages[identity.runID] = stage
  }

  func begin(_ run: RunSnapshot) {
    runs[run.runID] = run
    stages[run.runID] = .preparing
    if run.lane == .primary || activeRunID == nil { activeRunID = run.runID }
    isRunning = true
  }

  func updateText(_ text: String, from identity: WorkflowRunIdentity) {
    guard activeRunID == identity.runID, runs[identity.runID]?.lane == identity.lane,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    lastCompletedText = text
  }

  func complete(_ summary: WorkflowRunSummary) {
    if summary.trigger.isVoiceCapture {
      updateText(summary.finalText, from: .init(runID: summary.runID, lane: summary.lane))
    }
    finish(summary.runID)
  }

  func finish(_ runID: UUID) {
    guard runs.removeValue(forKey: runID) != nil || activeRunID == runID else { return }
    stages.removeValue(forKey: runID)
    if activeRunID == runID || activeRunID == nil {
      activeRunID =
        runs.values.sorted {
          if $0.lane != $1.lane { return $0.lane == .primary }
          return $0.startedAt > $1.startedAt
        }.first?.runID
    }
    isRunning = !runs.isEmpty
  }

  func reset() {
    runs.removeAll()
    stages.removeAll()
    activeRunID = nil
    isRunning = false
  }
}

public enum LocalSpeechPreparationState: Sendable, Equatable {
  case idle
  case preparing
  case ready
}

enum WorkflowAudioRunState: Sendable, Equatable {
  case idle
  case preparing(workflowID: UUID)
  case recording(workflowID: UUID)
  case transcribing(workflowID: UUID)
}

public enum VoiceAssistantResourceState: Sendable, Equatable {
  case notInstalled
  case preparing(progress: Double?)
  case ready
  case failed(String)
  case unavailable(VoiceAssistantResourceUnavailableReason)

  public var isPreparing: Bool {
    if case .preparing = self { return true }
    return false
  }
}

public enum VoiceAssistantResourceUnavailableReason: Error, Sendable, Equatable {
  case distributionLicenseUnverified
}

public struct TTSModelOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let precision: String
  public let approximateDownloadByteCount: UInt64
  public let isDefault: Bool

  public init(
    id: String,
    precision: String,
    approximateDownloadByteCount: UInt64,
    isDefault: Bool
  ) {
    self.id = id
    self.precision = precision
    self.approximateDownloadByteCount = approximateDownloadByteCount
    self.isDefault = isDefault
  }
}

public enum WakeWordRuntimePresentationState: Sendable, Equatable {
  case disabled
  case modelMissing
  case starting
  case listening
  case suspended(String)
  case failed(String)
}

public struct WakeWordSettingsSnapshot: Sendable, Equatable {
  public let phrases: [String]
  public let isEnabled: Bool
  public let workflowName: String?

  public init(
    phrases: [String],
    isEnabled: Bool,
    workflowName: String?
  ) {
    self.phrases = phrases
    self.isEnabled = isEnabled
    self.workflowName = workflowName
  }
}

public enum WakeWordSettingsUpdateResult: Sendable, Equatable {
  case saved
  case failed(String)
}
