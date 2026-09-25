import Foundation
import Observation
import RillCore

@MainActor
@Observable
public final class SpeechFeatureModel {
  public let voice = VoiceRunModel()
  public internal(set) var preferredSpeechEngine: PreferredSpeechEngine = .local
  public internal(set) var builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode = .pasteIntoApp
  public internal(set) var longRecordingModeEnabled: Bool = false
  public internal(set) var recordingDurationLimit: RecordingDurationLimit = .fiveMinutes
  public internal(set) var localSpeechModel: String = ""
  public internal(set) var localSpeechPrewarm: Bool = false
  public internal(set) var enabledSpeechModelIDs: Set<String> = []
  public internal(set) var residentSpeechModelIDs: Set<String> = []
  public internal(set) var residentSpeechBudgetConfirmation: String? = nil
  public internal(set) var measuredSpeechModelPeakByteCounts: [String: UInt64] = [:]
  public internal(set) var pendingResidentSpeechModelIDs: Set<String>? = nil
  public internal(set) var speechModelPoolDegradedByMemoryPressure: Bool = false
  public internal(set) var localSpeechPreparationState: LocalSpeechPreparationState = .idle
  public internal(set) var localSpeechPreparationProgress: Double = 0
  public internal(set) var localSpeechPreparationCompletedUnitCount: Int64 = 0
  public internal(set) var localSpeechPreparationTotalUnitCount: Int64 = 0
  public internal(set) var localSpeechPreparedModelIdentifier: String? = nil
  public internal(set) var downloadedLocalSpeechModels: [String] = []
  public internal(set) var downloadedLocalSpeechModelsAvailability:
    StoredSettingsDomainAvailability = .available
  public internal(set) var downloadedLocalSpeechModelsError: String? = nil
  public internal(set) var localSpeechPreparationError: String? = nil
  public internal(set) var localSpeechAvailability: LocalSpeechAvailability =
    .trustMaterialUnavailable
  public internal(set) var localSpeechTrustMaterialAvailable: Bool = false
  public internal(set) var trustedLocalSpeechModels: [LocalSpeechModelDescriptor] = []
  public internal(set) var defaultLocalSpeechModelIdentifier: String? = nil
  public internal(set) var localSpeechPhysicalMemoryGiB: Int = 0
  public internal(set) var wakeWordResourceState: VoiceAssistantResourceState = .notInstalled
  public internal(set) var wakeWordRuntimeState: WakeWordRuntimePresentationState = .disabled
  public internal(set) var ttsModelOptions: [TTSModelOption] = []
  public internal(set) var defaultTTSModelIdentifier: String = ""
  public internal(set) var ttsModelIdentifier: String = ""
  public internal(set) var downloadedTTSModelIdentifiers: Set<String> = []
  public internal(set) var ttsResourceState: VoiceAssistantResourceState = .notInstalled
  public internal(set) var isSpeechPlaybackActive: Bool = false
}
