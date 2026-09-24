import AppKit
import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge

enum AppCredentialPersistenceError: LocalizedError {
  case secureStoreUnavailable
  case settingsStoreUnavailable
  case verificationFailed

  var errorDescription: String? {
    switch self {
    case .secureStoreUnavailable:
      return "Secure credential storage is unavailable."
    case .settingsStoreUnavailable:
      return "Provider settings storage is unavailable."
    case .verificationFailed:
      return "The provider configuration could not be saved and verified."
    }
  }
}

public enum VocabularyCorrectionSaveOutcome: Sendable, Equatable {
  case created(ruleID: UUID)
  case reused(ruleID: UUID)
  case conflict(existingRuleID: UUID)
  case invalid
  case notReady
}

public enum SettingsSaveCategory: String, CaseIterable, Sendable, Equatable {
  case interface
  case systemClipboard
  case speech
  case input
  case vocabulary
  case workflows
}

public struct UnsavedSettingsSummary: Sendable, Equatable {
  public let affectedChangeCount: Int
  public let categories: [SettingsSaveCategory]

  public init(
    affectedChangeCount: Int,
    categories: [SettingsSaveCategory]
  ) {
    self.affectedChangeCount = affectedChangeCount
    self.categories = categories
  }
}

public enum SettingsSaveState: Sendable, Equatable {
  case saved
  case unsaved(UnsavedSettingsSummary)
  case retrying(UnsavedSettingsSummary)

  public var unsavedSummary: UnsavedSettingsSummary? {
    switch self {
    case .saved:
      nil
    case .unsaved(let summary), .retrying(let summary):
      summary
    }
  }

  public var isRetrying: Bool {
    if case .retrying = self { return true }
    return false
  }
}

public enum ScalarSettingsDomain: String, CaseIterable, Identifiable, Sendable, Hashable {
  case interface
  case systemClipboard
  case speechRoute
  case localSpeech
  case openAI
  case input

  public var id: String { rawValue }

  var settingKeys: Set<AppSettingKey> {
    switch self {
    case .interface:
      [.interfaceLanguage]
    case .systemClipboard:
      [
        .systemClipboardCaptureEnabled,
        .recordHistoryVisibility,
        .recordPanelHotkey,
      ]
    case .speechRoute:
      [.preferredSpeechEngine, .ttsModel]
    case .localSpeech:
      [
        .localSpeechModel,
        .localSpeechPrewarm,
        .enabledSpeechModels,
        .residentSpeechModels,
        .residentSpeechBudgetConfirmation,
        .speechModelMeasuredPeaks,
      ]
    case .openAI:
      [.openAIBaseURL, .openAIModel]
    case .input:
      [
        .builtinPushToTalkOutputMode,
        .longRecordingModeEnabled,
        .recordingDurationLimit,
      ]
    }
  }

  public func unavailableWarning(language: AppLanguage) -> String {
    switch language {
    case .english:
      "Some saved \(englishName) settings could not be read. These controls are locked to preserve the original stored values."
    case .simplifiedChinese:
      "部分已保存的\(simplifiedChineseName)设置无法读取。相关控件已锁定，以保留原始存储值。"
    }
  }

  private var englishName: String {
    switch self {
    case .interface: "interface"
    case .systemClipboard: "clipboard"
    case .speechRoute: "speech routing"
    case .localSpeech: "local speech"
    case .openAI: "LLM Provider"
    case .input: "input"
    }
  }

  private var simplifiedChineseName: String {
    switch self {
    case .interface: "界面"
    case .systemClipboard: "剪贴板"
    case .speechRoute: "语音路由"
    case .localSpeech: "本地语音"
    case .openAI: "LLM Provider"
    case .input: "输入"
    }
  }
}

enum ProviderSettingsPersistenceError: LocalizedError, Sendable, Equatable {
  case unavailableStoredSettings

  var errorDescription: String? {
    "Saved speech-provider settings are unavailable."
  }

  func message(language: AppLanguage) -> String {
    switch language {
    case .english:
      "Saved speech-provider settings are unavailable."
    case .simplifiedChinese:
      "已保存的语音服务设置不可用。"
    }
  }
}

typealias SettingsStoreWriteOperation =
  @Sendable (
    any SettingsStore
  ) async throws -> Void

struct RetryableSettingsStoreWrite: Sendable {
  let category: SettingsSaveCategory
  let operation: SettingsStoreWriteOperation
}

enum StoredSettingsLoadWarning: Sendable {
  case storedValuesUnavailable
  case customWorkflows
  case workflowEnabledStates
  case downloadedModelMetadata
  case vocabularyRules
  case openAICredential

  var presentation: LocalizedText {
    switch self {
    case .storedValuesUnavailable:
      LocalizedText(
        english:
          "One or more stored settings could not be read. Affected features remain unavailable or use safe defaults.",
        simplifiedChinese: "一个或多个已保存设置无法读取；受影响功能保持不可用或使用安全默认值。"
      )
    case .customWorkflows:
      LocalizedText(
        english: "Custom workflows could not be loaded and were ignored.",
        simplifiedChinese: "自定义工作流无法加载，已忽略。"
      )
    case .workflowEnabledStates:
      LocalizedText(
        english: "Workflow enabled states could not be loaded and were ignored.",
        simplifiedChinese: "工作流启用状态无法加载，已忽略。"
      )
    case .downloadedModelMetadata:
      LocalizedText(
        english: "Downloaded model metadata could not be loaded and was ignored.",
        simplifiedChinese: "已下载模型的元数据无法加载，已忽略。"
      )
    case .vocabularyRules:
      LocalizedText(
        english: "Vocabulary rules could not be loaded and were ignored.",
        simplifiedChinese: "词汇规则无法加载，已忽略。"
      )
    case .openAICredential:
      LocalizedText(
        english: "The LLM Provider credential could not be read from secure storage.",
        simplifiedChinese: "无法从安全存储读取 LLM Provider 凭据。"
      )
    }
  }
}

public enum StoredSettingsDomainAvailability: Sendable, Equatable {
  case available
  case unavailable
}

enum StoredSettingsDomain: Sendable, Hashable {
  case workflowLibrary
  case downloadedModelMetadata
  case vocabularyRules
}

struct StoredAppSettingsSnapshot: Sendable {
  let persistentSettingsStoreWasAvailable: Bool
  let unavailableSettingKeys: Set<AppSettingKey>
  let legacyLocalSpeechMigrationValues: [AppSettingKey: String]
  let language: String?
  let customWorkflows: [WorkflowDefinition]
  let workflowCustomizations: [WorkflowCustomization]
  let workflowLibraryNeedsMigration: Bool
  let workflowEnabledStates: [UUID: Bool]
  let systemClipboardCaptureEnabled: String?
  let recordHistoryVisibility: String?
  let recordPanelHotkey: String?
  let preferredSpeechEngine: String?
  let ttsModel: String?
  let localSpeechModel: String?
  let downloadedLocalSpeechModels: [String]
  let localSpeechPrewarm: String?
  let enabledSpeechModels: String?
  let residentSpeechModels: String?
  let residentSpeechBudgetConfirmation: String?
  let speechModelMeasuredPeaks: String?
  let openAIAPIKey: String?
  let openAICredentialAvailability: OpenAICredentialAvailability
  let openAIBaseURL: String?
  let openAIModel: String?
  let vocabularyRules: [VocabularyRule]
  let vocabularyCollections: [VocabularyCollection]
  let vocabularyBindings: [VocabularyCollectionBinding]
  let vocabularyLibraryNeedsMigration: Bool
  let privacyPolicySettings: PrivacyPolicySettings
  let privacySettingsWereInvalid: Bool
  let recordRetentionPeriod: String?
  let runHistoryRetentionPeriod: String?
  let failedAudioRecoveryEnabled: String?
  let benchmarkRecordingArchiveEnabled: String?
  let builtinPushToTalkOutputMode: String?
  let longRecordingModeEnabled: String?
  let recordingDurationLimit: String?
  let loadWarnings: [StoredSettingsLoadWarning]
  let unavailableDomains: Set<StoredSettingsDomain>
}

struct InitialWorkflowFileLoad: Sendable {
  let result: WorkflowFileLoadResult
  let didMigrateLegacyWorkflows: Bool
}

struct RecoverableStoredSettingsDomains: Sendable {
  let customWorkflows: [WorkflowDefinition]?
  let workflowFiles: WorkflowFileLoadResult?
  let workflowEnabledStates: [UUID: Bool]?
  let downloadedLocalSpeechModels: [String]?
  let vocabularyRules: [VocabularyRule]?
}

enum StoredSettingsCollectionValidationError: Error {
  case invalidIdentifier
  case duplicateIdentifier
}

enum WorkflowFileMigrationError: Error {
  case verificationFailed
}

struct LegacyLocalSpeechSettingResolution {
  let value: String?
  let usedLegacyValue: Bool
  let isUnavailable: Bool
}

extension AppModel {
  static let scalarSettingsKeys = Set(
    ScalarSettingsDomain.allCases.flatMap(\.settingKeys)
  )

  private static let privacySettingKeys = AppSettingsCodec.privacySettingKeys

  private static let openAIConfigurationSettingKeys = AppSettingsCodec
    .openAIConfigurationSettingKeys

  public func hasUnavailableScalarSettings(in domain: ScalarSettingsDomain) -> Bool {
    !unavailableScalarSettingKeys.isDisjoint(with: domain.settingKeys)
  }

  public func isRetryingUnavailableScalarSettings(in domain: ScalarSettingsDomain) -> Bool {
    retryingUnavailableScalarSettingsDomains.contains(domain)
  }

  func loadSettings() {
    guard settingsStore != nil || credentialStore != nil else {
      isLoadingSettings = false
      settingsKeysModifiedDuringInitialLoad.removeAll()
      unavailableScalarSettingKeys = Self.scalarSettingsKeys
      applyResolvedClipboardCapturePreference(enabled: false)
      localSpeechSettingsSource.markUnavailable()
      shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
      openAICredentialAvailability = .inaccessible
      vocabularyRuleSource.markUnavailable(
        reason: "Persistent settings storage is unavailable."
      )
      isLoadingPrivacySettings = false
      areHistoryRetentionSettingsAvailable = false
      historyRetentionSettingsLoadError = L10n.runText(
        .retentionStorageUnavailableDefaults,
        language: language
      )
      refreshHistoryRetentionSettingsErrorPresentation()
      if !privacySettingsSource.hasAvailableSettings {
        let reason = "Persistent settings storage is unavailable."
        privacySettingsSource.markUnavailable(reason: reason)
        privacySettingsLoadError = L10n.runText(.privacyLoadBlocked, language: language)
      }
      return
    }
    let settingsStore = self.settingsStore
    let workflowFileStore = self.workflowFileStore
    let credentialStore = self.credentialStore
    let requiresPersistentPrivacySettings = !privacySettingsSource.hasAvailableSettings
    settingsLoadGeneration &+= 1
    let generation = settingsLoadGeneration
    let slot = AppModelSettingsReadTaskSlot.initialSettingsLoad
    let taskID = UUID()
    let taskOwner = settingsReadTaskOwner
    let task = Task {
      @MainActor [weak self, settingsStore, workflowFileStore, credentialStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.settingsLoadGeneration == generation
      else {
        return
      }
      do {
        let settings = try await AppSettingsCodec.loadStoredAppSettings(
          from: settingsStore,
          credentialStore: credentialStore,
          requiresPersistentPrivacySettings: requiresPersistentPrivacySettings
        )
        let workflowFiles = await AppSettingsCodec.loadAndMigrateWorkflowFiles(
          from: workflowFileStore,
          legacyWorkflows: settings.customWorkflows,
          enabledStates: settings.workflowEnabledStates
        )
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settingsLoadGeneration == generation
        else {
          return
        }
        self.applyStoredSettings(settings, workflowFiles: workflowFiles)
        if workflowFiles?.didMigrateLegacyWorkflows == true {
          await AppSettingsCodec.retireLegacyWorkflowDefinitions(
            in: settingsStore,
            preserving: settings.workflowCustomizations
          )
        }
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settingsLoadGeneration == generation
        else {
          return
        }
        self.isLoadingSettings = false
        self.settingsKeysModifiedDuringInitialLoad.removeAll()
        self.unavailableScalarSettingKeys = Self.scalarSettingsKeys
        self.applyResolvedClipboardCapturePreference(enabled: false)
        self.localSpeechSettingsSource.markUnavailable()
        self.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
        self.openAICredentialAvailability = .inaccessible
        self.isRestoringSettings = true
        self.privacyPolicySettings = .defaults
        self.isRestoringSettings = false
        self.areHistoryRetentionSettingsAvailable = false
        self.historyRetentionSettingsLoadError = L10n.runText(
          .retentionLoadFailedPaused,
          language: self.language
        )
        self.refreshHistoryRetentionSettingsErrorPresentation()
        self.loadHistory()
        self.vocabularyRuleSource.markUnavailable(
          reason: "Configuration storage could not be loaded."
        )
        self.markStoredSettingsDomainUnavailable(.workflowLibrary)
        self.markStoredSettingsDomainUnavailable(.downloadedModelMetadata)
        self.markStoredSettingsDomainUnavailable(.vocabularyRules)
        self.isLoadingPrivacySettings = false
        self.privacySettingsSource.markUnavailable(
          reason: "Configuration storage could not be loaded."
        )
        self.privacySettingsLoadError = L10n.runText(
          .privacyLoadBlockedRetry,
          language: self.language
        )
        self.append(
          english: L10n.runText(.configurationStorageUnavailable, language: .english),
          simplifiedChinese: L10n.runText(
            .configurationStorageUnavailable,
            language: .simplifiedChinese
          )
        )
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  func applyStoredSettings(
    _ settings: StoredAppSettingsSnapshot,
    workflowFiles: InitialWorkflowFileLoad? = nil
  ) {
    let shouldPrepareLocalSpeechModel = shouldPrepareLocalSpeechModelAfterInitialSettingsLoad
    unavailableScalarSettingKeys = settings.unavailableSettingKeys.intersection(
      Self.scalarSettingsKeys
    )
    isRestoringSettings = true
    applyStoredWorkflowSettings(settings, workflowFiles: workflowFiles)
    applyStoredInterfaceSettings(settings)
    applyStoredSpeechSettings(settings)
    let trustedLocalSpeechModelMigration = applyStoredLocalSpeechSettings(settings)
    applyStoredOpenAISettings(settings)
    applyStoredVocabularySettings(settings)
    applyStoredPrivacySettings(settings)
    applyStoredHistoryRetentionSettings(settings)
    applyStoredFailedAudioRecoverySetting(settings)
    applyStoredBenchmarkRecordingArchiveSetting(settings)
    rebuildWorkflowLibrary()
    isRestoringSettings = false
    synchronizeLocalSpeechSettingsSource()
    setLocalSpeechRuntimeEnabledAction(preferredSpeechEngine == .local)
    let settingsModifiedDuringLoad = settingsKeysModifiedDuringInitialLoad
    isLoadingSettings = false
    settingsKeysModifiedDuringInitialLoad.removeAll()
    shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
    synchronizeResidentSpeechModels(from: [])
    if settings.workflowLibraryNeedsMigration
      || settings.vocabularyLibraryNeedsMigration
    {
      persistWorkflowCompositionMigration()
    }
    var localSpeechMigrationValues = settings.legacyLocalSpeechMigrationValues
    if let trustedLocalSpeechModelMigration,
      localSpeechModel == trustedLocalSpeechModelMigration
    {
      localSpeechMigrationValues[.localSpeechModel] = trustedLocalSpeechModelMigration
    }
    persistLocalSpeechSettingMigrations(
      localSpeechMigrationValues,
      excluding: settingsModifiedDuringLoad
    )
    loadFailedAudioRecoveryReceipts()
    for warning in settings.loadWarnings {
      let presentation = warning.presentation
      append(
        english: presentation.english,
        simplifiedChinese: presentation.simplifiedChinese
      )
    }
    performLocalHistoryRetention(startPeriodicMaintenanceAfterCompletion: true)
    if shouldPrepareLocalSpeechModel {
      prepareLocalSpeechModel()
    }
  }

  func markSettingModifiedDuringInitialLoad(_ key: AppSettingKey) {
    guard isLoadingSettings, !isRestoringSettings else { return }
    settingsKeysModifiedDuringInitialLoad.insert(key)
  }

  func shouldApplyStoredSetting(_ key: AppSettingKey) -> Bool {
    !settingsKeysModifiedDuringInitialLoad.contains(key)
      && !unavailableScalarSettingKeys.contains(key)
  }

  func applyStoredHistoryRetentionSettings(_ settings: StoredAppSettingsSnapshot) {
    guard settings.persistentSettingsStoreWasAvailable else {
      areHistoryRetentionSettingsAvailable = false
      historyRetentionSettingsLoadError = L10n.runText(
        .retentionStorageUnavailableDefaults,
        language: language
      )
      historyRetentionSettingsWriteError = nil
      clipboardHistoryRetentionSettingIsInvalid = false
      runHistoryRetentionSettingIsInvalid = false
      refreshHistoryRetentionSettingsErrorPresentation()
      loadHistory()
      return
    }
    areHistoryRetentionSettingsAvailable = true
    historyRetentionSettingsLoadError = nil
    historyRetentionSettingsWriteError = nil
    clipboardHistoryRetentionSettingIsInvalid = false
    runHistoryRetentionSettingIsInvalid = false
    recordRetentionPeriod = resolvedHistoryRetentionPeriod(
      settings.recordRetentionPeriod,
      isRecordSetting: true,
      settingWasUnavailable: settings.unavailableSettingKeys.contains(
        .recordRetentionPeriod
      )
    )
    runHistoryRetentionPeriod = resolvedHistoryRetentionPeriod(
      settings.runHistoryRetentionPeriod,
      isRecordSetting: false,
      settingWasUnavailable: settings.unavailableSettingKeys.contains(
        .runHistoryRetentionPeriod
      )
    )
    refreshHistoryRetentionSettingsErrorPresentation()
    loadHistory()
  }

  func applyStoredFailedAudioRecoverySetting(_ settings: StoredAppSettingsSnapshot) {
    guard settings.persistentSettingsStoreWasAvailable else {
      failedAudioRecoveryEnabled = false
      return
    }
    switch settings.failedAudioRecoveryEnabled {
    case "true":
      failedAudioRecoveryEnabled = true
    case nil, "", "false":
      failedAudioRecoveryEnabled = false
    default:
      failedAudioRecoveryEnabled = false
      append(
        english: L10n.runText(.failedRecoverySettingInvalid, language: .english),
        simplifiedChinese: L10n.runText(
          .failedRecoverySettingInvalid,
          language: .simplifiedChinese
        )
      )
    }
  }

  func applyStoredBenchmarkRecordingArchiveSetting(_ settings: StoredAppSettingsSnapshot) {
    guard settings.persistentSettingsStoreWasAvailable else {
      benchmarkRecordingArchiveEnabled = false
      return
    }
    switch settings.benchmarkRecordingArchiveEnabled {
    case "true":
      benchmarkRecordingArchiveEnabled = true
    case nil, "", "false":
      benchmarkRecordingArchiveEnabled = false
    default:
      benchmarkRecordingArchiveEnabled = false
      append(
        english: L10n.runText(.benchmarkSettingInvalid, language: .english),
        simplifiedChinese: L10n.runText(.benchmarkSettingInvalid, language: .simplifiedChinese)
      )
    }
  }

  private func resolvedHistoryRetentionPeriod(
    _ rawValue: String?,
    isRecordSetting: Bool,
    settingWasUnavailable: Bool = false
  ) -> HistoryRetentionPeriod {
    if settingWasUnavailable {
      if isRecordSetting {
        clipboardHistoryRetentionSettingIsInvalid = true
      } else {
        runHistoryRetentionSettingIsInvalid = true
      }
      append(
        english: L10n.runHistoryRetentionReadFailed(
          isRecordSetting: isRecordSetting,
          language: .english
        ),
        simplifiedChinese: L10n.runHistoryRetentionReadFailed(
          isRecordSetting: isRecordSetting,
          language: .simplifiedChinese
        )
      )
      return .forever
    }
    guard let rawValue, !rawValue.isEmpty else {
      return .defaultPeriod
    }
    guard let period = HistoryRetentionPeriod(rawValue: rawValue) else {
      if isRecordSetting {
        clipboardHistoryRetentionSettingIsInvalid = true
      } else {
        runHistoryRetentionSettingIsInvalid = true
      }
      append(
        english: L10n.runHistoryRetentionInvalid(
          isRecordSetting: isRecordSetting,
          language: .english
        ),
        simplifiedChinese: L10n.runHistoryRetentionInvalid(
          isRecordSetting: isRecordSetting,
          language: .simplifiedChinese
        )
      )
      return .forever
    }
    return period
  }

  func refreshHistoryRetentionSettingsErrorPresentation() {
    var messages: [String] = []
    if let historyRetentionSettingsLoadError {
      messages.append(historyRetentionSettingsLoadError)
    }
    if clipboardHistoryRetentionSettingIsInvalid {
      messages.append(L10n.runText(.clipboardRetentionDamaged, language: language))
    }
    if runHistoryRetentionSettingIsInvalid {
      messages.append(L10n.runText(.runRetentionDamaged, language: language))
    }
    if let historyRetentionSettingsWriteError {
      messages.append(historyRetentionSettingsWriteError)
    }
    historyRetentionSettingsError =
      messages.isEmpty
      ? nil
      : messages.joined(separator: "\n")
  }

  func applyStoredWorkflowSettings(
    _ settings: StoredAppSettingsSnapshot,
    workflowFiles: InitialWorkflowFileLoad?
  ) {
    let storedDomainUnavailable = settings.unavailableDomains.contains(.workflowLibrary)
    if storedDomainUnavailable, workflowFiles == nil {
      markStoredSettingsDomainUnavailable(.workflowLibrary)
      return
    }
    guard !hasModifiedWorkflowLibrary else { return }

    let usesTOMLSource: Bool
    if let workflowFiles {
      usesTOMLSource = settings.customWorkflows.isEmpty || workflowFiles.didMigrateLegacyWorkflows
    } else {
      usesTOMLSource = false
    }

    if usesTOMLSource, let workflowFiles {
      usesWorkflowFilesAsSource = true
      customWorkflows = workflowFiles.result.records.map(\.workflow)
      workflowFileSourcesByID = Dictionary(
        uniqueKeysWithValues: workflowFiles.result.records.compactMap { record in
          record.source.map { (record.workflow.id, $0) }
        })
      workflowFileIssues = workflowFiles.result.issues
      invalidWorkflowFileIDs = Set(workflowFileIssues.compactMap(\.workflowID))
      workflowFileURLsByID = Dictionary(
        uniqueKeysWithValues: workflowFiles.result.records.map {
          ($0.workflow.id, $0.fileURL)
        }
      )
      if let directory = workflowFileStore?.configurationDirectoryURL {
        for issue in workflowFileIssues {
          if let id = issue.workflowID, workflowFileURLsByID[id] == nil {
            workflowFileURLsByID[id] = directory.appendingPathComponent(issue.filename)
          }
        }
      }
      workflowEnabledStates =
        storedDomainUnavailable
        ? [:]
        : settings.workflowEnabledStates
      for record in workflowFiles.result.records {
        workflowEnabledStates[record.workflow.id] = record.isEnabled
      }
    } else {
      usesWorkflowFilesAsSource = false
      customWorkflows = settings.customWorkflows
      let partialRecords = workflowFiles?.result.records ?? []
      workflowFileURLsByID = Dictionary(
        uniqueKeysWithValues: partialRecords.map {
          ($0.workflow.id, $0.fileURL)
        })
      workflowFileSourcesByID = Dictionary(
        uniqueKeysWithValues: partialRecords.compactMap { record in
          record.source.map { (record.workflow.id, $0) }
        })
      workflowEnabledStates = settings.workflowEnabledStates
    }
    workflowCustomizations =
      storedDomainUnavailable
      ? []
      : settings.workflowCustomizations

    if storedDomainUnavailable {
      markStoredSettingsDomainUnavailable(.workflowLibrary)
    } else {
      workflowLibraryAvailability = .available
      workflowLibraryError = workflowFileIssueMessage(
        workflowFiles?.result.issues ?? []
      )
    }
    rebuildWorkflowLibrary()
    startWorkflowFileMonitoring()
  }

  public func reloadWorkflowFiles() async {
    guard let workflowFileStore else { return }
    workflowFileLoadGeneration += 1
    let generation = workflowFileLoadGeneration
    let result = await workflowFileStore.load()
    guard !hasBegunApplicationShutdown, generation == workflowFileLoadGeneration else { return }

    // A failed first-run migration deliberately keeps the legacy definitions active.
    // Do not let a manual reload of an empty directory discard that recovery copy.
    let shouldAdoptFileSource = usesWorkflowFilesAsSource || customWorkflows.isEmpty
    guard shouldAdoptFileSource else {
      workflowLibraryError = workflowFileIssueMessage(result.issues)
      return
    }

    usesWorkflowFilesAsSource = true
    let previousCustomIDs = Set(customWorkflows.map(\.id))
    let invalidNames = Set(result.issues.map(\.filename))
    let retainedInvalid = customWorkflows.filter { workflow in
      workflowFileURLsByID[workflow.id].map { invalidNames.contains($0.lastPathComponent) } ?? false
    }
    workflowFileIssues = result.issues
    invalidWorkflowFileIDs = Set(result.issues.compactMap(\.workflowID)).union(
      retainedInvalid.map(\.id))
    let validIDs = Set(result.records.map { $0.workflow.id })
    customWorkflows =
      result.records.map(\.workflow) + retainedInvalid.filter { !validIDs.contains($0.id) }
    let invalidURLs = workflowFileURLsByID.filter { invalidWorkflowFileIDs.contains($0.key) }
    workflowFileSourcesByID = Dictionary(
      uniqueKeysWithValues: result.records.compactMap { record in
        record.source.map { (record.workflow.id, $0) }
      })
    workflowFileURLsByID = Dictionary(
      uniqueKeysWithValues: result.records.map {
        ($0.workflow.id, $0.fileURL)
      }
    )
    workflowFileURLsByID.merge(invalidURLs) { current, _ in current }
    for workflowID in previousCustomIDs {
      workflowEnabledStates.removeValue(forKey: workflowID)
    }
    for record in result.records {
      workflowEnabledStates[record.workflow.id] = record.isEnabled
    }
    if isWorkflowLibraryAvailable {
      workflowLibraryError = workflowFileIssueMessage(result.issues)
    } else {
      refreshUnavailableStoredSettingsDomainErrors()
    }
    rebuildWorkflowLibrary()
    persistWorkflowEnabledStates()
  }

  func workflowFileIssueMessage(_ issues: [WorkflowFileIssue]) -> String? {
    guard !issues.isEmpty else { return nil }
    let visibleIssues = issues.prefix(3).map { issue in
      "\(issue.filename): \(issue.message)"
    }
    let suffix =
      issues.count > visibleIssues.count
      ? " (+\(issues.count - visibleIssues.count) more)"
      : ""
    let heading = L10n.runText(.workflowTOMLIssuesHeading, language: language)
    return "\(heading) \(visibleIssues.joined(separator: "; "))\(suffix)"
  }

  func applyStoredInterfaceSettings(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.interfaceLanguage),
      let storedLanguage = settings.language,
      let language = AppLanguage(rawValue: storedLanguage)
    {
      self.language = language
    }

    if settings.unavailableSettingKeys.contains(.systemClipboardCaptureEnabled) {
      applyResolvedClipboardCapturePreference(enabled: false)
    } else if shouldApplyStoredSetting(.systemClipboardCaptureEnabled) {
      applyResolvedClipboardCapturePreference(
        enabled: settings.systemClipboardCaptureEnabled.flatMap(
          AppSettingsCodec.storedBooleanIfValid) ?? false
      )
    }

    if shouldApplyStoredSetting(.recordHistoryVisibility),
      let rawVisibility = settings.recordHistoryVisibility,
      let visibility = RecordHistoryVisibility(rawValue: rawVisibility)
    {
      recordHistoryVisibility = visibility
    }

    if shouldApplyStoredSetting(.recordPanelHotkey) {
      recordPanelHotkeyBinding = HotkeyBindingDescriptor(
        storageString: settings.recordPanelHotkey
      )
    }
  }

  func applyStoredSpeechSettings(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.preferredSpeechEngine),
      let rawEngine = settings.preferredSpeechEngine,
      let engine = PreferredSpeechEngine(rawValue: rawEngine)
    {
      preferredSpeechEngine = engine
    }

    if shouldApplyStoredSetting(.ttsModel) {
      let storedModel = settings.ttsModel?.trimmingCharacters(in: .whitespacesAndNewlines)
      ttsModelIdentifier =
        ttsModelOptions.contains(where: { $0.id == storedModel })
        ? (storedModel ?? defaultTTSModelIdentifier)
        : defaultTTSModelIdentifier
    }

    if shouldApplyStoredSetting(.builtinPushToTalkOutputMode),
      let rawOutputMode = settings.builtinPushToTalkOutputMode,
      let outputMode = BuiltinPushToTalkOutputMode(rawValue: rawOutputMode)
    {
      builtinPushToTalkOutputMode = outputMode
    }

    if shouldApplyStoredSetting(.longRecordingModeEnabled),
      let rawLongRecordingMode = settings.longRecordingModeEnabled
    {
      longRecordingModeEnabled = AppSettingsCodec.storedBoolean(
        rawLongRecordingMode, defaultValue: false)
    }

    if shouldApplyStoredSetting(.recordingDurationLimit),
      let rawDurationLimit = settings.recordingDurationLimit,
      let durationLimit = RecordingDurationLimit(rawValue: rawDurationLimit)
    {
      recordingDurationLimit = durationLimit
    }
  }

  func applyStoredLocalSpeechSettings(_ settings: StoredAppSettingsSnapshot) -> String? {
    let shouldApplyStoredModel = shouldApplyStoredSetting(.localSpeechModel)
    let trustedModelMigration = trustedLocalSpeechModelMigrationTarget(
      storedModel: settings.localSpeechModel,
      shouldApplyStoredModel: shouldApplyStoredModel
    )
    if settings.unavailableDomains.contains(.downloadedModelMetadata) {
      markStoredSettingsDomainUnavailable(.downloadedModelMetadata)
    } else if shouldApplyStoredSetting(.localSpeechDownloadedModels) {
      downloadedLocalSpeechModelsAvailability = .available
      downloadedLocalSpeechModelsError = nil
      downloadedLocalSpeechModels = settings.downloadedLocalSpeechModels.filter { modelIdentifier in
        trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier })
      }
    }
    if shouldApplyStoredModel, let model = settings.localSpeechModel {
      localSpeechModel = model
    }
    if shouldApplyStoredSetting(.localSpeechPrewarm), let prewarm = settings.localSpeechPrewarm {
      localSpeechPrewarm = AppSettingsCodec.storedBoolean(
        prewarm, defaultValue: LocalSpeechSettings().prewarm)
    }
    if shouldApplyStoredSetting(.enabledSpeechModels),
      let rawValue = settings.enabledSpeechModels,
      let values = try? AppSettingsCodec.loadDownloadedLocalSpeechModels(from: rawValue)
    {
      enabledSpeechModelIDs = Set(values).intersection(
        speechModelResourceCatalog.map(\.id)
      )
    }
    if shouldApplyStoredSetting(.residentSpeechModels),
      let rawValue = settings.residentSpeechModels,
      let values = try? AppSettingsCodec.loadDownloadedLocalSpeechModels(from: rawValue)
    {
      residentSpeechModelIDs = Set(values).intersection(enabledSpeechModelIDs)
    }
    if shouldApplyStoredSetting(.speechModelMeasuredPeaks),
      let values = try? AppSettingsCodec.loadMeasuredSpeechModelPeaks(
        from: settings.speechModelMeasuredPeaks
      )
    {
      let catalogIDs = Set(speechModelResourceCatalog.map(\.id))
      measuredSpeechModelPeakByteCounts = values.filter { catalogIDs.contains($0.key) }
    }
    if shouldApplyStoredSetting(.residentSpeechBudgetConfirmation) {
      let value =
        settings.residentSpeechBudgetConfirmation?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      residentSpeechBudgetConfirmation =
        value == residentSpeechModelBudget.confirmationFingerprint ? value : nil
    }
    normalizeTrustedLocalSpeechSelection()
    synchronizeWakeWordResourceWithLocalSpeechModel()
    return trustedModelMigration
  }

  func trustedLocalSpeechModelMigrationTarget(
    storedModel: String?,
    shouldApplyStoredModel: Bool
  ) -> String? {
    guard shouldApplyStoredModel,
      let storedModel,
      !trustedLocalSpeechModels.isEmpty,
      let defaultLocalSpeechModelIdentifier
    else {
      return nil
    }
    if trustedLocalSpeechModels.contains(where: { $0.id == storedModel }) {
      return nil
    }
    let trimmedModel = storedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if trustedLocalSpeechModels.contains(where: { $0.id == trimmedModel }) {
      return trimmedModel
    }
    return defaultLocalSpeechModelIdentifier
  }

  func normalizeTrustedLocalSpeechSelection() {
    guard !trustedLocalSpeechModels.isEmpty,
      let defaultLocalSpeechModelIdentifier
    else {
      return
    }
    let storedModel = localSpeechModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if trustedLocalSpeechModels.contains(where: { $0.id == storedModel }) {
      localSpeechModel = storedModel
    } else {
      localSpeechModel = defaultLocalSpeechModelIdentifier
    }
  }

  func applyStoredOpenAISettings(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.openAIAPIKey) {
      if let apiKey = settings.openAIAPIKey {
        openAIAPIKey = apiKey
      }
      openAICredentialAvailability = settings.openAICredentialAvailability
    }
    if shouldApplyStoredSetting(.openAIBaseURL),
      let baseURL = settings.openAIBaseURL,
      OpenAISettings.isValidBaseURL(baseURL)
    {
      openAIBaseURL = baseURL
    }
    if shouldApplyStoredSetting(.openAIModel),
      let model = settings.openAIModel,
      OpenAISettings.isValidModelIdentifier(model)
    {
      openAIModel = model
    }
  }

  public func retryUnavailableScalarSettings(in domain: ScalarSettingsDomain) {
    if domain == .openAI {
      retryOpenAICredentialLoad()
      return
    }
    guard !hasBegunApplicationShutdown,
      hasUnavailableScalarSettings(in: domain),
      !isRetryingUnavailableScalarSettings(in: domain),
      let settingsStore
    else {
      return
    }

    let generation = (scalarSettingsRetryGenerations[domain] ?? 0) + 1
    scalarSettingsRetryGenerations[domain] = generation
    let localSpeechModelMutationGeneration = self.localSpeechModelMutationGeneration
    retryingUnavailableScalarSettingsDomains.insert(domain)
    let slot = AppModelSettingsReadTaskSlot.scalarSettingsRetry(domain)
    let taskID = UUID()
    let taskOwner = settingsReadTaskOwner
    let task = Task { @MainActor [weak self, settingsStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.scalarSettingsRetryGenerations[domain] == generation
      else {
        return
      }
      do {
        let readKeys =
          domain == .localSpeech
          ? Array(domain.settingKeys) + [
            .legacyWhisperKitModel,
            .legacyWhisperKitPrewarm,
          ]
          : Array(domain.settingKeys)
        let snapshot = try await settingsStore.settingsSnapshot(
          forKeys: readKeys
        )
        var recoveredValues = snapshot.values
        var recoveredUnavailableKeys = snapshot.unavailableKeys
        var legacyMigrationValues: [AppSettingKey: String] = [:]
        if domain == .localSpeech {
          let legacyLocalSpeechKeyPairs: [(AppSettingKey, AppSettingKey)] = [
            (AppSettingKey.localSpeechModel, .legacyWhisperKitModel),
            (.localSpeechPrewarm, .legacyWhisperKitPrewarm),
          ]
          for (currentKey, legacyKey) in legacyLocalSpeechKeyPairs {
            let resolution = AppSettingsCodec.resolveLegacyLocalSpeechSetting(
              currentKey: currentKey,
              legacyKey: legacyKey,
              in: snapshot
            )
            recoveredUnavailableKeys.remove(currentKey)
            recoveredUnavailableKeys.remove(legacyKey)
            if resolution.isUnavailable {
              recoveredValues.removeValue(forKey: currentKey)
              recoveredUnavailableKeys.insert(currentKey)
            } else if let value = resolution.value {
              recoveredValues[currentKey] = value
              if resolution.usedLegacyValue {
                legacyMigrationValues[currentKey] = value
              }
            } else {
              recoveredValues.removeValue(forKey: currentKey)
            }
          }
        }
        let invalidKeys = AppSettingsCodec.invalidScalarSettingKeys(in: recoveredValues)
        recoveredUnavailableKeys.formUnion(invalidKeys)
        for key in invalidKeys {
          legacyMigrationValues.removeValue(forKey: key)
        }
        let unavailableKeys =
          recoveredUnavailableKeys
          .intersection(domain.settingKeys)
        guard unavailableKeys.isEmpty else {
          throw ProviderSettingsPersistenceError.unavailableStoredSettings
        }
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.scalarSettingsRetryGenerations[domain] == generation
        else {
          return
        }
        let localSpeechModelWasModifiedDuringRetry =
          domain == .localSpeech
          && self.localSpeechModelMutationGeneration != localSpeechModelMutationGeneration
        let trustedLocalSpeechModelMigration =
          domain == .localSpeech && !localSpeechModelWasModifiedDuringRetry
          ? self.trustedLocalSpeechModelMigrationTarget(
            storedModel: recoveredValues[.localSpeechModel],
            shouldApplyStoredModel: true
          )
          : nil
        self.applyRecoveredScalarSettings(
          recoveredValues,
          in: domain,
          preservingLocalSpeechModel: localSpeechModelWasModifiedDuringRetry
        )
        if domain == .localSpeech {
          if localSpeechModelWasModifiedDuringRetry {
            legacyMigrationValues.removeValue(forKey: .localSpeechModel)
            if self.trustedLocalSpeechModels.contains(where: { $0.id == self.localSpeechModel }) {
              legacyMigrationValues[.localSpeechModel] = self.localSpeechModel
            }
          } else if let trustedLocalSpeechModelMigration,
            self.localSpeechModel == trustedLocalSpeechModelMigration
          {
            legacyMigrationValues[.localSpeechModel] = trustedLocalSpeechModelMigration
          }
          self.persistLocalSpeechSettingMigrations(legacyMigrationValues)
        }
        self.unavailableScalarSettingKeys.subtract(domain.settingKeys)
        if domain == .localSpeech {
          self.synchronizeLocalSpeechSettingsSource()
        }
        self.retryingUnavailableScalarSettingsDomains.remove(domain)
        self.append(
          english: L10n.runText(.savedSettingsAvailableAgain, language: .english),
          simplifiedChinese: L10n.runText(
            .savedSettingsAvailableAgain,
            language: .simplifiedChinese
          )
        )
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.scalarSettingsRetryGenerations[domain] == generation
        else {
          return
        }
        self.retryingUnavailableScalarSettingsDomains.remove(domain)
        self.append(
          english: L10n.runText(.savedSettingsStillUnavailable, language: .english),
          simplifiedChinese: L10n.runText(
            .savedSettingsStillUnavailable,
            language: .simplifiedChinese
          )
        )
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  public func retryOpenAICredentialLoad() {
    guard !hasBegunApplicationShutdown, !isLoadingSettings else { return }
    openAICredentialLoadGeneration &+= 1
    let generation = openAICredentialLoadGeneration
    guard let settingsStore, let credentialStore else {
      openAICredentialAvailability = .inaccessible
      return
    }

    openAICredentialAvailability = .loading
    retryingUnavailableScalarSettingsDomains.insert(.openAI)
    let slot = AppModelSettingsReadTaskSlot.openAICredentialRetry
    let taskID = UUID()
    let taskOwner = settingsReadTaskOwner
    let task = Task { @MainActor [weak self, settingsStore, credentialStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.openAICredentialLoadGeneration == generation
      else {
        return
      }
      do {
        async let settingsSnapshot = settingsStore.settingsSnapshot(
          forKeys: Array(ScalarSettingsDomain.openAI.settingKeys)
        )
        async let storedCredential = credentialStore.credential(for: .openAIAPIKey)
        let (snapshot, credential) = try await (settingsSnapshot, storedCredential)
        let unavailableKeys = snapshot.unavailableKeys
          .union(AppSettingsCodec.invalidScalarSettingKeys(in: snapshot.values))
          .intersection(ScalarSettingsDomain.openAI.settingKeys)
        guard unavailableKeys.isEmpty else {
          throw ProviderSettingsPersistenceError.unavailableStoredSettings
        }
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.openAICredentialLoadGeneration == generation
        else {
          return
        }
        let wasRestoringSettings = self.isRestoringSettings
        self.isRestoringSettings = true
        if let baseURL = snapshot.values[.openAIBaseURL],
          OpenAISettings.isValidBaseURL(baseURL)
        {
          self.openAIBaseURL = baseURL
        }
        if let model = snapshot.values[.openAIModel],
          OpenAISettings.isValidModelIdentifier(model)
        {
          self.openAIModel = model
        }
        self.openAIAPIKey = credential ?? ""
        self.isRestoringSettings = wasRestoringSettings
        self.unavailableScalarSettingKeys.subtract(
          ScalarSettingsDomain.openAI.settingKeys
        )
        self.retryingUnavailableScalarSettingsDomains.remove(.openAI)
        self.openAICredentialAvailability =
          AppSettingsCodec.openAICredentialAvailability(for: credential)
        self.workflowLibraryChangedAction()
        self.append(
          english: L10n.runText(.openAISettingsAvailableAgain, language: .english),
          simplifiedChinese: L10n.runText(
            .openAISettingsAvailableAgain,
            language: .simplifiedChinese
          )
        )
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.openAICredentialLoadGeneration == generation
        else {
          return
        }
        self.retryingUnavailableScalarSettingsDomains.remove(.openAI)
        self.openAICredentialAvailability = .inaccessible
        self.workflowLibraryChangedAction()
        self.append(
          english: L10n.runText(.openAISettingsStillUnavailable, language: .english),
          simplifiedChinese: L10n.runText(
            .openAISettingsStillUnavailable,
            language: .simplifiedChinese
          )
        )
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  private func applyRecoveredScalarSettings(
    _ values: [AppSettingKey: String],
    in domain: ScalarSettingsDomain,
    preservingLocalSpeechModel: Bool = false
  ) {
    let wasRestoringSettings = isRestoringSettings
    isRestoringSettings = true
    defer { isRestoringSettings = wasRestoringSettings }

    switch domain {
    case .interface:
      if let rawValue = values[.interfaceLanguage],
        let recoveredLanguage = AppLanguage(rawValue: rawValue)
      {
        language = recoveredLanguage
      }
    case .systemClipboard:
      applyResolvedClipboardCapturePreference(
        enabled: values[.systemClipboardCaptureEnabled].flatMap(
          AppSettingsCodec.storedBooleanIfValid) ?? false
      )
      if let rawValue = values[.recordHistoryVisibility],
        let visibility = RecordHistoryVisibility(rawValue: rawValue)
      {
        recordHistoryVisibility = visibility
      }
      if let rawValue = values[.recordPanelHotkey] {
        recordPanelHotkeyBinding = HotkeyBindingDescriptor(storageString: rawValue)
      }
    case .speechRoute:
      if let rawValue = values[.preferredSpeechEngine],
        let engine = PreferredSpeechEngine(rawValue: rawValue)
      {
        preferredSpeechEngine = engine
      }
      if let modelIdentifier = values[.ttsModel],
        ttsModelOptions.contains(where: { $0.id == modelIdentifier })
      {
        ttsModelIdentifier = modelIdentifier
      }
    case .localSpeech:
      if !preservingLocalSpeechModel, let model = values[.localSpeechModel] {
        localSpeechModel = model
      }
      if let rawValue = values[.localSpeechPrewarm],
        let value = AppSettingsCodec.storedBooleanIfValid(rawValue)
      {
        localSpeechPrewarm = value
      }
      normalizeTrustedLocalSpeechSelection()
    case .openAI:
      if let baseURL = values[.openAIBaseURL],
        OpenAISettings.isValidBaseURL(baseURL)
      {
        openAIBaseURL = baseURL
      }
      if let model = values[.openAIModel],
        OpenAISettings.isValidModelIdentifier(model)
      {
        openAIModel = model
      }
    case .input:
      if let rawValue = values[.builtinPushToTalkOutputMode],
        let outputMode = BuiltinPushToTalkOutputMode(rawValue: rawValue)
      {
        builtinPushToTalkOutputMode = outputMode
      }
      if let rawValue = values[.longRecordingModeEnabled],
        let value = AppSettingsCodec.storedBooleanIfValid(rawValue)
      {
        longRecordingModeEnabled = value
      }
      if let rawValue = values[.recordingDurationLimit],
        let value = RecordingDurationLimit(rawValue: rawValue)
      {
        recordingDurationLimit = value
      }
    }
  }

  func applyStoredVocabularySettings(_ settings: StoredAppSettingsSnapshot) {
    if settings.unavailableDomains.contains(.vocabularyRules) {
      markStoredSettingsDomainUnavailable(.vocabularyRules)
      return
    }
    vocabularyRulesAvailability = .available
    vocabularyRulesError = nil
    if shouldApplyStoredSetting(Self.vocabularyRulesSettingKey) {
      isApplyingVocabularyLibrary = true
      vocabularyCollections = settings.vocabularyCollections
      vocabularyCollectionBindings = settings.vocabularyBindings
      vocabularyRules = AppSettingsCodec.sortedVocabularyRules(settings.vocabularyRules)
      isApplyingVocabularyLibrary = false
      vocabularyRuleSource.updateCollections(vocabularyCollections)
      if settings.workflowLibraryNeedsMigration
        || settings.vocabularyLibraryNeedsMigration
      {
        workflowCustomizations = (customWorkflows + builtInWorkflows)
          .filter { $0.plan.setup.speechRoute != nil }
          .map {
            WorkflowCustomization(
              workflowID: $0.id,
              vocabularyBindings: vocabularyCollectionBindings
            )
          }
      }
      rebuildWorkflowLibrary()
    }
    if !settings.persistentSettingsStoreWasAvailable {
      vocabularyRuleSource.markUnavailable(
        reason: "Persistent settings storage is unavailable."
      )
    } else if settings.unavailableSettingKeys.contains(Self.vocabularyRulesSettingKey) {
      vocabularyRuleSource.markUnavailable(
        reason: "Stored vocabulary settings are unavailable."
      )
    }
  }

  public var isWorkflowLibraryAvailable: Bool {
    workflowLibraryAvailability == .available
  }

  public var areDownloadedLocalSpeechModelsAvailable: Bool {
    downloadedLocalSpeechModelsAvailability == .available
  }

  public var areVocabularyRulesAvailable: Bool {
    vocabularyRulesAvailability == .available
  }

  private func markStoredSettingsDomainUnavailable(_ domain: StoredSettingsDomain) {
    switch domain {
    case .workflowLibrary:
      workflowLibraryAvailability = .unavailable
    case .downloadedModelMetadata:
      downloadedLocalSpeechModelsAvailability = .unavailable
    case .vocabularyRules:
      vocabularyRulesAvailability = .unavailable
      vocabularyRuleSource.markUnavailable(
        reason: "Stored vocabulary settings could not be decoded safely."
      )
    }
    refreshUnavailableStoredSettingsDomainErrors()
  }

  func refreshUnavailableStoredSettingsDomainErrors() {
    if workflowLibraryAvailability == .unavailable {
      workflowLibraryError = unavailableStoredSettingsDomainMessage(.workflowLibrary)
    }
    if downloadedLocalSpeechModelsAvailability == .unavailable {
      downloadedLocalSpeechModelsError = unavailableStoredSettingsDomainMessage(
        .downloadedModelMetadata
      )
    }
    if vocabularyRulesAvailability == .unavailable {
      vocabularyRulesError = unavailableStoredSettingsDomainMessage(.vocabularyRules)
    }
  }

  private func unavailableStoredSettingsDomainMessage(_ domain: StoredSettingsDomain) -> String {
    switch (language, domain) {
    case (.english, .workflowLibrary):
      "The saved workflow library could not be loaded. Editing stays disabled to protect the existing data. Repair storage, then retry."
    case (.simplifiedChinese, .workflowLibrary):
      "无法加载已保存的工作流库。为保护现有数据，编辑保持停用。请修复存储后重试。"
    case (.english, .downloadedModelMetadata):
      "Downloaded local-model metadata could not be loaded. Rill will not overwrite it until storage is repaired and retried."
    case (.simplifiedChinese, .downloadedModelMetadata):
      "无法加载已下载本地模型的元数据。修复存储并重试前，Rill 不会覆盖该数据。"
    case (.english, .vocabularyRules):
      "The saved vocabulary rules could not be loaded. Editing stays disabled to protect the existing data. Repair storage, then retry."
    case (.simplifiedChinese, .vocabularyRules):
      "无法加载已保存的词汇规则。为保护现有数据，编辑保持停用。请修复存储后重试。"
    }
  }

  public func retryUnavailableStoredSettingsDomains() {
    guard !hasBegunApplicationShutdown,
      !isLoadingSettings,
      !isRetryingUnavailableSettingsDomains
    else {
      return
    }
    let retryWorkflowLibrary = workflowLibraryAvailability == .unavailable
    let retryDownloadedModelMetadata = downloadedLocalSpeechModelsAvailability == .unavailable
    let retryVocabularyRules = vocabularyRulesAvailability == .unavailable
    guard retryWorkflowLibrary || retryDownloadedModelMetadata || retryVocabularyRules else {
      return
    }
    guard let settingsStore else {
      refreshUnavailableStoredSettingsDomainErrors()
      return
    }

    unavailableSettingsDomainRetryGeneration += 1
    let generation = unavailableSettingsDomainRetryGeneration
    isRetryingUnavailableSettingsDomains = true
    let slot = AppModelSettingsReadTaskSlot.storedSettingsDomainsRetry
    let taskID = UUID()
    let taskOwner = settingsReadTaskOwner
    let workflowFileStore = self.workflowFileStore
    let task = Task {
      @MainActor [weak self, settingsStore, workflowFileStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.unavailableSettingsDomainRetryGeneration == generation
      else {
        return
      }
      do {
        let recovered = try await AppSettingsCodec.loadRecoverableStoredSettingsDomains(
          from: settingsStore,
          workflowFileStore: workflowFileStore
        )
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.unavailableSettingsDomainRetryGeneration == generation
        else {
          return
        }
        self.applyRecoveredStoredSettingsDomains(
          recovered,
          retryWorkflowLibrary: retryWorkflowLibrary,
          retryDownloadedModelMetadata: retryDownloadedModelMetadata,
          retryVocabularyRules: retryVocabularyRules
        )
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.unavailableSettingsDomainRetryGeneration == generation
        else {
          return
        }
        self.isRetryingUnavailableSettingsDomains = false
        self.refreshUnavailableStoredSettingsDomainErrors()
        self.append(
          english: L10n.runText(.protectedSettingsStillUnavailable, language: .english),
          simplifiedChinese: L10n.runText(
            .protectedSettingsStillUnavailable,
            language: .simplifiedChinese
          )
        )
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  private func applyRecoveredStoredSettingsDomains(
    _ recovered: RecoverableStoredSettingsDomains,
    retryWorkflowLibrary: Bool,
    retryDownloadedModelMetadata: Bool,
    retryVocabularyRules: Bool
  ) {
    let wasRestoringSettings = isRestoringSettings
    isRestoringSettings = true
    defer {
      isRestoringSettings = wasRestoringSettings
      isRetryingUnavailableSettingsDomains = false
      refreshUnavailableStoredSettingsDomainErrors()
    }

    var recoveredAnyDomain = false
    if retryWorkflowLibrary,
      let workflowEnabledStates = recovered.workflowEnabledStates
    {
      if let workflowFiles = recovered.workflowFiles {
        usesWorkflowFilesAsSource = true
        self.customWorkflows = workflowFiles.records.map(\.workflow)
        workflowFileSourcesByID = Dictionary(
          uniqueKeysWithValues: workflowFiles.records.compactMap { record in
            record.source.map { (record.workflow.id, $0) }
          })
        workflowFileIssues = workflowFiles.issues
        invalidWorkflowFileIDs = Set(workflowFiles.issues.compactMap(\.workflowID))
        workflowFileURLsByID = Dictionary(
          uniqueKeysWithValues: workflowFiles.records.map {
            ($0.workflow.id, $0.fileURL)
          }
        )
      } else if let customWorkflows = recovered.customWorkflows {
        usesWorkflowFilesAsSource = false
        self.customWorkflows = customWorkflows
      } else {
        return
      }
      self.workflowEnabledStates = workflowEnabledStates
      for record in recovered.workflowFiles?.records ?? [] {
        self.workflowEnabledStates[record.workflow.id] = record.isEnabled
      }
      workflowLibraryAvailability = .available
      workflowLibraryError = workflowFileIssueMessage(
        recovered.workflowFiles?.issues ?? []
      )
      rebuildWorkflowLibrary()
      recoveredAnyDomain = true
    }
    if retryDownloadedModelMetadata,
      let downloadedLocalSpeechModels = recovered.downloadedLocalSpeechModels
    {
      self.downloadedLocalSpeechModels =
        trustedLocalSpeechModels.isEmpty
        ? downloadedLocalSpeechModels
        : downloadedLocalSpeechModels.filter { modelIdentifier in
          trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier })
        }
      downloadedLocalSpeechModelsAvailability = .available
      downloadedLocalSpeechModelsError = nil
      recoveredAnyDomain = true
    }
    if retryVocabularyRules, let vocabularyRules = recovered.vocabularyRules {
      vocabularyRulesAvailability = .available
      vocabularyRulesError = nil
      self.vocabularyRules = vocabularyRules
      recoveredAnyDomain = true
    }

    if recoveredAnyDomain {
      append(
        english: L10n.runText(.protectedSettingsReloaded, language: .english),
        simplifiedChinese: L10n.runText(
          .protectedSettingsReloaded,
          language: .simplifiedChinese
        )
      )
    }
  }

  func applyStoredPrivacySettings(_ settings: StoredAppSettingsSnapshot) {
    privacyPolicySettings = settings.privacyPolicySettings
    isLoadingPrivacySettings = false
    if settings.privacySettingsWereInvalid {
      privacySettingsLoadError = L10n.runText(.privacySettingsDamaged, language: language)
      privacySettingsSource.markUnavailable(reason: "Privacy settings are damaged.")
    } else {
      privacySettingsLoadError = nil
      privacySettingsSource.update(privacyPolicySettings)
    }
  }

  func loadDiagnostics() {
    guard !hasBegunApplicationShutdown else { return }
    guard let diagnosticRepository else {
      diagnosticsLoadState = .loaded
      return
    }
    diagnosticsLoadGeneration += 1
    let generation = diagnosticsLoadGeneration
    diagnosticsLoadState = .loading
    let taskID = UUID()
    let task = Task { @MainActor [weak self, diagnosticRepository] in
      guard let self else { return }
      defer { self.finishHistoryProjectionLoadTask(id: taskID) }
      guard !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.diagnosticsLoadGeneration == generation
      else {
        return
      }
      do {
        let stored = try await diagnosticRepository.events(
          matching: DiagnosticQuery(limit: 50)
        )
        guard !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.diagnosticsLoadGeneration == generation
        else {
          return
        }
        self.diagnosticEvents = Self.sortedDiagnosticEvents(stored)
        self.diagnosticsLoadState = .loaded
      } catch {
        guard !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.diagnosticsLoadGeneration == generation
        else {
          return
        }
        self.diagnosticsLoadState = .failed
        self.append(
          english: L10n.runText(.diagnosticsRepositoryUnavailable, language: .english),
          simplifiedChinese: L10n.runText(
            .diagnosticsRepositoryUnavailable,
            language: .simplifiedChinese
          )
        )
      }
    }
    historyProjectionLoadTasks[taskID] = task
  }

  func persistPreferredSpeechEnginePreference() {
    persistStringSetting(
      preferredSpeechEngine.rawValue,
      for: .preferredSpeechEngine
    )
  }

  func persistBuiltinPushToTalkOutputModePreference() {
    persistStringSetting(
      builtinPushToTalkOutputMode.rawValue,
      for: .builtinPushToTalkOutputMode
    )
  }

  func persistLongRecordingModePreference() {
    persistStringSetting(
      longRecordingModeEnabled ? "true" : "false",
      for: .longRecordingModeEnabled
    )
  }

  func persistRecordingDurationLimitPreference() {
    persistStringSetting(
      recordingDurationLimit.rawValue,
      for: .recordingDurationLimit
    )
  }

  func persistLanguagePreference() {
    persistStringSetting(
      language.rawValue,
      for: .interfaceLanguage
    )
  }

  func persistRecordPanelHotkeyPreference() {
    persistStringSetting(
      recordPanelHotkeyBinding.storageString,
      for: .recordPanelHotkey
    )
  }

  func persistClipboardCaptureEnabledPreference() {
    persistStringSetting(
      systemClipboardCaptureEnabled ? "true" : "false",
      for: .systemClipboardCaptureEnabled
    )
  }

  func persistRecordHistoryVisibilityPreference() {
    persistStringSetting(
      recordHistoryVisibility.rawValue,
      for: .recordHistoryVisibility
    )
  }

  func persistLocalSpeechSettingMigrations(
    _ values: [AppSettingKey: String],
    excluding excludedKeys: Set<AppSettingKey> = []
  ) {
    for key in [
      AppSettingKey.preferredSpeechEngine,
      AppSettingKey.localSpeechModel,
      .localSpeechDownloadedModels,
      .localSpeechPrewarm,
    ] {
      guard !excludedKeys.contains(key), let value = values[key] else { continue }
      persistRetryableSettingsStoreWrite(
        for: key,
        category: .speech
      ) { settingsStore in
        try await settingsStore.setString(value, forKey: key)
      }
    }
  }

  func persistStringSetting(
    _ value: String,
    for key: AppSettingKey
  ) {
    markSettingModifiedDuringInitialLoad(key)
    guard !isRestoringSettings else { return }
    guard !unavailableScalarSettingKeys.contains(key) else { return }
    guard let category = AppSettingsCodec.settingsSaveCategory(for: key) else {
      assertionFailure("A specialized settings key was routed through ordinary persistence.")
      return
    }

    persistRetryableSettingsStoreWrite(
      for: key,
      category: category,
      debounceDuration: Self.debouncedStringSettingKeys.contains(key)
        ? settingsWriteDebounceDuration
        : .zero
    ) { settingsStore in
      try await settingsStore.setString(value, forKey: key)
    }
  }

  func persistSecureCredential(
    _ value: String,
    for credentialKey: SecureCredentialKey,
    taskKey: AppSettingKey
  ) {
    markSettingModifiedDuringInitialLoad(taskKey)
    guard !isRestoringSettings else { return }
    guard let credentialStore else {
      if credentialKey == .openAIAPIKey {
        openAICredentialAvailability = .inaccessible
      }
      append(
        english: L10n.runText(.credentialSaveFailed, language: .english),
        simplifiedChinese: L10n.runText(.credentialSaveFailed, language: .simplifiedChinese)
      )
      return
    }

    persistenceWrites.replace(
      for: taskKey,
      debounce: settingsWriteDebounceDuration
    ) {
      if value.isEmpty {
        try await credentialStore.removeCredential(for: credentialKey)
      } else {
        try await credentialStore.setCredential(value, for: credentialKey)
      }
    } completion: { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        if credentialKey == .openAIAPIKey {
          self.openAICredentialAvailability = AppSettingsCodec.openAICredentialAvailability(
            for: value)
          self.workflowLibraryChangedAction()
        }
      case .failure(is CancellationError):
        break
      case .failure:
        if credentialKey == .openAIAPIKey {
          self.openAICredentialAvailability = .inaccessible
          self.workflowLibraryChangedAction()
        }
        self.append(
          english: L10n.runText(.credentialSaveFailed, language: .english),
          simplifiedChinese: L10n.runText(.credentialSaveFailed, language: .simplifiedChinese)
        )
      }
    }
  }

  func persistRetryableSettingsStoreWrite(
    for key: AppSettingKey,
    category: SettingsSaveCategory,
    debounceDuration: Duration = .zero,
    operation: @escaping SettingsStoreWriteOperation
  ) {
    settings.submit(key: key, category: category, debounce: debounceDuration, operation: operation)
    { [weak self] in
      self?.appendSettingsSaveFailureEvent()
    }
  }

  public func retryUnsavedSettingsSave() {
    settings.retry { [weak self] in self?.appendSettingsSaveFailureEvent() }
  }

  func appendSettingsSaveFailureEvent() {
    append(
      english: L10n.runText(.settingsSaveFailedRetry, language: .english),
      simplifiedChinese: L10n.runText(.settingsSaveFailedRetry, language: .simplifiedChinese)
    )
  }

  public func flushPendingPersistenceWrites() async {
    await persistenceWrites.flush()
  }

  /// The global hotkey producer must not become available until the initial
  /// durable settings snapshot has atomically selected its workflow, speech
  /// engine, and hold/toggle mode. Manual UI remains usable while this waits.
  public func waitForInitialVoiceConfiguration() async {
    await settingsReadTaskOwner.waitForActiveTask(in: .initialSettingsLoad)
  }

  public func stopSettingsReadTasksForApplicationShutdown() async {
    hasBegunApplicationShutdown = true
    workflowFileMonitorTask?.cancel()
    await workflowFileMonitorTask?.value
    workflowFileMonitorTask = nil
    settingsLoadGeneration &+= 1
    openAICredentialLoadGeneration &+= 1
    openAIVerificationGeneration &+= 1
    openAIVerificationTask?.cancel()
    openAIVerificationTask = nil
    for domain in ScalarSettingsDomain.allCases {
      scalarSettingsRetryGenerations[domain, default: 0] &+= 1
    }
    unavailableSettingsDomainRetryGeneration &+= 1
    isLoadingSettings = false
    isLoadingPrivacySettings = false
    isRetryingUnavailableSettingsDomains = false
    settingsKeysModifiedDuringInitialLoad.removeAll()
    shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
    retryingUnavailableScalarSettingsDomains.removeAll()
    if openAICredentialAvailability == .loading {
      openAICredentialAvailability = .inaccessible
    }
    await settingsReadTaskOwner.cancelAllAndDrain()
  }

  public func drainPendingSettingsWritesForApplicationShutdown(
    retrySleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await ContinuousClock().sleep(for: duration)
    }
  ) async {
    await flushPendingPersistenceWrites()
    let retryDelays: [Duration] = [
      .milliseconds(500),
      .seconds(1),
      .seconds(2),
      .seconds(4),
      .seconds(8),
    ]
    var retryDelayIndex = 0

    while settings.hasUnsavedWrites {
      guard !Task.isCancelled else { return }
      retryUnsavedSettingsSave()
      await flushPendingPersistenceWrites()
      guard settings.hasUnsavedWrites else { return }

      do {
        try await retrySleep(retryDelays[retryDelayIndex])
      } catch is CancellationError {
        return
      } catch {
        return
      }
      retryDelayIndex = min(retryDelayIndex + 1, retryDelays.count - 1)
    }
  }

  func currentLocalSpeechSettings() -> LocalSpeechSettings {
    LocalSpeechSettings(
      model: selectedTrustedLocalSpeechModelIdentifier,
      modelRepo: "", modelToken: "", modelFolder: "", language: "", downloadIfNeeded: true,
      prewarm: localSpeechPrewarm,
      enabledModelIDs: enabledSpeechModelIDs,
      residentModelIDs: residentSpeechModelIDs,
      residentBudgetConfirmation: residentSpeechBudgetConfirmation
    )
  }

  func publishCurrentLocalSpeechSettingsToRuntime() {
    guard !isLoadingSettings,
      !isRestoringSettings,
      !hasUnavailableScalarSettings(in: .localSpeech)
    else {
      return
    }
    localSpeechSettingsSource.update(currentLocalSpeechSettings())
  }

  func synchronizeLocalSpeechSettingsSource() {
    guard !hasUnavailableScalarSettings(in: .localSpeech) else {
      localSpeechSettingsSource.markUnavailable()
      return
    }
    localSpeechSettingsSource.update(currentLocalSpeechSettings())
  }

  func setPrivacyCloudConfirmationRequired(_ isRequired: Bool) {
    guard privacySettingsAreEditable else { return }
    privacyPolicySettings.cloudConfirmationRequired = isRequired
  }

  @discardableResult
  public func grantCloudProcessingAuthorization(
    _ authorization: CloudProcessingAuthorization
  ) -> Bool {
    guard privacySettingsAreEditable else { return false }
    var policy = privacyPolicySettings
    policy.cloudProcessingAuthorizations.removeAll {
      $0.workflowID == authorization.workflowID
    }
    policy.cloudProcessingAuthorizations.append(authorization)
    privacyPolicySettings = policy
    return true
  }

  func revokeCloudProcessingAuthorization(_ authorizationID: UUID) {
    guard privacySettingsAreEditable else { return }
    var policy = privacyPolicySettings
    policy.cloudProcessingAuthorizations.removeAll { $0.id == authorizationID }
    privacyPolicySettings = policy
  }

  func revokeAllCloudProcessingAuthorizations() {
    guard privacySettingsAreEditable else { return }
    guard !privacyPolicySettings.cloudProcessingAuthorizations.isEmpty else { return }
    var policy = privacyPolicySettings
    policy.cloudProcessingAuthorizations = []
    privacyPolicySettings = policy
  }

  func setPrivacySecureInputConservativeMode(_ isEnabled: Bool) {
    guard privacySettingsAreEditable else { return }
    privacyPolicySettings.secureInputConservativeMode = isEnabled
  }

  func setPrivacyHistoryPreviewMode(_ mode: PrivacyHistoryPreviewMode) {
    guard privacySettingsAreEditable else { return }
    guard privacyPolicySettings.historyPreviewMode != mode else { return }
    privacyPolicySettings.historyPreviewMode = mode
  }

  func setSensitiveAppRuleEnabled(_ ruleID: UUID, isEnabled: Bool) {
    updateSensitiveAppRule(ruleID) { rule in rule.enabled = isEnabled }
  }

  func setSensitiveAppRuleBlocksClipboardHistory(_ ruleID: UUID, blocks: Bool) {
    updateSensitiveAppRule(ruleID) { rule in rule.blocksClipboardHistory = blocks }
  }

  func setSensitiveAppRuleBlocksWorkflowCapture(_ ruleID: UUID, blocks: Bool) {
    updateSensitiveAppRule(ruleID) { rule in rule.blocksWorkflowCapture = blocks }
  }

  func setSensitiveAppRuleBlocksSelectedText(_ ruleID: UUID, blocks: Bool) {
    updateSensitiveAppRule(ruleID) { rule in rule.blocksSelectedText = blocks }
  }

  func setSensitiveAppRuleBlocksCloudProcessing(_ ruleID: UUID, blocks: Bool) {
    updateSensitiveAppRule(ruleID) { rule in rule.blocksCloudProcessing = blocks }
  }

  func addSensitiveAppRule(
    bundleIdentifier: String,
    applicationName: String?
  ) throws {
    try ensurePrivacySettingsAreEditable()
    let rule = try SensitiveAppRule(
      bundleIdentifier: bundleIdentifier,
      applicationName: applicationName
    ).normalizedAndValidated()
    var policy = privacyPolicySettings
    policy.sensitiveAppRules = try SensitiveAppRule.mergingRecommendedDefaults(
      with: policy.sensitiveAppRules + [rule]
    )
    privacyPolicySettings = policy
  }

  func editSensitiveAppRule(
    _ ruleID: UUID,
    bundleIdentifier: String,
    applicationName: String?
  ) throws {
    try ensurePrivacySettingsAreEditable()
    guard let index = privacyPolicySettings.sensitiveAppRules.firstIndex(where: { $0.id == ruleID })
    else {
      throw SensitiveAppRuleValidationError.ruleNotFound
    }
    guard !privacyPolicySettings.sensitiveAppRules[index].isRecommended else {
      throw SensitiveAppRuleValidationError.recommendedRuleCannotBeEdited
    }

    var policy = privacyPolicySettings
    policy.sensitiveAppRules[index].bundleIdentifier = bundleIdentifier
    policy.sensitiveAppRules[index].applicationName = applicationName
    policy.sensitiveAppRules = try SensitiveAppRule.mergingRecommendedDefaults(
      with: policy.sensitiveAppRules
    )
    privacyPolicySettings = policy
  }

  func deleteSensitiveAppRule(_ ruleID: UUID) throws {
    try ensurePrivacySettingsAreEditable()
    guard let rule = privacyPolicySettings.sensitiveAppRules.first(where: { $0.id == ruleID })
    else {
      throw SensitiveAppRuleValidationError.ruleNotFound
    }
    guard !rule.isRecommended else {
      throw SensitiveAppRuleValidationError.recommendedRuleCannotBeEdited
    }
    var policy = privacyPolicySettings
    policy.sensitiveAppRules.removeAll { $0.id == ruleID }
    privacyPolicySettings = policy
  }

  func restoreRecommendedSensitiveAppRules() throws {
    try ensurePrivacySettingsAreEditable()
    var policy = privacyPolicySettings
    policy.sensitiveAppRules = try SensitiveAppRule.restoringRecommendedDefaults(
      whileKeepingCustomRules: policy.sensitiveAppRules
    )
    privacyPolicySettings = policy
  }

  private func updateSensitiveAppRule(_ ruleID: UUID, mutate: (inout SensitiveAppRule) -> Void) {
    guard privacySettingsAreEditable else { return }
    guard let index = privacyPolicySettings.sensitiveAppRules.firstIndex(where: { $0.id == ruleID })
    else { return }
    mutate(&privacyPolicySettings.sensitiveAppRules[index])
  }

  private var privacySettingsAreEditable: Bool {
    !hasBegunApplicationShutdown
      && !isLoadingPrivacySettings
      && privacySettingsLoadError == nil
  }

  private func ensurePrivacySettingsAreEditable() throws {
    if hasBegunApplicationShutdown {
      throw PrivacyPolicySettingsSourceError.notReady
    }
    if isLoadingPrivacySettings {
      throw PrivacyPolicySettingsSourceError.notReady
    }
    if let privacySettingsLoadError {
      throw PrivacyPolicySettingsSourceError.unavailable(privacySettingsLoadError)
    }
  }

  func persistVocabularyRules() {
    persistVocabularyLibrary()
  }

  func persistVocabularyLibrary() {
    markSettingModifiedDuringInitialLoad(Self.vocabularyLibrarySettingKey)
    guard !isRestoringSettings, areVocabularyRulesAvailable else { return }
    let document = VocabularyLibraryDocument(
      collections: vocabularyCollections, defaultBindings: vocabularyCollectionBindings)
    persistRetryableSettingsStoreWrite(
      for: Self.vocabularyLibrarySettingKey,
      category: .vocabulary
    ) { settingsStore in
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(document)
      try await settingsStore.setString(
        String(decoding: data, as: UTF8.self),
        forKey: Self.vocabularyLibrarySettingKey
      )
    }
  }

  func persistWorkflowCompositionMigration() {
    guard let settingsStore, !hasBegunApplicationShutdown else { return }
    let workflowDocument = WorkflowLibraryDocument(
      customWorkflows: usesWorkflowFilesAsSource ? [] : customWorkflows,
      customizations: workflowCustomizations
    )
    let vocabularyDocument = VocabularyLibraryDocument(
      collections: vocabularyCollections, defaultBindings: vocabularyCollectionBindings
    )
    Task { [weak self, settingsStore] in
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let workflowData = try encoder.encode(workflowDocument)
        let vocabularyData = try encoder.encode(vocabularyDocument)
        try await settingsStore.setStringsAtomically([
          Self.workflowLibrarySettingKey: String(decoding: workflowData, as: UTF8.self),
          Self.vocabularyLibrarySettingKey: String(
            decoding: vocabularyData,
            as: UTF8.self
          ),
        ])
      } catch {
        await MainActor.run {
          self?.markStoredSettingsDomainUnavailable(.workflowLibrary)
          self?.markStoredSettingsDomainUnavailable(.vocabularyRules)
          self?.append(
            english: L10n.runText(.workflowMigrationSaveFailed, language: .english),
            simplifiedChinese: L10n.runText(
              .workflowMigrationSaveFailed,
              language: .simplifiedChinese
            )
          )
        }
      }
    }
  }

  func persistPrivacyPolicySettings() {
    guard !hasBegunApplicationShutdown, !isRestoringSettings else { return }
    guard let settingsStore else {
      privacySettingsSaveError = L10n.runText(
        .privacySaveStorageUnavailable,
        language: language
      )
      isSavingPrivacySettings = false
      return
    }
    let policy = privacyPolicySettings
    let values: [AppSettingKey: String]
    do {
      values = try AppSettingsCodec.privacySettingsStorageValues(for: policy)
    } catch {
      privacySettingsSaveError = localizedPrivacySettingsSaveFailure()
      isSavingPrivacySettings = false
      return
    }

    privacySettingsWriteGeneration += 1
    let generation = privacySettingsWriteGeneration
    let previousTask = pendingPrivacySettingsWriteTask
    isSavingPrivacySettings = true
    let task = Task { [weak self, settingsStore, previousTask] in
      await previousTask?.value
      do {
        try await settingsStore.setStringsAtomically(values)
        await MainActor.run {
          guard let self, self.privacySettingsWriteGeneration == generation else { return }
          self.pendingPrivacySettingsWriteTask = nil
          self.isSavingPrivacySettings = false
          self.privacySettingsSaveError = nil
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.append(
            english: L10n.runText(.privacySaveFailedRetry, language: .english),
            simplifiedChinese: L10n.runText(
              .privacySaveFailedRetry,
              language: .simplifiedChinese
            )
          )
          guard self.privacySettingsWriteGeneration == generation else { return }
          self.pendingPrivacySettingsWriteTask = nil
          self.isSavingPrivacySettings = false
          self.privacySettingsSaveError = self.localizedPrivacySettingsSaveFailure()
        }
      }
    }
    pendingPrivacySettingsWriteTask = task
    persistenceWrites.track(task)
  }

  func retryPrivacySettingsSave() {
    persistPrivacyPolicySettings()
  }

  func retryPrivacySettingsLoad() {
    guard !hasBegunApplicationShutdown, !isLoadingPrivacySettings else { return }
    isLoadingPrivacySettings = true
    workflowLibraryChangedAction()
    let settingsStore = self.settingsStore
    let settingKeys: [AppSettingKey] = [
      .privacySensitiveAppRules,
      .privacyCloudConfirmationRequired,
      .privacyCloudProcessingAuthorizations,
      .privacyHistoryPreviewMode,
      .privacySecureInputConservativeMode,
    ]
    let slot = AppModelSettingsReadTaskSlot.privacySettingsRetry
    let taskID = UUID()
    let taskOwner = settingsReadTaskOwner
    let task = Task { @MainActor [weak self, settingsStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown
      else {
        return
      }
      do {
        guard let settingsStore else {
          throw PrivacyPolicySettingsSourceError.unavailable(
            "Persistent settings storage is unavailable."
          )
        }
        let snapshot = try await settingsStore.settingsSnapshot(
          forKeys: settingKeys
        )
        guard snapshot.unavailableKeys.isDisjoint(with: settingKeys) else {
          throw PrivacyPolicySettingsSourceError.unavailable(
            "A protected privacy setting is unavailable."
          )
        }
        let policy = try AppSettingsCodec.decodePrivacyPolicySettings(from: snapshot.values)
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown
        else {
          return
        }
        self.isRestoringSettings = true
        self.privacyPolicySettings = policy
        self.isRestoringSettings = false
        self.isLoadingPrivacySettings = false
        self.privacySettingsLoadError = nil
        self.privacySettingsSource.update(policy)
        self.workflowLibraryChangedAction()
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown
        else {
          return
        }
        self.isLoadingPrivacySettings = false
        self.privacySettingsLoadError = L10n.runText(
          .privacyLoadFailedRepairStorage,
          language: self.language
        )
        self.privacySettingsSource.markUnavailable(
          reason: "Privacy settings could not be loaded."
        )
        self.workflowLibraryChangedAction()
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  func resetPrivacySettingsToSafeDefaults() {
    guard !hasBegunApplicationShutdown, !isLoadingPrivacySettings else { return }
    let defaults = PrivacyPolicySettings.defaults
    isLoadingPrivacySettings = false
    privacySettingsLoadError = nil
    isRestoringSettings = true
    privacyPolicySettings = defaults
    isRestoringSettings = false
    privacySettingsSource.update(defaults)
    workflowLibraryChangedAction()
    persistPrivacyPolicySettings()
  }

  func waitForPendingPrivacySettingsWrite() async {
    await pendingPrivacySettingsWriteTask?.value
  }

  private func localizedPrivacySettingsSaveFailure() -> String {
    L10n.runText(.privacySaveFailedSessionOnly, language: language)
  }

  func persistWorkflowEnabledStates() {
    markSettingModifiedDuringInitialLoad(.workflowEnabledStates)
    guard !isRestoringSettings, isWorkflowLibraryAvailable else { return }
    let enabledStates =
      workflowEnabledStates
      .reduce(into: [String: Bool]()) { partialResult, entry in
        partialResult[entry.key.uuidString] = entry.value
      }

    persistRetryableSettingsStoreWrite(
      for: .workflowEnabledStates,
      category: .workflows
    ) { settingsStore in
      if enabledStates.isEmpty {
        try await settingsStore.removeValue(forKey: .workflowEnabledStates)
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(enabledStates)
        try await settingsStore.setString(
          String(decoding: data, as: UTF8.self),
          forKey: .workflowEnabledStates
        )
      }
    }
  }

  func persistDownloadedLocalSpeechModels() {
    markSettingModifiedDuringInitialLoad(.localSpeechDownloadedModels)
    guard !isRestoringSettings, areDownloadedLocalSpeechModelsAvailable else { return }
    let downloadedLocalSpeechModels = self.downloadedLocalSpeechModels

    persistRetryableSettingsStoreWrite(
      for: .localSpeechDownloadedModels,
      category: .speech
    ) { settingsStore in
      if downloadedLocalSpeechModels.isEmpty {
        try await settingsStore.removeValue(forKey: .localSpeechDownloadedModels)
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(downloadedLocalSpeechModels)
        try await settingsStore.setString(
          String(decoding: data, as: UTF8.self),
          forKey: .localSpeechDownloadedModels
        )
      }
    }
  }

  func recordDownloadedLocalSpeechModel(_ modelIdentifier: String) {
    guard !hasBegunApplicationShutdown,
      !isLoadingSettings,
      !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      areDownloadedLocalSpeechModelsAvailable,
      trustedLocalSpeechModels.isEmpty
        || trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier }),
      !downloadedLocalSpeechModels.contains(modelIdentifier)
    else {
      return
    }
    downloadedLocalSpeechModels.append(modelIdentifier)
    downloadedLocalSpeechModels.sort()
    persistDownloadedLocalSpeechModels()
    synchronizeWakeWordResourceWithLocalSpeechModel()
  }
}
