import Foundation
import Observation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge

struct SettingsStringWrite: Sendable {
  let category: SettingsSaveCategory
  let encode: @Sendable () throws -> String
}

@MainActor @Observable
public final class SettingsPersistenceModel {
  public internal(set) var language: AppLanguage
  public internal(set) var systemClipboardCaptureEnabled: Bool = false
  public internal(set) var recordPanelHotkeyBinding: HotkeyBindingDescriptor = .doubleCommand
  public internal(set) var preferredSpeechEngine: PreferredSpeechEngine = .local
  public internal(set) var builtinPushToTalkOutputMode: BuiltinPushToTalkOutputMode = .pasteIntoApp
  public internal(set) var longRecordingModeEnabled: Bool = false
  public internal(set) var recordingDurationLimit: RecordingDurationLimit = .fiveMinutes
  public internal(set) var localSpeechModel: String = LocalSpeechSettings().model
  public internal(set) var localSpeechPrewarm: Bool = LocalSpeechSettings().prewarm
  public internal(set) var enabledSpeechModelIDs: Set<String> = []
  public internal(set) var residentSpeechModelIDs: Set<String> = []
  public internal(set) var residentSpeechBudgetConfirmation: String? = nil
  public internal(set) var openAIAPIKey: String = ""
  public internal(set) var openAIBaseURL: String = OpenAISettings().baseURL
  public internal(set) var openAIModel: String = OpenAISettings().model
  public internal(set) var ttsModelIdentifier: String = ""
  public internal(set) var recordHistoryVisibility: RecordHistoryVisibility = .remainingOnly

  public internal(set) var unavailableScalarSettingKeys: Set<AppSettingKey> = []
  public internal(set) var retryingUnavailableScalarSettingsDomains: Set<ScalarSettingsDomain> = []
  public internal(set) var openAICredentialAvailability: OpenAICredentialAvailability = .loading
  public internal(set) var openAIConfigurationVerificationState:
    OpenAIConfigurationVerificationState = .idle
  public internal(set) var openAIVerificationFailure: OpenAIVerificationFailure?
  public internal(set) var isRetryingUnavailableSettingsDomains = false
  var isRestoringSettings = false
  var settingsKeysModifiedDuringInitialLoad: Set<AppSettingKey> = []
  var settingsLoadGeneration = 0
  var unavailableSettingsDomainRetryGeneration = 0
  var scalarSettingsRetryGenerations: [ScalarSettingsDomain: Int] = [:]
  var localSpeechModelMutationGeneration = 0
  let settingsReadTaskOwner = AppModelSettingsReadTaskOwner()
  var openAICredentialLoadGeneration = 0
  var openAIVerificationGeneration = 0
  var openAIVerificationTask: Task<Void, Never>?

  public internal(set) var isLoading = true
  public private(set) var saveState: SettingsSaveState = .saved
  let writes = PersistenceWriteCoordinator()
  private let store: (any SettingsStore)?
  private var failed: [AppSettingKey: RetryableSettingsStoreWrite] = [:]
  private var retrying: Set<AppSettingKey> = []
  var hasUnsavedWrites: Bool { !failed.isEmpty }

  init(store: (any SettingsStore)?, language: AppLanguage) {
    self.store = store
    self.language = language
  }

  func submit(
    key: AppSettingKey, category: SettingsSaveCategory, debounce: Duration,
    operation: @escaping SettingsStoreWriteOperation, onFailure: @escaping @MainActor () -> Void
  ) {
    schedule(
      .init(category: category, operation: operation), key: key, debounce: debounce,
      onFailure: onFailure)
  }

  func retry(onFailure: @escaping @MainActor () -> Void) {
    guard !failed.isEmpty else { return }
    var strings: [AppSettingKey: SettingsStringWrite] = [:]
    for (key, write) in failed.sorted(by: { $0.key.rawValue < $1.key.rawValue })
    where !retrying.contains(key) {
      if case .string(let encode) = write.content {
        strings[key] = SettingsStringWrite(category: write.category, encode: encode)
      } else {
        schedule(write, key: key, debounce: .zero, onFailure: onFailure)
      }
    }
    submitAtomically(strings, onFailure: onFailure)
  }

  func submitAtomically(
    _ values: [AppSettingKey: SettingsStringWrite], onFailure: @escaping @MainActor () -> Void
  ) {
    guard !values.isEmpty else { return }
    let entries = values.mapValues(RetryableSettingsStoreWrite.init)
    guard let store else {
      failed.merge(entries) { _, latest in latest }
      refreshState()
      onFailure()
      return
    }
    for (key, entry) in entries where failed[key] != nil {
      failed[key] = entry
      retrying.insert(key)
    }
    refreshState()
    writes.replace(for: Set(values.keys)) {
      try await store.setStringsAtomically(try values.mapValues { try $0.encode() })
    } completion: { [weak self] result, currentKeys in
      guard let self else { return }
      retrying.subtract(currentKeys)
      switch result {
      case .success:
        for key in currentKeys { failed.removeValue(forKey: key) }
      case .failure(is CancellationError): break
      case .failure:
        for key in currentKeys { failed[key] = entries[key] }
        onFailure()
      }
      refreshState()
    }
  }

  private func schedule(
    _ write: RetryableSettingsStoreWrite, key: AppSettingKey, debounce: Duration,
    onFailure: @escaping @MainActor () -> Void
  ) {
    guard let store else {
      failed[key] = write
      refreshState()
      onFailure()
      return
    }
    if failed[key] != nil {
      failed[key] = write
      retrying.insert(key)
      refreshState()
    }
    writes.replace(for: key, debounce: debounce) {
      try await write.perform(in: store, for: key)
    } completion: { [weak self] result in
      guard let self else { return }
      retrying.remove(key)
      switch result {
      case .success: failed.removeValue(forKey: key)
      case .failure(is CancellationError): break
      case .failure:
        failed[key] = write
        onFailure()
      }
      refreshState()
    }
  }

  private func refreshState() {
    guard !failed.isEmpty else {
      retrying.removeAll()
      saveState = .saved
      return
    }
    let summary = UnsavedSettingsSummary(
      affectedChangeCount: failed.count,
      categories: Set(failed.values.map(\.category)).sorted { $0.rawValue < $1.rawValue })
    saveState = retrying.isEmpty ? .unsaved(summary) : .retrying(summary)
  }
}

public enum OpenAICredentialAvailability: Sendable, Equatable {
  case loading
  case missing
  case saving
  case available
  case inaccessible
}

public enum OpenAIConfigurationVerificationState: Sendable, Equatable {
  case idle
  case verifying
  case verified
  case failed
}
