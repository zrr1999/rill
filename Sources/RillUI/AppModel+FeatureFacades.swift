import Foundation
import RillCore

extension AppModel {
  public var preferredSpeechEngine: PreferredSpeechEngine {
    get { speech.preferredSpeechEngine }
    set {
      let oldValue = speech.preferredSpeechEngine
      speech.preferredSpeechEngine = newValue
      handlePreferredSpeechEngineChange(from: oldValue)
    }
  }

  public var builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode {
    get { speech.builtinPushToTalkOutputMode }
    set {
      let oldValue = speech.builtinPushToTalkOutputMode
      speech.builtinPushToTalkOutputMode = newValue
      handleBuiltinPushToTalkOutputModeChange(from: oldValue)
    }
  }

  public var longRecordingModeEnabled: Bool {
    get { speech.longRecordingModeEnabled }
    set {
      let oldValue = speech.longRecordingModeEnabled
      speech.longRecordingModeEnabled = newValue
      handleLongRecordingModeChange(from: oldValue)
    }
  }

  public var recordingDurationLimit: RecordingDurationLimit {
    get { speech.recordingDurationLimit }
    set {
      let oldValue = speech.recordingDurationLimit
      speech.recordingDurationLimit = newValue
      handleRecordingDurationLimitChange(from: oldValue)
    }
  }

  public var localSpeechModel: String {
    get { speech.localSpeechModel }
    set {
      let oldValue = speech.localSpeechModel
      speech.localSpeechModel = newValue
      handleLocalSpeechModelChange(from: oldValue)
    }
  }

  public var localSpeechPrewarm: Bool {
    get { speech.localSpeechPrewarm }
    set {
      let oldValue = speech.localSpeechPrewarm
      speech.localSpeechPrewarm = newValue
      handleLocalSpeechPrewarmChange(from: oldValue)
    }
  }

  public var enabledSpeechModelIDs: Set<String> {
    get { speech.enabledSpeechModelIDs }
    set {
      let oldValue = speech.enabledSpeechModelIDs
      speech.enabledSpeechModelIDs = newValue
      handleEnabledSpeechModelIDsChange(from: oldValue)
    }
  }

  public var residentSpeechModelIDs: Set<String> {
    get { speech.residentSpeechModelIDs }
    set {
      let oldValue = speech.residentSpeechModelIDs
      speech.residentSpeechModelIDs = newValue
      handleResidentSpeechModelIDsChange(from: oldValue)
    }
  }

  public var residentSpeechBudgetConfirmation: String? {
    get { speech.residentSpeechBudgetConfirmation }
    set {
      let oldValue = speech.residentSpeechBudgetConfirmation
      speech.residentSpeechBudgetConfirmation = newValue
      handleResidentSpeechBudgetConfirmationChange(from: oldValue)
    }
  }

  public internal(set) var measuredSpeechModelPeakByteCounts: [String: UInt64] {
    get { speech.measuredSpeechModelPeakByteCounts }
    set {
      speech.measuredSpeechModelPeakByteCounts = newValue
    }
  }

  public internal(set) var pendingResidentSpeechModelIDs: Set<String>? {
    get { speech.pendingResidentSpeechModelIDs }
    set {
      speech.pendingResidentSpeechModelIDs = newValue
    }
  }

  public internal(set) var speechModelPoolDegradedByMemoryPressure: Bool {
    get { speech.speechModelPoolDegradedByMemoryPressure }
    set {
      speech.speechModelPoolDegradedByMemoryPressure = newValue
    }
  }

  public internal(set) var localSpeechPreparationState: LocalSpeechPreparationState {
    get { speech.localSpeechPreparationState }
    set {
      speech.localSpeechPreparationState = newValue
    }
  }

  public internal(set) var localSpeechPreparationProgress: Double {
    get { speech.localSpeechPreparationProgress }
    set {
      speech.localSpeechPreparationProgress = newValue
    }
  }

  public internal(set) var localSpeechPreparationCompletedUnitCount: Int64 {
    get { speech.localSpeechPreparationCompletedUnitCount }
    set {
      speech.localSpeechPreparationCompletedUnitCount = newValue
    }
  }

  public internal(set) var localSpeechPreparationTotalUnitCount: Int64 {
    get { speech.localSpeechPreparationTotalUnitCount }
    set {
      speech.localSpeechPreparationTotalUnitCount = newValue
    }
  }

  public internal(set) var localSpeechPreparedModelIdentifier: String? {
    get { speech.localSpeechPreparedModelIdentifier }
    set {
      speech.localSpeechPreparedModelIdentifier = newValue
    }
  }

  public internal(set) var downloadedLocalSpeechModels: [String] {
    get { speech.downloadedLocalSpeechModels }
    set {
      speech.downloadedLocalSpeechModels = newValue
    }
  }

  public internal(set) var downloadedLocalSpeechModelsAvailability: StoredSettingsDomainAvailability
  {
    get { speech.downloadedLocalSpeechModelsAvailability }
    set {
      speech.downloadedLocalSpeechModelsAvailability = newValue
    }
  }

  public internal(set) var downloadedLocalSpeechModelsError: String? {
    get { speech.downloadedLocalSpeechModelsError }
    set {
      speech.downloadedLocalSpeechModelsError = newValue
    }
  }

  public var localSpeechPreparationError: String? {
    get { speech.localSpeechPreparationError }
    set {
      speech.localSpeechPreparationError = newValue
    }
  }

  public var localSpeechAvailability: LocalSpeechAvailability {
    speech.localSpeechAvailability
  }

  public var localSpeechTrustMaterialAvailable: Bool {
    speech.localSpeechTrustMaterialAvailable
  }

  public var trustedLocalSpeechModels: [LocalSpeechModelDescriptor] {
    speech.trustedLocalSpeechModels
  }

  public var defaultLocalSpeechModelIdentifier: String? {
    speech.defaultLocalSpeechModelIdentifier
  }

  public var localSpeechPhysicalMemoryGiB: Int {
    speech.localSpeechPhysicalMemoryGiB
  }

  public internal(set) var wakeWordResourceState: VoiceAssistantResourceState {
    get { speech.wakeWordResourceState }
    set {
      speech.wakeWordResourceState = newValue
    }
  }

  public internal(set) var wakeWordRuntimeState: WakeWordRuntimePresentationState {
    get { speech.wakeWordRuntimeState }
    set {
      speech.wakeWordRuntimeState = newValue
    }
  }

  public var ttsModelOptions: [TTSModelOption] {
    speech.ttsModelOptions
  }

  public var defaultTTSModelIdentifier: String {
    speech.defaultTTSModelIdentifier
  }

  public var ttsModelIdentifier: String {
    get { speech.ttsModelIdentifier }
    set {
      let oldValue = speech.ttsModelIdentifier
      speech.ttsModelIdentifier = newValue
      handleTTSModelIdentifierChange(from: oldValue)
    }
  }

  public internal(set) var downloadedTTSModelIdentifiers: Set<String> {
    get { speech.downloadedTTSModelIdentifiers }
    set {
      speech.downloadedTTSModelIdentifiers = newValue
    }
  }

  public internal(set) var ttsResourceState: VoiceAssistantResourceState {
    get { speech.ttsResourceState }
    set {
      speech.ttsResourceState = newValue
    }
  }

  public internal(set) var isSpeechPlaybackActive: Bool {
    get { speech.isSpeechPlaybackActive }
    set {
      speech.isSpeechPlaybackActive = newValue
    }
  }

  public var contextMemory: ContextMemoryModel? {
    get { knowledge.contextMemory }
    set {
      knowledge.contextMemory = newValue
    }
  }

  public var systemClipboardCaptureEnabled: Bool {
    get { systemClipboard.systemClipboardCaptureEnabled }
    set {
      let oldValue = systemClipboard.systemClipboardCaptureEnabled
      systemClipboard.systemClipboardCaptureEnabled = newValue
      handleClipboardCaptureEnabledChange(from: oldValue)
    }
  }

  public internal(set) var clipboardCapturePreferenceRevision: UInt64 {
    get { systemClipboard.clipboardCapturePreferenceRevision }
    set {
      systemClipboard.clipboardCapturePreferenceRevision = newValue
    }
  }

  public internal(set) var systemClipboardCaptureControlSnapshot:
    SystemClipboardCaptureControlSnapshot
  {
    get { systemClipboard.systemClipboardCaptureControlSnapshot }
    set {
      systemClipboard.systemClipboardCaptureControlSnapshot = newValue
    }
  }
}
