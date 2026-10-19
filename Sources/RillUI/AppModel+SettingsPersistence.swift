import AppKit
import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

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
  case privacy
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
        .bufferOutputHotkey,
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
        .longRecordingModeEnabled,
        .recordingDurationLimit,
      ]
    }
  }

  public func unavailableWarning(language: AppLanguage) -> String {
    L10n.resource(
      "settings.unavailableWarning",
      defaultValue: "Some saved \(nameResource) settings could not be read. These controls are locked to preserve the original stored values."
    ).string(for: language)
  }

  private var nameResource: LocalizedStringResource {
    switch self {
    case .interface: L10n.resource("settings.domain.interface")
    case .systemClipboard: L10n.resource("settings.domain.systemClipboard")
    case .speechRoute: L10n.resource("settings.domain.speechRoute")
    case .localSpeech: L10n.resource("settings.domain.localSpeech")
    case .openAI: L10n.resource("models.service.llm")

    case .input: L10n.resource("settings.domain.input")
    }
  }
}

enum ProviderSettingsPersistenceError: LocalizedError, Sendable, Equatable {
  case unavailableStoredSettings

  var errorDescription: String? {
    "Saved speech-provider settings are unavailable."
  }

  var presentation: LocalizedStringResource {
    L10n.resource("AppModel.SettingsPersistence.Saved.speech.provider.settings.are.unavailable")
  }

  func message(language: AppLanguage) -> String {
    presentation.string(for: language)
  }
}

typealias SettingsStoreWriteOperation =
  @Sendable (
    any SettingsStore
  ) async throws -> Void

struct RetryableSettingsStoreWrite: Sendable {
  enum Content: Sendable {
    case operation(SettingsStoreWriteOperation)
    case string(@Sendable () throws -> String)
  }

  let category: SettingsSaveCategory
  let content: Content

  init(category: SettingsSaveCategory, operation: @escaping SettingsStoreWriteOperation) {
    self.category = category
    content = .operation(operation)
  }

  init(_ value: SettingsStringWrite) {
    category = value.category
    content = .string(value.encode)
  }

  func perform(in store: any SettingsStore, for key: AppSettingKey) async throws {
    switch content {
    case .operation(let operation): try await operation(store)
    case .string(let encode): try await store.setString(encode(), forKey: key)
    }
  }
}

enum StoredSettingsLoadWarning: Sendable {
  case legacyWorkflowFormatUnsupported
  case storedValuesUnavailable
  case downloadedModelMetadata
  case vocabularyRules
  case openAICredential

  var presentation: LocalizedStringResource {
    switch self {
    case .legacyWorkflowFormatUnsupported:
      L10n.resource("workflow.legacy.unsupported")
    case .storedValuesUnavailable:
      L10n.resource("AppModel.SettingsPersistence.One.or.more.stored.settings.could.not.be.read.Affected.features.remain")
    case .downloadedModelMetadata:
      L10n.resource("AppModel.SettingsPersistence.Downloaded.model.metadata.could.not.be.loaded.and.was.ignored")
    case .vocabularyRules:
      L10n.resource("AppModel.SettingsPersistence.Vocabulary.rules.could.not.be.loaded.and.were.ignored")
    case .openAICredential:
      L10n.resource("AppModel.SettingsPersistence.The.LLM.Provider.credential.could.not.be.read.from.secure.storage")
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
  let systemClipboardCaptureEnabled: String?
  let recordHistoryVisibility: String?
  let bufferOutputHotkey: String?
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
  let corpusRecordingArchiveEnabled: String?
  let longRecordingModeEnabled: String?
  let recordingDurationLimit: String?
  let loadWarnings: [StoredSettingsLoadWarning]
  let unavailableDomains: Set<StoredSettingsDomain>
}

struct RecoverableStoredSettingsDomains: Sendable {
  let workflowFiles: WorkflowFileLoadResult?
  let downloadedLocalSpeechModels: [String]?
  let vocabularyRules: [VocabularyRule]?
}

enum StoredSettingsCollectionValidationError: Error {
  case invalidIdentifier
  case duplicateIdentifier
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

  func loadSettings() {
    guard settingsStore != nil || credentialStore != nil else {
      self.settings.isLoading = false
      self.settings.settingsKeysModifiedDuringInitialLoad.removeAll()
      self.settings.unavailableScalarSettingKeys = Self.scalarSettingsKeys
      applyResolvedClipboardCapturePreference(enabled: false)
      localSpeechSettingsSource.markUnavailable()
      self.voice.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
      do {
        self.settings.setCredentialAvailability(.inaccessible)
        self.publishLanguageModelSettings()
      }
      vocabularyRuleSource.markUnavailable(
        reason: "Persistent settings storage is unavailable."
      )
      self.settings.isLoadingPrivacySettings = false
      self.history.areHistoryRetentionSettingsAvailable = false
      self.history.historyRetentionSettingsLoadFailure = L10n.resource("run.retentionStorageUnavailableDefaults")

      if !privacySettingsSource.hasAvailableSettings {
        let reason = "Persistent settings storage is unavailable."
        privacySettingsSource.markUnavailable(reason: reason)
        self.settings.privacySettingsLoadFailure = L10n.resource("run.privacyLoadBlocked")
      }
      return
    }
    let settingsStore = self.settingsStore
    let workflowFileStore = self.workflowFileStore
    let credentialStore = self.credentialStore
    let requiresPersistentPrivacySettings = !privacySettingsSource.hasAvailableSettings
    self.settings.settingsLoadGeneration &+= 1
    let generation = self.settings.settingsLoadGeneration
    let slot = AppModelSettingsReadTaskSlot.initialSettingsLoad
    let taskID = UUID()
    let taskOwner = self.settings.settingsReadTaskOwner
    let task = Task {
      @MainActor [weak self, settingsStore, workflowFileStore, credentialStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.settings.settingsLoadGeneration == generation
      else {
        return
      }
      do {
        let settings = try await AppSettingsCodec.loadStoredAppSettings(
          from: settingsStore,
          credentialStore: credentialStore,
          requiresPersistentPrivacySettings: requiresPersistentPrivacySettings
        )
        let workflowFiles = await workflowFileStore?.load()
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settings.settingsLoadGeneration == generation
        else {
          return
        }
        self.applyStoredSettings(settings, workflowFiles: workflowFiles)
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settings.settingsLoadGeneration == generation
        else {
          return
        }
        self.settings.isLoading = false
        self.settings.settingsKeysModifiedDuringInitialLoad.removeAll()
        self.settings.unavailableScalarSettingKeys = Self.scalarSettingsKeys
        self.applyResolvedClipboardCapturePreference(enabled: false)
        self.localSpeechSettingsSource.markUnavailable()
        self.voice.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
        do {
          self.settings.setCredentialAvailability(.inaccessible)
          self.publishLanguageModelSettings()
        }
        self.settings.isRestoringSettings = true
        self.applyPrivacyPolicySettings(.defaults)
        self.settings.isRestoringSettings = false
        self.history.areHistoryRetentionSettingsAvailable = false
        self.history.historyRetentionSettingsLoadFailure = L10n.resource("run.retentionLoadFailedPaused")

        self.loadHistory()
        self.vocabularyRuleSource.markUnavailable(
          reason: "Configuration storage could not be loaded."
        )
        self.markStoredSettingsDomainUnavailable(.workflowLibrary)
        self.markStoredSettingsDomainUnavailable(.downloadedModelMetadata)
        self.markStoredSettingsDomainUnavailable(.vocabularyRules)
        self.settings.isLoadingPrivacySettings = false
        self.privacySettingsSource.markUnavailable(
          reason: "Configuration storage could not be loaded."
        )
        self.settings.privacySettingsLoadFailure = L10n.resource("run.privacyLoadBlockedRetry")
        self.append(
          L10n.resource("run.configurationStorageUnavailable")
        )
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  func applyStoredSettings(
    _ settings: StoredAppSettingsSnapshot,
    workflowFiles: WorkflowFileLoadResult? = nil
  ) {
    let shouldPrepareLocalSpeechModel = self.voice.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad
    self.settings.unavailableScalarSettingKeys = settings.unavailableSettingKeys.intersection(
      Self.scalarSettingsKeys
    )
    self.settings.isRestoringSettings = true
    applyStoredWorkflowSettings(settings, workflowFiles: workflowFiles)
    applyStoredInterfaceSettings(settings)
    applyStoredSpeechSettings(settings)
    let trustedLocalSpeechModelMigration = applyStoredLocalSpeechSettings(settings)
    applyStoredOpenAISettings(settings)
    applyStoredVocabularySettings(settings)
    applyStoredPrivacySettings(settings)
    applyStoredHistoryRetentionSettings(settings)
    applyStoredFailedAudioRecoverySetting(settings)
    corpusArchive.applyStored(settings.corpusRecordingArchiveEnabled, available: settings.persistentSettingsStoreWasAvailable)
    rebuildWorkflowLibrary()
    self.settings.isRestoringSettings = false
    synchronizeLocalSpeechSettingsSource()
    setLocalSpeechRuntimeEnabledAction(self.settings.preferredSpeechEngine == .local)
    let settingsModifiedDuringLoad = self.settings.settingsKeysModifiedDuringInitialLoad
    self.settings.isLoading = false
    self.settings.settingsKeysModifiedDuringInitialLoad.removeAll()
    self.voice.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
    synchronizeResidentSpeechModels(from: [])
    if settings.vocabularyLibraryNeedsMigration { vocabulary.commit() }
    var localSpeechMigrationValues = settings.legacyLocalSpeechMigrationValues
    if let trustedLocalSpeechModelMigration,
      self.settings.localSpeechModel == trustedLocalSpeechModelMigration
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
      append(presentation)
    }
    performLocalHistoryRetention(startPeriodicMaintenanceAfterCompletion: true)
    if shouldPrepareLocalSpeechModel {
      prepareLocalSpeechModel()
    }
  }

  func markSettingModifiedDuringInitialLoad(_ key: AppSettingKey) {
    guard self.settings.isLoading, !self.settings.isRestoringSettings else { return }
    self.settings.settingsKeysModifiedDuringInitialLoad.insert(key)
  }

  func shouldApplyStoredSetting(_ key: AppSettingKey) -> Bool {
    !self.settings.settingsKeysModifiedDuringInitialLoad.contains(key)
      && !self.settings.unavailableScalarSettingKeys.contains(key)
  }

  func applyStoredHistoryRetentionSettings(_ settings: StoredAppSettingsSnapshot) {
    guard settings.persistentSettingsStoreWasAvailable else {
      self.history.areHistoryRetentionSettingsAvailable = false
      self.history.historyRetentionSettingsLoadFailure = L10n.resource("run.retentionStorageUnavailableDefaults")
      self.history.historyRetentionSettingsWriteFailure = nil
      self.history.clipboardHistoryRetentionSettingIsInvalid = false
      self.history.runHistoryRetentionSettingIsInvalid = false

      loadHistory()
      return
    }
    self.history.areHistoryRetentionSettingsAvailable = true
    self.history.historyRetentionSettingsLoadFailure = nil
    self.history.historyRetentionSettingsWriteFailure = nil
    self.history.clipboardHistoryRetentionSettingIsInvalid = false
    self.history.runHistoryRetentionSettingIsInvalid = false
    recordRetentionPeriod = resolvedHistoryRetentionPeriod(
      settings.recordRetentionPeriod,
      isRecordSetting: true,
      settingWasUnavailable: settings.unavailableSettingKeys.contains(
        .recordRetentionPeriod
      )
    )
    history.applyRunHistoryRetentionPeriod(
      resolvedHistoryRetentionPeriod(
        settings.runHistoryRetentionPeriod,
        isRecordSetting: false,
        settingWasUnavailable: settings.unavailableSettingKeys.contains(
          .runHistoryRetentionPeriod
        )
      ))

    loadHistory()
  }

  func applyStoredFailedAudioRecoverySetting(_ settings: StoredAppSettingsSnapshot) {
    guard settings.persistentSettingsStoreWasAvailable else {
      self.voice.failedAudioRecoveryEnabled = false
      return
    }
    switch settings.failedAudioRecoveryEnabled {
    case "true":
      self.voice.failedAudioRecoveryEnabled = true
    case nil, "", "false":
      self.voice.failedAudioRecoveryEnabled = false
    default:
      self.voice.failedAudioRecoveryEnabled = false
      append(
        L10n.resource("run.failedRecoverySettingInvalid")
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
        self.history.clipboardHistoryRetentionSettingIsInvalid = true
      } else {
        self.history.runHistoryRetentionSettingIsInvalid = true
      }
      append(
        L10n.runHistoryRetentionReadFailed(isRecordSetting: isRecordSetting)
      )
      return .forever
    }
    guard let rawValue, !rawValue.isEmpty else {
      return .defaultPeriod
    }
    guard let period = HistoryRetentionPeriod(rawValue: rawValue) else {
      if isRecordSetting {
        self.history.clipboardHistoryRetentionSettingIsInvalid = true
      } else {
        self.history.runHistoryRetentionSettingIsInvalid = true
      }
      append(
        L10n.runHistoryRetentionInvalid(isRecordSetting: isRecordSetting)
      )
      return .forever
    }
    return period
  }

  func applyStoredWorkflowSettings(
    _ settings: StoredAppSettingsSnapshot,
    workflowFiles: WorkflowFileLoadResult?
  ) {
    let storedDomainUnavailable = settings.unavailableDomains.contains(.workflowLibrary)
    if storedDomainUnavailable, workflowFiles == nil {
      markStoredSettingsDomainUnavailable(.workflowLibrary)
      return
    }
    guard !self.workflowLibrary.hasModifiedWorkflowLibrary else { return }

    if let workflowFiles {
      self.workflowLibrary.installFileLoad(workflowFiles, in: workflowFileStore?.configurationDirectoryURL)
    } else {
      self.workflowLibrary.customWorkflows = []
    }

    if storedDomainUnavailable {
      markStoredSettingsDomainUnavailable(.workflowLibrary)
    } else {
      self.workflowLibrary.workflowLibraryAvailability = .available
      self.workflowLibrary.workflowLibraryErrorPresentation = { [weak self] language in
        guard let self else { return nil }
        return self.workflowFileIssueMessage(
          workflowFiles?.issues ?? [], language: language)
      }
    }
    rebuildWorkflowLibrary()
    startWorkflowFileMonitoring()
  }

  public func reloadWorkflowFiles() async {
    guard let workflowFileStore else { return }
    self.workflowLibrary.workflowFileLoadGeneration += 1
    let generation = self.workflowLibrary.workflowFileLoadGeneration
    let result = await workflowFileStore.load()
    guard !hasBegunApplicationShutdown, generation == self.workflowLibrary.workflowFileLoadGeneration else { return }

    self.workflowLibrary.installFileLoad(
      result, in: workflowFileStore.configurationDirectoryURL, retainingInvalidWorkflows: true)
    if isWorkflowLibraryAvailable {
      self.workflowLibrary.workflowLibraryErrorPresentation = { [weak self] language in
        guard let self else { return nil }
        return self.workflowFileIssueMessage(result.issues, language: language)
      }
    } else {
      refreshUnavailableStoredSettingsDomainErrors()
    }
    rebuildWorkflowLibrary()
  }

  func workflowFileIssueMessage(_ issues: [WorkflowFileIssue], language: AppLanguage) -> String? {
    guard !issues.isEmpty else { return nil }
    let visibleIssues = issues.prefix(3).map { issue in
      "\(issue.filename): \(L10n.workflowFileIssue(issue, language: language))"
    }
    let suffix =
      issues.count > visibleIssues.count
      ? " ("
        + L10n.pluralString("workflowFile.error.moreIssues", language: language, issues.count - visibleIssues.count) + ")"
      : ""
    let heading = L10n.runText(.workflowTOMLIssuesHeading, language: language)
    return "\(heading) \(visibleIssues.joined(separator: "; "))\(suffix)"
  }

  func applyStoredInterfaceSettings(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.interfaceLanguage),
      let storedLanguage = settings.language,
      let restoredLanguage = AppLanguage(rawValue: storedLanguage)
    {
      self.applyLanguage(restoredLanguage)
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
      applyRecordHistoryVisibility(visibility)
    }

    if shouldApplyStoredSetting(.bufferOutputHotkey), let value = settings.bufferOutputHotkey,
      case .keyboardShortcut = HotkeyBindingDescriptor(storageString: value)
    {
      applyBufferOutputHotkeyBinding(HotkeyBindingDescriptor(storageString: value))
    }
    if shouldApplyStoredSetting(.recordPanelHotkey) {
      applyRecordPanelHotkeyBinding(
        HotkeyBindingDescriptor(
          storageString: settings.recordPanelHotkey
        ))
    }
  }

  func applyStoredSpeechSettings(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.preferredSpeechEngine),
      let rawEngine = settings.preferredSpeechEngine,
      let engine = PreferredSpeechEngine(rawValue: rawEngine)
    {
      applyPreferredSpeechEngine(engine)
    }

    if shouldApplyStoredSetting(.ttsModel) {
      let storedModel = settings.ttsModel?.trimmingCharacters(in: .whitespacesAndNewlines)
      applyTTSModelIdentifier(
        ttsModelOptions.contains(where: { $0.id == storedModel })
          ? (storedModel ?? defaultTTSModelIdentifier)
          : defaultTTSModelIdentifier)
    }

    if shouldApplyStoredSetting(.longRecordingModeEnabled),
      let rawLongRecordingMode = settings.longRecordingModeEnabled
    {
      applyLongRecordingModeEnabled(
        AppSettingsCodec.storedBoolean(
          rawLongRecordingMode, defaultValue: false))
    }

    if shouldApplyStoredSetting(.recordingDurationLimit),
      let rawDurationLimit = settings.recordingDurationLimit,
      let durationLimit = RecordingDurationLimit(rawValue: rawDurationLimit)
    {
      applyRecordingDurationLimit(durationLimit)
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
      self.voice.downloadedLocalSpeechModelsAvailability = .available
      self.voice.downloadedLocalSpeechModelsError = nil
      self.voice.downloadedLocalSpeechModels = settings.downloadedLocalSpeechModels.filter { modelIdentifier in
        trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier })
      }
    }
    if shouldApplyStoredModel, let model = settings.localSpeechModel {
      applyLocalSpeechModel(model)
    }
    if shouldApplyStoredSetting(.localSpeechPrewarm), let prewarm = settings.localSpeechPrewarm {
      applyLocalSpeechPrewarm(
        AppSettingsCodec.storedBoolean(
          prewarm, defaultValue: LocalSpeechSettings().prewarm))
    }
    if shouldApplyStoredSetting(.enabledSpeechModels),
      let rawValue = settings.enabledSpeechModels,
      let values = try? AppSettingsCodec.loadDownloadedLocalSpeechModels(from: rawValue)
    {
      applyEnabledSpeechModelIDs(
        Set(values).intersection(
          speechModelResourceCatalog.map(\.id)
        ))
    }
    if shouldApplyStoredSetting(.residentSpeechModels),
      let rawValue = settings.residentSpeechModels,
      let values = try? AppSettingsCodec.loadDownloadedLocalSpeechModels(from: rawValue)
    {
      applyResidentSpeechModelIDs(Set(values).intersection(self.settings.enabledSpeechModelIDs))
    }
    if shouldApplyStoredSetting(.speechModelMeasuredPeaks),
      let values = try? AppSettingsCodec.loadMeasuredSpeechModelPeaks(
        from: settings.speechModelMeasuredPeaks
      )
    {
      let catalogIDs = Set(speechModelResourceCatalog.map(\.id))
      self.voice.measuredSpeechModelPeakByteCounts = values.filter { catalogIDs.contains($0.key) }
    }
    if shouldApplyStoredSetting(.residentSpeechBudgetConfirmation) {
      let value =
        settings.residentSpeechBudgetConfirmation?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      applyResidentSpeechBudgetConfirmation(value == residentSpeechModelBudget.confirmationFingerprint ? value : nil)
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
    let storedModel = self.settings.localSpeechModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if trustedLocalSpeechModels.contains(where: { $0.id == storedModel }) {
      applyLocalSpeechModel(storedModel)
    } else {
      applyLocalSpeechModel(defaultLocalSpeechModelIdentifier)
    }
  }

  func applyStoredOpenAISettings(_ snapshot: StoredAppSettingsSnapshot) {
    do {
      let key = snapshot.openAIAPIKey
      let baseURL = snapshot.openAIBaseURL
      let model = snapshot.openAIModel
      if shouldApplyStoredSetting(SecureCredentialKey.openAIAPIKey.legacySettingKey) {
        applyLanguageModelAPIKey(key ?? "")
        settings.setCredentialAvailability(
          snapshot.openAICredentialAvailability)
      }
      if shouldApplyStoredSetting(AppSettingKey.openAIBaseURL), let baseURL {
        applyLanguageModelBaseURL(baseURL)
      }
      if shouldApplyStoredSetting(AppSettingKey.openAIModel), let model {
        applyLanguageModelIdentifier(model)
      }
      publishLanguageModelSettings()
    }
  }

  public func retryUnavailableScalarSettings(in domain: ScalarSettingsDomain) {
    if domain == .openAI {
      retryOpenAICredentialLoad()
      return
    }
    guard !hasBegunApplicationShutdown,
      settings.hasUnavailableScalarSettings(in: domain),
      !settings.isRetryingUnavailableScalarSettings(in: domain),
      let settingsStore
    else {
      return
    }

    let generation = (self.settings.scalarSettingsRetryGenerations[domain] ?? 0) + 1
    self.settings.scalarSettingsRetryGenerations[domain] = generation
    let modelSelectionGeneration = self.settings.localSpeechModelMutationGeneration
    self.settings.retryingUnavailableScalarSettingsDomains.insert(domain)
    let slot = AppModelSettingsReadTaskSlot.scalarSettingsRetry(domain)
    let taskID = UUID()
    let taskOwner = self.settings.settingsReadTaskOwner
    let task = Task { @MainActor [weak self, settingsStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.settings.scalarSettingsRetryGenerations[domain] == generation
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
          self.settings.scalarSettingsRetryGenerations[domain] == generation
        else {
          return
        }
        let localSpeechModelWasModifiedDuringRetry =
          domain == .localSpeech
          && self.settings.localSpeechModelMutationGeneration != modelSelectionGeneration
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
            if self.trustedLocalSpeechModels.contains(where: { $0.id == self.settings.localSpeechModel }) {
              legacyMigrationValues[.localSpeechModel] = self.settings.localSpeechModel
            }
          } else if let trustedLocalSpeechModelMigration,
            self.settings.localSpeechModel == trustedLocalSpeechModelMigration
          {
            legacyMigrationValues[.localSpeechModel] = trustedLocalSpeechModelMigration
          }
          self.persistLocalSpeechSettingMigrations(legacyMigrationValues)
        }
        self.settings.unavailableScalarSettingKeys.subtract(domain.settingKeys)
        if domain == .localSpeech {
          self.synchronizeLocalSpeechSettingsSource()
        }
        self.settings.retryingUnavailableScalarSettingsDomains.remove(domain)
        self.append(
          L10n.resource("run.savedSettingsAvailableAgain")
        )
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settings.scalarSettingsRetryGenerations[domain] == generation
        else {
          return
        }
        self.settings.retryingUnavailableScalarSettingsDomains.remove(domain)
        self.append(
          L10n.resource("run.savedSettingsStillUnavailable")
        )
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  public func retryOpenAICredentialLoad() {
    guard !hasBegunApplicationShutdown, !self.settings.isLoading else { return }
    let domain: ScalarSettingsDomain = .openAI
    self.settings.credentialLoadGeneration &+= 1
    let generation = self.settings.credentialLoadGeneration
    guard let settingsStore, let credentialStore else {
      self.settings.setCredentialAvailability(.inaccessible)
      self.publishLanguageModelSettings()
      return
    }

    self.settings.setCredentialAvailability(.loading)
    self.publishLanguageModelSettings()
    self.settings.retryingUnavailableScalarSettingsDomains.insert(domain)
    let slot = AppModelSettingsReadTaskSlot.scalarSettingsRetry(domain)
    let taskID = UUID()
    let taskOwner = self.settings.settingsReadTaskOwner
    let task = Task { @MainActor [weak self, settingsStore, credentialStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.settings.credentialLoadGeneration == generation
      else {
        return
      }
      do {
        let snapshot: SettingsStoreReadSnapshot
        let credential: String?

        async let settingsSnapshot = settingsStore.settingsSnapshot(forKeys: Array(domain.settingKeys))
        async let storedCredential = credentialStore.credential(for: SecureCredentialKey.openAIAPIKey)
        (snapshot, credential) = try await (settingsSnapshot, storedCredential)

        let unavailableKeys = snapshot.unavailableKeys
          .union(AppSettingsCodec.invalidScalarSettingKeys(in: snapshot.values))
          .intersection(domain.settingKeys)
        guard unavailableKeys.isEmpty else {
          throw ProviderSettingsPersistenceError.unavailableStoredSettings
        }
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settings.credentialLoadGeneration == generation
        else {
          return
        }
        let wasRestoringSettings = self.settings.isRestoringSettings
        self.settings.isRestoringSettings = true
        if let baseURL = snapshot.values[AppSettingKey.openAIBaseURL] {
          self.applyLanguageModelBaseURL(baseURL)
        }
        if let model = snapshot.values[AppSettingKey.openAIModel] {
          self.applyLanguageModelIdentifier(model)
        }
        self.applyLanguageModelAPIKey(credential ?? "")
        self.settings.isRestoringSettings = wasRestoringSettings
        self.settings.unavailableScalarSettingKeys.subtract(
          domain.settingKeys
        )
        self.settings.retryingUnavailableScalarSettingsDomains.remove(domain)
        self.settings.setCredentialAvailability(AppSettingsCodec.openAICredentialAvailability(for: credential))
        self.publishLanguageModelSettings()
        self.workflowLibraryChangedAction()
        self.append(
          L10n.resource("run.openAISettingsAvailableAgain")
        )
      } catch is CancellationError {
        return
      } catch {
        guard taskOwner.isActive(in: slot, id: taskID),
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settings.credentialLoadGeneration == generation
        else {
          return
        }
        self.settings.retryingUnavailableScalarSettingsDomains.remove(domain)
        self.settings.setCredentialAvailability(.inaccessible)
        self.publishLanguageModelSettings()
        self.workflowLibraryChangedAction()
        self.append(
          L10n.resource("run.openAISettingsStillUnavailable")
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
    let wasRestoringSettings = self.settings.isRestoringSettings
    self.settings.isRestoringSettings = true
    defer { self.settings.isRestoringSettings = wasRestoringSettings }

    switch domain {
    case .interface:
      if let rawValue = values[.interfaceLanguage],
        let recoveredLanguage = AppLanguage(rawValue: rawValue)
      {
        applyLanguage(recoveredLanguage)
      }
    case .systemClipboard:
      applyResolvedClipboardCapturePreference(
        enabled: values[.systemClipboardCaptureEnabled].flatMap(
          AppSettingsCodec.storedBooleanIfValid) ?? false
      )
      if let rawValue = values[.recordHistoryVisibility],
        let visibility = RecordHistoryVisibility(rawValue: rawValue)
      {
        applyRecordHistoryVisibility(visibility)
      }
      if let rawValue = values[.bufferOutputHotkey] {
        applyBufferOutputHotkeyBinding(HotkeyBindingDescriptor(storageString: rawValue))
      }
      if let rawValue = values[.recordPanelHotkey] {
        applyRecordPanelHotkeyBinding(HotkeyBindingDescriptor(storageString: rawValue))
      }
    case .speechRoute:
      if let rawValue = values[.preferredSpeechEngine],
        let engine = PreferredSpeechEngine(rawValue: rawValue)
      {
        applyPreferredSpeechEngine(engine)
      }
      if let modelIdentifier = values[.ttsModel],
        ttsModelOptions.contains(where: { $0.id == modelIdentifier })
      {
        applyTTSModelIdentifier(modelIdentifier)
      }
    case .localSpeech:
      if !preservingLocalSpeechModel, let model = values[.localSpeechModel] {
        applyLocalSpeechModel(model)
      }
      if let rawValue = values[.localSpeechPrewarm],
        let value = AppSettingsCodec.storedBooleanIfValid(rawValue)
      {
        applyLocalSpeechPrewarm(value)
      }
      normalizeTrustedLocalSpeechSelection()
    case .openAI:

      if let baseURL = values[AppSettingKey.openAIBaseURL] {
        applyLanguageModelBaseURL(baseURL)
      }
      if let model = values[AppSettingKey.openAIModel] {
        applyLanguageModelIdentifier(model)
      }
    case .input:
      if let rawValue = values[.longRecordingModeEnabled],
        let value = AppSettingsCodec.storedBooleanIfValid(rawValue)
      {
        applyLongRecordingModeEnabled(value)
      }
      if let rawValue = values[.recordingDurationLimit],
        let value = RecordingDurationLimit(rawValue: rawValue)
      {
        applyRecordingDurationLimit(value)
      }
    }
  }

  func applyStoredVocabularySettings(_ settings: StoredAppSettingsSnapshot) {
    if settings.unavailableDomains.contains(.vocabularyRules) {
      markStoredSettingsDomainUnavailable(.vocabularyRules)
      return
    }
    self.vocabulary.availability = .available
    self.vocabulary.error = nil
    if shouldApplyStoredSetting(Self.vocabularyRulesSettingKey) {
      vocabulary.restore(collections: settings.vocabularyCollections, bindings: settings.vocabularyBindings)
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
    self.workflowLibrary.workflowLibraryAvailability == .available
  }

  public var areDownloadedLocalSpeechModelsAvailable: Bool {
    self.voice.downloadedLocalSpeechModelsAvailability == .available
  }

  public var areVocabularyRulesAvailable: Bool {
    self.vocabulary.availability == .available
  }

  private func markStoredSettingsDomainUnavailable(_ domain: StoredSettingsDomain) {
    switch domain {
    case .workflowLibrary:
      self.workflowLibrary.workflowLibraryAvailability = .unavailable
    case .downloadedModelMetadata:
      self.voice.downloadedLocalSpeechModelsAvailability = .unavailable
    case .vocabularyRules:
      self.vocabulary.availability = .unavailable
      vocabularyRuleSource.markUnavailable(
        reason: "Stored vocabulary settings could not be decoded safely."
      )
    }
    refreshUnavailableStoredSettingsDomainErrors()
  }

  func refreshUnavailableStoredSettingsDomainErrors() {
    if self.workflowLibrary.workflowLibraryAvailability == .unavailable {
      self.workflowLibrary.workflowLibraryErrorPresentation = { [weak self] language in
        guard let self else { return nil }
        return self.unavailableStoredSettingsDomainMessage(.workflowLibrary, language: language)
      }
    }
    if self.voice.downloadedLocalSpeechModelsAvailability == .unavailable {
      self.voice.downloadedLocalSpeechModelsError = unavailableStoredSettingsDomainMessage(
        .downloadedModelMetadata
      )
    }
    if self.vocabulary.availability == .unavailable {
      self.vocabulary.error = unavailableStoredSettingsDomainMessage(.vocabularyRules)
    }
  }

  private func unavailableStoredSettingsDomainMessage(_ domain: StoredSettingsDomain, language: AppLanguage? = nil) -> String {
    switch domain {
    case .workflowLibrary:
      L10n.resource("AppModel.SettingsPersistence.The.saved.workflow.library.could.not.be.loaded.Editing.stays.disabled.to.protect.the").string(
        for: language ?? self.settings.language)
    case .downloadedModelMetadata:
      L10n.resource("AppModel.SettingsPersistence.Downloaded.local.model.metadata.could.not.be.loaded.Rill.will.not.overwrite.it.until").string(
        for: language ?? self.settings.language)
    case .vocabularyRules:
      L10n.resource("AppModel.SettingsPersistence.The.saved.vocabulary.rules.could.not.be.loaded.Editing.stays.disabled.to.protect.the").string(
        for: language ?? self.settings.language)
    }
  }

  public func retryUnavailableStoredSettingsDomains() {
    guard !hasBegunApplicationShutdown,
      !self.settings.isLoading,
      !self.settings.isRetryingUnavailableSettingsDomains
    else {
      return
    }
    let retryWorkflowLibrary = self.workflowLibrary.workflowLibraryAvailability == .unavailable
    let retryDownloadedModelMetadata = self.voice.downloadedLocalSpeechModelsAvailability == .unavailable
    let retryVocabularyRules = self.vocabulary.availability == .unavailable
    guard retryWorkflowLibrary || retryDownloadedModelMetadata || retryVocabularyRules else {
      return
    }
    guard let settingsStore else {
      refreshUnavailableStoredSettingsDomainErrors()
      return
    }

    self.settings.unavailableSettingsDomainRetryGeneration += 1
    let generation = self.settings.unavailableSettingsDomainRetryGeneration
    self.settings.isRetryingUnavailableSettingsDomains = true
    let slot = AppModelSettingsReadTaskSlot.storedSettingsDomainsRetry
    let taskID = UUID()
    let taskOwner = self.settings.settingsReadTaskOwner
    let workflowFileStore = self.workflowFileStore
    let task = Task {
      @MainActor [weak self, settingsStore, workflowFileStore, taskOwner] in
      defer { taskOwner.finish(in: slot, id: taskID) }
      guard let self,
        taskOwner.isActive(in: slot, id: taskID),
        !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.settings.unavailableSettingsDomainRetryGeneration == generation
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
          self.settings.unavailableSettingsDomainRetryGeneration == generation
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
          self.settings.unavailableSettingsDomainRetryGeneration == generation
        else {
          return
        }
        self.settings.isRetryingUnavailableSettingsDomains = false
        self.refreshUnavailableStoredSettingsDomainErrors()
        self.append(
          L10n.resource("run.protectedSettingsStillUnavailable")
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
    let wasRestoringSettings = self.settings.isRestoringSettings
    self.settings.isRestoringSettings = true
    defer {
      self.settings.isRestoringSettings = wasRestoringSettings
      self.settings.isRetryingUnavailableSettingsDomains = false
      refreshUnavailableStoredSettingsDomainErrors()
    }

    var recoveredAnyDomain = false
    if retryWorkflowLibrary {
      guard let workflowFiles = recovered.workflowFiles else { return }
      self.workflowLibrary.installFileLoad(workflowFiles, in: workflowFileStore?.configurationDirectoryURL)
      self.workflowLibrary.workflowLibraryAvailability = .available
      self.workflowLibrary.workflowLibraryErrorPresentation = { [weak self] language in
        guard let self else { return nil }
        return self.workflowFileIssueMessage(
          workflowFiles.issues, language: language)
      }
      rebuildWorkflowLibrary()
      recoveredAnyDomain = true
    }
    if retryDownloadedModelMetadata,
      let recoveredModels = recovered.downloadedLocalSpeechModels
    {
      self.voice.downloadedLocalSpeechModels =
        trustedLocalSpeechModels.isEmpty
        ? recoveredModels
        : recoveredModels.filter { modelIdentifier in
          trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier })
        }
      self.voice.downloadedLocalSpeechModelsAvailability = .available
      self.voice.downloadedLocalSpeechModelsError = nil
      recoveredAnyDomain = true
    }
    if retryVocabularyRules, let vocabularyRules = recovered.vocabularyRules {
      self.vocabulary.availability = .available
      self.vocabulary.error = nil
      vocabulary.restoreLegacyRules(vocabularyRules)
      recoveredAnyDomain = true
    }

    if recoveredAnyDomain {
      append(
        L10n.resource("run.protectedSettingsReloaded")
      )
    }
  }

  func applyStoredPrivacySettings(_ settings: StoredAppSettingsSnapshot) {
    applyPrivacyPolicySettings(settings.privacyPolicySettings)
    self.settings.isLoadingPrivacySettings = false
    if settings.privacySettingsWereInvalid {
      self.settings.privacySettingsLoadFailure = L10n.resource("run.privacySettingsDamaged")
      privacySettingsSource.markUnavailable(reason: "Privacy settings are damaged.")
    } else {
      self.settings.privacySettingsLoadFailure = nil
      privacySettingsSource.update(self.settings.privacyPolicySettings)
    }
  }

  func loadDiagnostics() {
    guard !hasBegunApplicationShutdown else { return }
    guard let diagnosticRepository else {
      self.history.diagnosticsLoadState = .loaded
      return
    }
    self.history.diagnosticsLoadGeneration += 1
    let generation = self.history.diagnosticsLoadGeneration
    self.history.diagnosticsLoadState = .loading
    let taskID = UUID()
    let task = Task { @MainActor [weak self, diagnosticRepository] in
      guard let self else { return }
      defer { self.finishHistoryProjectionLoadTask(id: taskID) }
      guard !Task.isCancelled,
        !self.hasBegunApplicationShutdown,
        self.history.diagnosticsLoadGeneration == generation
      else {
        return
      }
      do {
        let stored = try await diagnosticRepository.events(
          matching: DiagnosticQuery(limit: 50)
        )
        guard !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.history.diagnosticsLoadGeneration == generation
        else {
          return
        }
        self.history.diagnosticEvents = Self.sortedDiagnosticEvents(stored)
        self.history.diagnosticsLoadState = .loaded
      } catch {
        guard !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.history.diagnosticsLoadGeneration == generation
        else {
          return
        }
        self.history.diagnosticsLoadState = .failed
        self.append(
          L10n.resource("run.diagnosticsRepositoryUnavailable")
        )
      }
    }
    self.history.historyProjectionLoadTasks[taskID] = task
  }

  func persistPreferredSpeechEnginePreference() {
    persistStringSetting(
      self.settings.preferredSpeechEngine.rawValue,
      for: .preferredSpeechEngine
    )
  }

  func persistLongRecordingModePreference() {
    persistStringSetting(
      self.settings.longRecordingModeEnabled ? "true" : "false",
      for: .longRecordingModeEnabled
    )
  }

  func persistRecordingDurationLimitPreference() {
    persistStringSetting(
      self.settings.recordingDurationLimit.rawValue,
      for: .recordingDurationLimit
    )
  }

  func persistLanguagePreference() {
    persistStringSetting(
      self.settings.language.rawValue,
      for: .interfaceLanguage
    )
  }

  func persistRecordPanelHotkeyPreference() {
    persistStringSetting(
      self.settings.recordPanelHotkeyBinding.storageString,
      for: .recordPanelHotkey
    )
  }

  func persistClipboardCaptureEnabledPreference() {
    persistStringSetting(
      self.settings.systemClipboardCaptureEnabled ? "true" : "false",
      for: .systemClipboardCaptureEnabled
    )
  }

  func persistRecordHistoryVisibilityPreference() {
    persistStringSetting(
      self.settings.recordHistoryVisibility.rawValue,
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
    guard !self.settings.isRestoringSettings else { return }
    guard !self.settings.unavailableScalarSettingKeys.contains(key) else { return }
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
    let isLanguageModelCredential = credentialKey == .openAIAPIKey
    markSettingModifiedDuringInitialLoad(taskKey)
    guard !self.settings.isRestoringSettings else { return }
    guard let credentialStore else {
      if isLanguageModelCredential {
        self.settings.setCredentialAvailability(.inaccessible)
        self.publishLanguageModelSettings()
      }
      append(
        L10n.resource("run.credentialSaveFailed")
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
        if isLanguageModelCredential {
          self.settings.setCredentialAvailability(AppSettingsCodec.openAICredentialAvailability(for: value))
          self.publishLanguageModelSettings()
          self.workflowLibraryChangedAction()
        }
      case .failure(is CancellationError):
        break
      case .failure:
        if isLanguageModelCredential {
          self.settings.setCredentialAvailability(.inaccessible)
          self.publishLanguageModelSettings()
          self.workflowLibraryChangedAction()
        }
        self.append(
          L10n.resource("run.credentialSaveFailed")
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
    settings.submit(key: key, category: category, debounce: debounceDuration, operation: operation) { [weak self] in
      self?.appendSettingsSaveFailureEvent()
    }
  }

  public func retryUnsavedSettingsSave() {
    settings.retry { [weak self] in self?.appendSettingsSaveFailureEvent() }
  }

  func appendSettingsSaveFailureEvent() {
    append(
      L10n.resource("run.settingsSaveFailedRetry")
    )
  }

  public func flushPendingPersistenceWrites() async {
    await persistenceWrites.flush()
  }

  /// The global hotkey producer must not become available until the initial
  /// durable settings snapshot has atomically selected its workflow, speech
  /// engine, and hold/toggle mode. Manual UI remains usable while this waits.
  public func waitForInitialVoiceConfiguration() async {
    await self.settings.settingsReadTaskOwner.waitForActiveTask(in: .initialSettingsLoad)
  }

  public func stopSettingsReadTasksForApplicationShutdown() async {
    beginApplicationShutdown()
    self.workflowLibrary.workflowFileMonitorTask?.cancel()
    await self.workflowLibrary.workflowFileMonitorTask?.value
    self.workflowLibrary.workflowFileMonitorTask = nil
    self.settings.settingsLoadGeneration &+= 1
    do { self.settings.credentialLoadGeneration &+= 1 }
    for domain in ScalarSettingsDomain.allCases {
      self.settings.scalarSettingsRetryGenerations[domain, default: 0] &+= 1
    }
    self.settings.unavailableSettingsDomainRetryGeneration &+= 1
    self.settings.isLoading = false
    self.settings.isLoadingPrivacySettings = false
    self.settings.isRetryingUnavailableSettingsDomains = false
    self.settings.settingsKeysModifiedDuringInitialLoad.removeAll()
    self.voice.shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = false
    self.settings.retryingUnavailableScalarSettingsDomains.removeAll()
    do {
      if self.settings.credentialAvailability() == .loading {
        self.settings.setCredentialAvailability(.inaccessible)
      }
      languageModelSettingsSource.update(nil)
    }
    await self.settings.settingsReadTaskOwner.cancelAllAndDrain()
    await settings.waitForOpenAIVerificationTasks()
    await workflowLibrary.waitForWorkflowExplanationTasks()
    await corpusArchive.waitForOperation()
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
      prewarm: self.settings.localSpeechPrewarm,
      enabledModelIDs: self.settings.enabledSpeechModelIDs,
      residentModelIDs: self.settings.residentSpeechModelIDs,
      residentBudgetConfirmation: self.settings.residentSpeechBudgetConfirmation
    )
  }

  func publishCurrentLocalSpeechSettingsToRuntime() {
    guard !self.settings.isLoading,
      !self.settings.isRestoringSettings,
      !settings.hasUnavailableScalarSettings(in: .localSpeech)
    else {
      return
    }
    localSpeechSettingsSource.update(currentLocalSpeechSettings())
  }

  func synchronizeLocalSpeechSettingsSource() {
    guard !settings.hasUnavailableScalarSettings(in: .localSpeech) else {
      localSpeechSettingsSource.markUnavailable()
      return
    }
    localSpeechSettingsSource.update(currentLocalSpeechSettings())
  }

  func setPrivacyCloudConfirmationRequired(_ isRequired: Bool) {
    guard privacySettingsAreEditable else { return }
    var policy = self.settings.privacyPolicySettings
    policy.cloudConfirmationRequired = isRequired
    applyPrivacyPolicySettings(policy)
  }

  @discardableResult
  public func grantCloudProcessingAuthorization(
    _ authorization: CloudProcessingAuthorization
  ) -> Bool {
    guard privacySettingsAreEditable else { return false }
    var policy = self.settings.privacyPolicySettings
    policy.cloudProcessingAuthorizations.removeAll {
      $0.workflowID == authorization.workflowID
    }
    policy.cloudProcessingAuthorizations.append(authorization)
    applyPrivacyPolicySettings(policy)
    return true
  }

  func revokeCloudProcessingAuthorization(_ authorizationID: UUID) {
    guard privacySettingsAreEditable else { return }
    var policy = self.settings.privacyPolicySettings
    policy.cloudProcessingAuthorizations.removeAll { $0.id == authorizationID }
    applyPrivacyPolicySettings(policy)
  }

  func revokeAllCloudProcessingAuthorizations() {
    guard privacySettingsAreEditable else { return }
    guard !self.settings.privacyPolicySettings.cloudProcessingAuthorizations.isEmpty else { return }
    var policy = self.settings.privacyPolicySettings
    policy.cloudProcessingAuthorizations = []
    applyPrivacyPolicySettings(policy)
  }

  func setPrivacySecureInputConservativeMode(_ isEnabled: Bool) {
    guard privacySettingsAreEditable else { return }
    var policy = self.settings.privacyPolicySettings
    policy.secureInputConservativeMode = isEnabled
    applyPrivacyPolicySettings(policy)
  }

  func setPrivacyHistoryPreviewMode(_ mode: PrivacyHistoryPreviewMode) {
    guard privacySettingsAreEditable else { return }
    guard self.settings.privacyPolicySettings.historyPreviewMode != mode else { return }
    var policy = self.settings.privacyPolicySettings
    policy.historyPreviewMode = mode
    applyPrivacyPolicySettings(policy)
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
    var policy = self.settings.privacyPolicySettings
    policy.sensitiveAppRules = try SensitiveAppRule.mergingRecommendedDefaults(
      with: policy.sensitiveAppRules + [rule]
    )
    applyPrivacyPolicySettings(policy)
  }

  func editSensitiveAppRule(
    _ ruleID: UUID,
    bundleIdentifier: String,
    applicationName: String?
  ) throws {
    try ensurePrivacySettingsAreEditable()
    guard let index = self.settings.privacyPolicySettings.sensitiveAppRules.firstIndex(where: { $0.id == ruleID })
    else {
      throw SensitiveAppRuleValidationError.ruleNotFound
    }
    guard !self.settings.privacyPolicySettings.sensitiveAppRules[index].isRecommended else {
      throw SensitiveAppRuleValidationError.recommendedRuleCannotBeEdited
    }

    var policy = self.settings.privacyPolicySettings
    policy.sensitiveAppRules[index].bundleIdentifier = bundleIdentifier
    policy.sensitiveAppRules[index].applicationName = applicationName
    policy.sensitiveAppRules = try SensitiveAppRule.mergingRecommendedDefaults(
      with: policy.sensitiveAppRules
    )
    applyPrivacyPolicySettings(policy)
  }

  func deleteSensitiveAppRule(_ ruleID: UUID) throws {
    try ensurePrivacySettingsAreEditable()
    guard let rule = self.settings.privacyPolicySettings.sensitiveAppRules.first(where: { $0.id == ruleID })
    else {
      throw SensitiveAppRuleValidationError.ruleNotFound
    }
    guard !rule.isRecommended else {
      throw SensitiveAppRuleValidationError.recommendedRuleCannotBeEdited
    }
    var policy = self.settings.privacyPolicySettings
    policy.sensitiveAppRules.removeAll { $0.id == ruleID }
    applyPrivacyPolicySettings(policy)
  }

  func restoreRecommendedSensitiveAppRules() throws {
    try ensurePrivacySettingsAreEditable()
    var policy = self.settings.privacyPolicySettings
    policy.sensitiveAppRules = try SensitiveAppRule.restoringRecommendedDefaults(
      whileKeepingCustomRules: policy.sensitiveAppRules
    )
    applyPrivacyPolicySettings(policy)
  }

  private func updateSensitiveAppRule(_ ruleID: UUID, mutate: (inout SensitiveAppRule) -> Void) {
    guard privacySettingsAreEditable else { return }
    guard let index = self.settings.privacyPolicySettings.sensitiveAppRules.firstIndex(where: { $0.id == ruleID })
    else { return }
    var policy = self.settings.privacyPolicySettings
    mutate(&policy.sensitiveAppRules[index])
    applyPrivacyPolicySettings(policy)
  }

  private var privacySettingsAreEditable: Bool {
    !hasBegunApplicationShutdown
      && !self.settings.isLoadingPrivacySettings
      && self.settings.privacySettingsLoadFailure == nil
  }

  private func ensurePrivacySettingsAreEditable() throws {
    if hasBegunApplicationShutdown {
      throw PrivacyPolicySettingsSourceError.notReady
    }
    if self.settings.isLoadingPrivacySettings {
      throw PrivacyPolicySettingsSourceError.notReady
    }
    if let error = settings.privacySettingsLoadError {
      throw PrivacyPolicySettingsSourceError.unavailable(error)
    }
  }

  func persistPrivacyPolicySettings() {
    settings.persistPrivacyPolicySettings { [weak self] in
      self?.append(
        L10n.resource("run.privacySaveFailedRetry"))
    }
  }

  func retryPrivacySettingsSave() {
    persistPrivacyPolicySettings()
  }

  func retryPrivacySettingsLoad() {
    guard !hasBegunApplicationShutdown, !self.settings.isLoadingPrivacySettings else { return }
    self.settings.isLoadingPrivacySettings = true
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
    let taskOwner = self.settings.settingsReadTaskOwner
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
        self.settings.isRestoringSettings = true
        self.applyPrivacyPolicySettings(policy)
        self.settings.isRestoringSettings = false
        self.settings.isLoadingPrivacySettings = false
        self.settings.privacySettingsLoadFailure = nil
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
        self.settings.isLoadingPrivacySettings = false
        self.settings.privacySettingsLoadFailure = L10n.resource("run.privacyLoadFailedRepairStorage")
        self.privacySettingsSource.markUnavailable(
          reason: "Privacy settings could not be loaded."
        )
        self.workflowLibraryChangedAction()
      }
    }
    taskOwner.replaceActive(in: slot, id: taskID, with: task)
  }

  func resetPrivacySettingsToSafeDefaults() {
    guard !hasBegunApplicationShutdown, !self.settings.isLoadingPrivacySettings else { return }
    let defaults = PrivacyPolicySettings.defaults
    self.settings.isLoadingPrivacySettings = false
    self.settings.privacySettingsLoadFailure = nil
    self.settings.isRestoringSettings = true
    applyPrivacyPolicySettings(defaults)
    self.settings.isRestoringSettings = false
    privacySettingsSource.update(defaults)
    workflowLibraryChangedAction()
    persistPrivacyPolicySettings()
  }

  func persistDownloadedLocalSpeechModels() {
    markSettingModifiedDuringInitialLoad(.localSpeechDownloadedModels)
    guard !self.settings.isRestoringSettings, areDownloadedLocalSpeechModelsAvailable else { return }
    let modelIdentifiers = self.voice.downloadedLocalSpeechModels

    persistRetryableSettingsStoreWrite(
      for: .localSpeechDownloadedModels,
      category: .speech
    ) { settingsStore in
      if modelIdentifiers.isEmpty {
        try await settingsStore.removeValue(forKey: .localSpeechDownloadedModels)
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(modelIdentifiers)
        try await settingsStore.setString(
          String(decoding: data, as: UTF8.self),
          forKey: .localSpeechDownloadedModels
        )
      }
    }
  }

  func recordDownloadedLocalSpeechModel(_ modelIdentifier: String) {
    guard !hasBegunApplicationShutdown,
      !self.settings.isLoading,
      !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      areDownloadedLocalSpeechModelsAvailable,
      trustedLocalSpeechModels.isEmpty
        || trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier }),
      !self.voice.downloadedLocalSpeechModels.contains(modelIdentifier)
    else {
      return
    }
    self.voice.downloadedLocalSpeechModels.append(modelIdentifier)
    self.voice.downloadedLocalSpeechModels.sort()
    persistDownloadedLocalSpeechModels()
    synchronizeWakeWordResourceWithLocalSpeechModel()
  }
}
