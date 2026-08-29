import AppKit
import Foundation
import RillCore
import RillRuntime

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
        .recordMergeSimilar,
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
    case .openAI: "OpenAI"
    case .input: "input"
    }
  }

  private var simplifiedChineseName: String {
    switch self {
    case .interface: "界面"
    case .systemClipboard: "剪贴板"
    case .speechRoute: "语音路由"
    case .localSpeech: "本地语音"
    case .openAI: "OpenAI"
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
        english: "The OpenAI credential could not be read from secure storage.",
        simplifiedChinese: "无法从安全存储读取 OpenAI 凭据。"
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

struct StoredAppSettingsSnapshot {
  let persistentSettingsStoreWasAvailable: Bool
  let unavailableSettingKeys: Set<AppSettingKey>
  let legacyLocalSpeechMigrationValues: [AppSettingKey: String]
  let language: String?
  let customWorkflows: [WorkflowDefinition]
  let workflowCustomizations: [WorkflowCustomization]
  let workflowLibraryNeedsMigration: Bool
  let workflowEnabledStates: [UUID: Bool]
  let systemClipboardCaptureEnabled: String?
  let recordMergeSimilar: String?
  let recordHistoryVisibility: String?
  let recordPanelHotkey: String?
  let preferredSpeechEngine: String?
  let ttsModel: String?
  let localSpeechModel: String?
  let downloadedLocalSpeechModels: [String]
  let legacyWhisperKitCustomModel: String?
  let legacyWhisperKitModelRepo: String?
  let legacyWhisperKitModelToken: String?
  let legacyWhisperKitModelFolder: String?
  let legacyWhisperKitLanguage: String?
  let legacyWhisperKitDownloadIfNeeded: String?
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

private struct RecoverableStoredSettingsDomains: Sendable {
  let customWorkflows: [WorkflowDefinition]?
  let workflowFiles: WorkflowFileLoadResult?
  let workflowEnabledStates: [UUID: Bool]?
  let downloadedLocalSpeechModels: [String]?
  let vocabularyRules: [VocabularyRule]?
}

private enum StoredSettingsCollectionValidationError: Error {
  case invalidIdentifier
  case duplicateIdentifier
}

private enum WorkflowFileMigrationError: Error {
  case verificationFailed
}

private struct LegacyLocalSpeechSettingResolution {
  let value: String?
  let usedLegacyValue: Bool
  let isUnavailable: Bool
}

extension AppModel {
  static let scalarSettingsKeys = Set(
    ScalarSettingsDomain.allCases.flatMap(\.settingKeys)
  )

  static func loadAndMigrateWorkflowFiles(
    from workflowFileStore: (any WorkflowFileStore)?,
    legacyWorkflows: [WorkflowDefinition],
    enabledStates: [UUID: Bool]
  ) async -> InitialWorkflowFileLoad? {
    guard let workflowFileStore else { return nil }
    var initial = await workflowFileStore.load()
    guard
      initial.discoveredFileCount == 0,
      initial.issues.isEmpty,
      !legacyWorkflows.isEmpty
    else {
      return InitialWorkflowFileLoad(
        result: initial,
        didMigrateLegacyWorkflows: false
      )
    }

    var createdFiles: [URL] = []
    do {
      for workflow in legacyWorkflows.sorted(by: {
        $0.id.uuidString < $1.id.uuidString
      }) {
        let fileURL = try await workflowFileStore.save(
          workflow: normalizeCustomWorkflow(workflow),
          isEnabled: enabledStates[workflow.id] ?? true,
          replacing: nil
        )
        createdFiles.append(fileURL)
      }
      initial = await workflowFileStore.load()
      guard
        initial.issues.isEmpty,
        initial.records.count == legacyWorkflows.count
      else {
        throw WorkflowFileMigrationError.verificationFailed
      }
      return InitialWorkflowFileLoad(
        result: initial,
        didMigrateLegacyWorkflows: true
      )
    } catch {
      for fileURL in createdFiles {
        try? await workflowFileStore.delete(fileURL: fileURL)
      }
      initial.issues.append(
        WorkflowFileIssue(
          filename: workflowFileStore.configurationDirectoryURL.lastPathComponent,
          message:
            "Existing workflows could not be migrated to TOML; the legacy library remains active."
        )
      )
      return InitialWorkflowFileLoad(
        result: initial,
        didMigrateLegacyWorkflows: false
      )
    }
  }

  static func retireLegacyWorkflowDefinitions(
    in settingsStore: (any SettingsStore)?,
    preserving customizations: [WorkflowCustomization]
  ) async {
    guard let settingsStore else { return }
    let document = WorkflowLibraryDocument(
      customWorkflows: [],
      customizations: customizations
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(document) else { return }
    do {
      try await settingsStore.setString(
        String(decoding: data, as: UTF8.self),
        forKey: workflowLibrarySettingKey
      )
      try await settingsStore.removeValue(forKey: .customWorkflows)
    } catch {
      // TOML already verified successfully and remains authoritative. Retaining
      // the legacy payload is a safe, retryable cleanup failure.
    }
  }

  private static let privacySettingKeys: Set<AppSettingKey> = [
    .privacySensitiveAppRules,
    .privacyCloudConfirmationRequired,
    .privacyCloudProcessingAuthorizations,
    .privacyHistoryPreviewMode,
    .privacySecureInputConservativeMode,
  ]

  private static let openAIConfigurationSettingKeys: Set<AppSettingKey> = [
    .openAIBaseURL,
    .openAIModel,
  ]

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
        let settings = try await Self.loadStoredAppSettings(
          from: settingsStore,
          credentialStore: credentialStore,
          requiresPersistentPrivacySettings: requiresPersistentPrivacySettings
        )
        let workflowFiles = await Self.loadAndMigrateWorkflowFiles(
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
          await Self.retireLegacyWorkflowDefinitions(
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

  private static func resolveLegacyLocalSpeechSetting(
    currentKey: AppSettingKey,
    legacyKey: AppSettingKey,
    in snapshot: SettingsStoreReadSnapshot
  ) -> LegacyLocalSpeechSettingResolution {
    if snapshot.unavailableKeys.contains(currentKey) {
      return LegacyLocalSpeechSettingResolution(
        value: nil,
        usedLegacyValue: false,
        isUnavailable: true
      )
    }
    if let currentValue = snapshot.values[currentKey] {
      return LegacyLocalSpeechSettingResolution(
        value: currentValue,
        usedLegacyValue: false,
        isUnavailable: false
      )
    }
    if snapshot.unavailableKeys.contains(legacyKey) {
      return LegacyLocalSpeechSettingResolution(
        value: nil,
        usedLegacyValue: false,
        isUnavailable: true
      )
    }
    return LegacyLocalSpeechSettingResolution(
      value: snapshot.values[legacyKey],
      usedLegacyValue: snapshot.values[legacyKey] != nil,
      isUnavailable: false
    )
  }

  static func loadStoredAppSettings(
    from settingsStore: (any SettingsStore)?,
    credentialStore: (any SecureCredentialStore)? = nil,
    requiresPersistentPrivacySettings: Bool = false
  ) async throws -> StoredAppSettingsSnapshot {
    let storedSnapshot: SettingsStoreReadSnapshot
    if let settingsStore {
      storedSnapshot = try await settingsStore.settingsSnapshot(
        forKeys: Self.settingsLoadKeys
      )
    } else {
      storedSnapshot = SettingsStoreReadSnapshot(
        values: [:],
        unavailableKeys: Set(Self.settingsLoadKeys)
      )
    }
    var storedSettings = storedSnapshot.values
    var unavailableSettingKeys = storedSnapshot.unavailableKeys
    var legacyLocalSpeechMigrationValues: [AppSettingKey: String] = [:]
    if storedSettings[.preferredSpeechEngine] == "cloud" {
      storedSettings[.preferredSpeechEngine] = PreferredSpeechEngine.local.rawValue
      legacyLocalSpeechMigrationValues[.preferredSpeechEngine] =
        PreferredSpeechEngine.local.rawValue
    }
    let legacyLocalSpeechKeyPairs: [(AppSettingKey, AppSettingKey)] = [
      (AppSettingKey.localSpeechModel, .legacyWhisperKitModel),
      (.localSpeechDownloadedModels, .legacyWhisperKitDownloadedModels),
      (.localSpeechPrewarm, .legacyWhisperKitPrewarm),
    ]
    for (currentKey, legacyKey) in legacyLocalSpeechKeyPairs {
      let resolution = Self.resolveLegacyLocalSpeechSetting(
        currentKey: currentKey,
        legacyKey: legacyKey,
        in: storedSnapshot
      )
      unavailableSettingKeys.remove(currentKey)
      unavailableSettingKeys.remove(legacyKey)
      if resolution.isUnavailable {
        storedSettings.removeValue(forKey: currentKey)
        unavailableSettingKeys.insert(currentKey)
      } else if let value = resolution.value {
        storedSettings[currentKey] = value
        if resolution.usedLegacyValue {
          legacyLocalSpeechMigrationValues[currentKey] = value
        }
      } else {
        storedSettings.removeValue(forKey: currentKey)
      }
    }
    unavailableSettingKeys.formUnion(
      Self.invalidScalarSettingKeys(in: storedSettings)
    )
    for key in unavailableSettingKeys {
      legacyLocalSpeechMigrationValues.removeValue(forKey: key)
    }
    var loadWarnings: [StoredSettingsLoadWarning] = []
    var unavailableDomains: Set<StoredSettingsDomain> = []
    if !unavailableSettingKeys.isEmpty {
      loadWarnings.append(.storedValuesUnavailable)
    }
    if !unavailableSettingKeys.isDisjoint(with: [
      .customWorkflows,
      Self.workflowLibrarySettingKey,
      .workflowEnabledStates,
    ]) {
      unavailableDomains.insert(.workflowLibrary)
    }
    if unavailableSettingKeys.contains(.localSpeechDownloadedModels) {
      unavailableDomains.insert(.downloadedModelMetadata)
    }
    if unavailableSettingKeys.contains(Self.vocabularyRulesSettingKey)
      || unavailableSettingKeys.contains(Self.vocabularyLibrarySettingKey)
    {
      unavailableDomains.insert(.vocabularyRules)
    }

    let customWorkflows: [WorkflowDefinition]
    let workflowCustomizations: [WorkflowCustomization]
    do {
      if let library = try Self.loadWorkflowLibrary(
        from: storedSettings[Self.workflowLibrarySettingKey]
      ) {
        customWorkflows = library.customWorkflows
        workflowCustomizations = library.customizations
      } else {
        customWorkflows = try Self.loadCustomWorkflows(from: storedSettings[.customWorkflows])
        workflowCustomizations = []
      }
    } catch {
      customWorkflows = []
      workflowCustomizations = []
      loadWarnings.append(.customWorkflows)
      unavailableDomains.insert(.workflowLibrary)
    }

    let workflowEnabledStates: [UUID: Bool]
    do {
      workflowEnabledStates = try Self.loadWorkflowEnabledStates(
        from: storedSettings[.workflowEnabledStates])
    } catch {
      workflowEnabledStates = [:]
      loadWarnings.append(.workflowEnabledStates)
      unavailableDomains.insert(.workflowLibrary)
    }

    let downloadedLocalSpeechModels: [String]
    do {
      downloadedLocalSpeechModels = try Self.loadDownloadedLocalSpeechModels(
        from: storedSettings[.localSpeechDownloadedModels]
      )
    } catch {
      downloadedLocalSpeechModels = []
      legacyLocalSpeechMigrationValues.removeValue(forKey: .localSpeechDownloadedModels)
      loadWarnings.append(.downloadedModelMetadata)
      unavailableDomains.insert(.downloadedModelMetadata)
    }

    let vocabularyRules: [VocabularyRule]
    let vocabularyCollections: [VocabularyCollection]
    let vocabularyBindings: [VocabularyCollectionBinding]
    do {
      if let library = try Self.loadVocabularyLibrary(
        from: storedSettings[Self.vocabularyLibrarySettingKey]
      ) {
        vocabularyCollections = library.collections
        vocabularyRules = library.collections.flatMap { collection in
          collection.entries.map { $0.legacyRule() }
        }
        vocabularyBindings =
          workflowCustomizations.lazy.compactMap(\.vocabularyBindings).first
          ?? customWorkflows.lazy.map(\.plan.setup.vocabularyBindings).first {
            !$0.isEmpty
          }
          ?? library.collections.map { collection in
            VocabularyCollectionBinding(collectionID: collection.id)
          }
      } else {
        vocabularyRules = try Self.loadVocabularyRules(
          from: storedSettings[Self.vocabularyRulesSettingKey])
        let migration = VocabularyLegacyMigrator.migrate(vocabularyRules)
        vocabularyCollections = migration.collections
        vocabularyBindings = migration.bindings
      }
    } catch {
      vocabularyRules = []
      vocabularyCollections = [.personal()]
      vocabularyBindings = [
        VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID),
      ]
      loadWarnings.append(.vocabularyRules)
      unavailableDomains.insert(.vocabularyRules)
    }

    let privacyPolicySettings: PrivacyPolicySettings
    let privacySettingsWereInvalid: Bool
    do {
      guard settingsStore != nil || !requiresPersistentPrivacySettings else {
        throw PrivacyPolicySettingsSourceError.unavailable(
          "Persistent settings storage is unavailable."
        )
      }
      guard unavailableSettingKeys.isDisjoint(with: Self.privacySettingKeys) else {
        throw PrivacyPolicySettingsSourceError.unavailable(
          "A protected privacy setting is unavailable."
        )
      }
      privacyPolicySettings = try Self.decodePrivacyPolicySettings(from: storedSettings)
      privacySettingsWereInvalid = false
    } catch {
      privacyPolicySettings = .defaults
      privacySettingsWereInvalid = true
    }

    let openAIAPIKey: String?
    let openAICredentialAvailability: OpenAICredentialAvailability
    if let credentialStore {
      do {
        openAIAPIKey = try await credentialStore.credential(for: .openAIAPIKey)
        openAICredentialAvailability =
          unavailableSettingKeys.isDisjoint(
            with: Self.openAIConfigurationSettingKeys
          )
          ? Self.openAICredentialAvailability(for: openAIAPIKey)
          : .inaccessible
      } catch {
        openAIAPIKey = nil
        openAICredentialAvailability = .inaccessible
        loadWarnings.append(.openAICredential)
      }
    } else {
      openAIAPIKey = nil
      openAICredentialAvailability = .inaccessible
    }

    return StoredAppSettingsSnapshot(
      persistentSettingsStoreWasAvailable: settingsStore != nil,
      unavailableSettingKeys: unavailableSettingKeys,
      legacyLocalSpeechMigrationValues: legacyLocalSpeechMigrationValues,
      language: storedSettings[.interfaceLanguage],
      customWorkflows: customWorkflows,
      workflowCustomizations: workflowCustomizations,
      workflowLibraryNeedsMigration:
        storedSettings[Self.workflowLibrarySettingKey] == nil
          && storedSettings[.customWorkflows] != nil,
      workflowEnabledStates: workflowEnabledStates,
      systemClipboardCaptureEnabled: storedSettings[.systemClipboardCaptureEnabled]
        ?? storedSettings[.legacyClipboardCaptureEnabled],
      recordMergeSimilar: storedSettings[.recordMergeSimilar]
        ?? storedSettings[.legacyClipboardMergeSimilarItems],
      recordHistoryVisibility: storedSettings[.recordHistoryVisibility]
        ?? storedSettings[.legacyClipboardHistoryVisibility],
      recordPanelHotkey: storedSettings[.recordPanelHotkey]
        ?? storedSettings[.legacyClipboardPanelHotkey],
      preferredSpeechEngine: storedSettings[.preferredSpeechEngine],
      ttsModel: storedSettings[.ttsModel],
      localSpeechModel: storedSettings[.localSpeechModel],
      downloadedLocalSpeechModels: downloadedLocalSpeechModels,
      legacyWhisperKitCustomModel: storedSettings[.legacyWhisperKitCustomModel],
      legacyWhisperKitModelRepo: storedSettings[.legacyWhisperKitModelRepo],
      legacyWhisperKitModelToken: nil,
      legacyWhisperKitModelFolder: storedSettings[.legacyWhisperKitModelFolder],
      legacyWhisperKitLanguage: storedSettings[.legacyWhisperKitLanguage],
      legacyWhisperKitDownloadIfNeeded: storedSettings[.legacyWhisperKitDownloadIfNeeded],
      localSpeechPrewarm: storedSettings[.localSpeechPrewarm],
      enabledSpeechModels: storedSettings[.enabledSpeechModels],
      residentSpeechModels: storedSettings[.residentSpeechModels],
      residentSpeechBudgetConfirmation:
        storedSettings[.residentSpeechBudgetConfirmation],
      speechModelMeasuredPeaks: storedSettings[.speechModelMeasuredPeaks],
      openAIAPIKey: openAIAPIKey,
      openAICredentialAvailability: openAICredentialAvailability,
      openAIBaseURL: storedSettings[.openAIBaseURL],
      openAIModel: storedSettings[.openAIModel],
      vocabularyRules: vocabularyRules,
      vocabularyCollections: vocabularyCollections,
      vocabularyBindings: vocabularyBindings,
      vocabularyLibraryNeedsMigration:
        storedSettings[Self.vocabularyLibrarySettingKey] == nil
          && storedSettings[Self.vocabularyRulesSettingKey] != nil,
      privacyPolicySettings: privacyPolicySettings,
      privacySettingsWereInvalid: privacySettingsWereInvalid,
      recordRetentionPeriod: storedSettings[.recordRetentionPeriod]
        ?? storedSettings[.legacyClipboardHistoryRetentionPeriod],
      runHistoryRetentionPeriod: storedSettings[.runHistoryRetentionPeriod],
      failedAudioRecoveryEnabled: storedSettings[.failedAudioRecoveryEnabled],
      benchmarkRecordingArchiveEnabled: storedSettings[.benchmarkRecordingArchiveEnabled],
      builtinPushToTalkOutputMode: storedSettings[.builtinPushToTalkOutputMode],
      longRecordingModeEnabled: storedSettings[.longRecordingModeEnabled],
      recordingDurationLimit: storedSettings[.recordingDurationLimit],
      loadWarnings: loadWarnings,
      unavailableDomains: unavailableDomains
    )
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
    applyPreferredSpeechEngineSelectionIfNeeded()
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
    } else {
      queueLocalSpeechReadinessIfNeeded()
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
      usesTOMLSource = workflowFiles.result.discoveredFileCount > 0
        || settings.customWorkflows.isEmpty
        || workflowFiles.didMigrateLegacyWorkflows
    } else {
      usesTOMLSource = false
    }

    if usesTOMLSource, let workflowFiles {
      usesWorkflowFilesAsSource = true
      customWorkflows = workflowFiles.result.records.map {
        Self.normalizeCustomWorkflow($0.workflow)
      }
      workflowFileURLsByID = Dictionary(
        uniqueKeysWithValues: workflowFiles.result.records.map {
          ($0.workflow.id, $0.fileURL)
        }
      )
      workflowEnabledStates = storedDomainUnavailable
        ? [:]
        : settings.workflowEnabledStates
      for record in workflowFiles.result.records {
        workflowEnabledStates[record.workflow.id] = record.isEnabled
      }
    } else {
      usesWorkflowFilesAsSource = false
      customWorkflows = settings.customWorkflows
      workflowFileURLsByID = [:]
      workflowEnabledStates = settings.workflowEnabledStates
    }
    workflowCustomizations = storedDomainUnavailable
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
  }

  public func reloadWorkflowFiles() async {
    guard let workflowFileStore else { return }
    let result = await workflowFileStore.load()
    guard !hasBegunApplicationShutdown else { return }

    // A failed first-run migration deliberately keeps the legacy definitions active.
    // Do not let a manual reload of an empty directory discard that recovery copy.
    let shouldAdoptFileSource = usesWorkflowFilesAsSource || customWorkflows.isEmpty
    guard shouldAdoptFileSource else {
      workflowLibraryError = workflowFileIssueMessage(result.issues)
      return
    }

    usesWorkflowFilesAsSource = true
    let previousCustomIDs = Set(customWorkflows.map(\.id))
    customWorkflows = result.records.map {
      Self.normalizeCustomWorkflow($0.workflow)
    }
    workflowFileURLsByID = Dictionary(
      uniqueKeysWithValues: result.records.map {
        ($0.workflow.id, $0.fileURL)
      }
    )
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
    append(
      english: L10n.runText(.workflowTOMLReloaded, language: .english),
      simplifiedChinese: L10n.runText(.workflowTOMLReloaded, language: .simplifiedChinese)
    )
  }

  func workflowFileIssueMessage(_ issues: [WorkflowFileIssue]) -> String? {
    guard !issues.isEmpty else { return nil }
    let visibleIssues = issues.prefix(3).map { issue in
      "\(issue.filename): \(issue.message)"
    }
    let suffix = issues.count > visibleIssues.count
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
        enabled: settings.systemClipboardCaptureEnabled.flatMap(Self.storedBooleanIfValid) ?? false
      )
    }

    if shouldApplyStoredSetting(.recordHistoryVisibility),
      let rawVisibility = settings.recordHistoryVisibility,
      let visibility = RecordHistoryVisibility(rawValue: rawVisibility)
    {
      recordHistoryVisibility = visibility
    }

    if shouldApplyStoredSetting(.recordMergeSimilar),
      let mergeSimilar = settings.recordMergeSimilar
    {
      mergeSimilarRecords = Self.storedBoolean(mergeSimilar, defaultValue: false)
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
      longRecordingModeEnabled = Self.storedBoolean(rawLongRecordingMode, defaultValue: false)
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
      downloadedLocalSpeechModels =
        trustedLocalSpeechModels.isEmpty
        ? settings.downloadedLocalSpeechModels
        : settings.downloadedLocalSpeechModels.filter { modelIdentifier in
          trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier })
        }
    }
    if shouldApplyStoredSetting(.localSpeechModel) {
      localSpeechModelOption = LegacyWhisperModelOption(
        storedModelValue: settings.localSpeechModel
      )
    }
    applyStoredLegacyWhisperModelStrings(settings)
    applyStoredLegacyWhisperBooleans(settings)
    if shouldApplyStoredSetting(.enabledSpeechModels),
      let rawValue = settings.enabledSpeechModels,
      let values = try? Self.loadDownloadedLocalSpeechModels(from: rawValue)
    {
      enabledSpeechModelIDs = Set(values).intersection(
        speechModelResourceCatalog.map(\.id)
      )
    }
    if shouldApplyStoredSetting(.residentSpeechModels),
      let rawValue = settings.residentSpeechModels,
      let values = try? Self.loadDownloadedLocalSpeechModels(from: rawValue)
    {
      residentSpeechModelIDs = Set(values).intersection(enabledSpeechModelIDs)
    }
    if shouldApplyStoredSetting(.speechModelMeasuredPeaks),
      let values = try? Self.loadMeasuredSpeechModelPeaks(
        from: settings.speechModelMeasuredPeaks
      )
    {
      let catalogIDs = Set(speechModelResourceCatalog.map(\.id))
      measuredSpeechModelPeakByteCounts = values.filter { catalogIDs.contains($0.key) }
    }
    if shouldApplyStoredSetting(.residentSpeechBudgetConfirmation) {
      let value = settings.residentSpeechBudgetConfirmation?
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
    // Production trusted catalogs never honor ambient repository, folder,
    // or bearer-token state left by older unverified-model settings.
    legacyWhisperKitModelRepo = ""
    legacyWhisperKitModelToken = ""
    legacyWhisperKitModelFolder = ""
  }

  func applyStoredLegacyWhisperModelStrings(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.legacyWhisperKitCustomModel),
      let customModel = settings.legacyWhisperKitCustomModel
    {
      legacyWhisperKitCustomModel = customModel
    } else if shouldApplyStoredSetting(.legacyWhisperKitCustomModel),
      shouldApplyStoredSetting(.localSpeechModel),
      localSpeechModelOption == .custom,
      let model = settings.localSpeechModel
    {
      legacyWhisperKitCustomModel = model
    }

    if shouldApplyStoredSetting(.localSpeechModel),
      let model = settings.localSpeechModel
    {
      localSpeechModel = model
    }
    if shouldApplyStoredSetting(.legacyWhisperKitModelRepo),
      let repo = settings.legacyWhisperKitModelRepo
    {
      legacyWhisperKitModelRepo = repo
    }
    if shouldApplyStoredSetting(.legacyWhisperKitModelToken),
      let token = settings.legacyWhisperKitModelToken
    {
      legacyWhisperKitModelToken = token
    }
    if shouldApplyStoredSetting(.legacyWhisperKitModelFolder),
      let folder = settings.legacyWhisperKitModelFolder
    {
      legacyWhisperKitModelFolder = folder
    }
    if shouldApplyStoredSetting(.legacyWhisperKitLanguage),
      let language = settings.legacyWhisperKitLanguage
    {
      legacyWhisperKitLanguage = language
    }
  }

  func applyStoredLegacyWhisperBooleans(_ settings: StoredAppSettingsSnapshot) {
    if shouldApplyStoredSetting(.legacyWhisperKitDownloadIfNeeded),
      let downloadIfNeeded = settings.legacyWhisperKitDownloadIfNeeded
    {
      legacyWhisperKitDownloadIfNeeded = Self.storedBoolean(
        downloadIfNeeded,
        defaultValue: LocalSpeechSettings().downloadIfNeeded
      )
    }

    if shouldApplyStoredSetting(.localSpeechPrewarm),
      let prewarm = settings.localSpeechPrewarm
    {
      localSpeechPrewarm = Self.storedBoolean(
        prewarm,
        defaultValue: LocalSpeechSettings().prewarm
      )
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
            let resolution = Self.resolveLegacyLocalSpeechSetting(
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
        let invalidKeys = Self.invalidScalarSettingKeys(in: recoveredValues)
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
          self.queueLocalSpeechReadinessIfNeeded()
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
          .union(Self.invalidScalarSettingKeys(in: snapshot.values))
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
          Self.openAICredentialAvailability(for: credential)
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
        enabled: values[.systemClipboardCaptureEnabled].flatMap(Self.storedBooleanIfValid) ?? false
      )
      if let rawValue = values[.recordHistoryVisibility],
        let visibility = RecordHistoryVisibility(rawValue: rawValue)
      {
        recordHistoryVisibility = visibility
      }
      if let rawValue = values[.recordMergeSimilar],
        let mergeSimilar = Self.storedBooleanIfValid(rawValue)
      {
        mergeSimilarRecords = mergeSimilar
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
      if !preservingLocalSpeechModel {
        if let model = values[.localSpeechModel] {
          localSpeechModelOption = LegacyWhisperModelOption(storedModelValue: model)
        }
        if let customModel = values[.legacyWhisperKitCustomModel] {
          legacyWhisperKitCustomModel = customModel
        } else if localSpeechModelOption == .custom,
          let model = values[.localSpeechModel]
        {
          legacyWhisperKitCustomModel = model
        }
        if let model = values[.localSpeechModel] { localSpeechModel = model }
      }
      if let repo = values[.legacyWhisperKitModelRepo] { legacyWhisperKitModelRepo = repo }
      if let folder = values[.legacyWhisperKitModelFolder] { legacyWhisperKitModelFolder = folder }
      if let language = values[.legacyWhisperKitLanguage] { legacyWhisperKitLanguage = language }
      if let rawValue = values[.legacyWhisperKitDownloadIfNeeded],
        let value = Self.storedBooleanIfValid(rawValue)
      {
        legacyWhisperKitDownloadIfNeeded = value
      }
      if let rawValue = values[.localSpeechPrewarm],
        let value = Self.storedBooleanIfValid(rawValue)
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
        let value = Self.storedBooleanIfValid(rawValue)
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

  static func openAICredentialAvailability(for credential: String?)
    -> OpenAICredentialAvailability
  {
    guard let credential,
      !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return .missing
    }
    return .available
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
      vocabularyRules = Self.sortedVocabularyRules(settings.vocabularyRules)
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
        let recovered = try await Self.loadRecoverableStoredSettingsDomains(
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
        self.customWorkflows = workflowFiles.records.map {
          Self.normalizeCustomWorkflow($0.workflow)
        }
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
    guard let category = Self.settingsSaveCategory(for: key) else {
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

    let previousTask = pendingSettingWriteTasks[taskKey]
    previousTask?.cancel()
    let generation = (pendingSettingWriteGenerations[taskKey] ?? 0) + 1
    pendingSettingWriteGenerations[taskKey] = generation
    let debounceDuration = settingsWriteDebounceDuration

    let task = Task { [weak self, credentialStore, previousTask] in
      await previousTask?.value
      do {
        try await Task.sleep(for: debounceDuration)
        try Task.checkCancellation()
        if value.isEmpty {
          try await credentialStore.removeCredential(for: credentialKey)
        } else {
          try await credentialStore.setCredential(value, for: credentialKey)
        }
        await MainActor.run {
          guard let self else { return }
          let isCurrentWrite = self.pendingSettingWriteGenerations[taskKey] == generation
          self.finishPendingSettingWrite(for: taskKey, generation: generation)
          if isCurrentWrite, credentialKey == .openAIAPIKey {
            self.openAICredentialAvailability =
              Self.openAICredentialAvailability(for: value)
            self.workflowLibraryChangedAction()
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          self?.finishPendingSettingWrite(for: taskKey, generation: generation)
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          let isCurrentWrite = self.pendingSettingWriteGenerations[taskKey] == generation
          self.finishPendingSettingWrite(for: taskKey, generation: generation)
          guard isCurrentWrite else { return }
          if credentialKey == .openAIAPIKey {
            self.openAICredentialAvailability = .inaccessible
            self.workflowLibraryChangedAction()
          }
          self.append(
            english: L10n.runText(.credentialSaveFailed, language: .english),
            simplifiedChinese: L10n.runText(
              .credentialSaveFailed,
              language: .simplifiedChinese
            )
          )
        }
      }
    }
    pendingSettingWriteTasks[taskKey] = task
    registerPersistenceWrite(task)
  }

  func persistRetryableSettingsStoreWrite(
    for key: AppSettingKey,
    category: SettingsSaveCategory,
    debounceDuration: Duration = .zero,
    operation: @escaping SettingsStoreWriteOperation
  ) {
    let retryableWrite = RetryableSettingsStoreWrite(
      category: category,
      operation: operation
    )
    guard let settingsStore else {
      recordFailedSettingsStoreWrite(retryableWrite, for: key)
      return
    }
    scheduleRetryableSettingsStoreWrite(
      retryableWrite,
      for: key,
      settingsStore: settingsStore,
      debounceDuration: debounceDuration
    )
  }

  func scheduleRetryableSettingsStoreWrite(
    _ retryableWrite: RetryableSettingsStoreWrite,
    for key: AppSettingKey,
    settingsStore: any SettingsStore,
    debounceDuration: Duration
  ) {
    let previousTask = pendingSettingWriteTasks[key]
    previousTask?.cancel()

    let generation = (pendingSettingWriteGenerations[key] ?? 0) + 1
    pendingSettingWriteGenerations[key] = generation
    if failedSettingsStoreWrites[key] != nil {
      retryingSettingsStoreWriteKeys.insert(key)
      refreshSettingsSaveState()
    }

    let task = Task { [weak self, settingsStore, previousTask, retryableWrite] in
      await previousTask?.value
      do {
        try await Task.sleep(for: debounceDuration)
        try Task.checkCancellation()
        try await retryableWrite.operation(settingsStore)
        await MainActor.run {
          guard let self,
            self.pendingSettingWriteGenerations[key] == generation
          else {
            return
          }
          self.finishPendingSettingWrite(for: key, generation: generation)
          self.failedSettingsStoreWrites[key] = nil
          self.retryingSettingsStoreWriteKeys.remove(key)
          self.refreshSettingsSaveState()
        }
      } catch is CancellationError {
        await MainActor.run {
          guard let self,
            self.pendingSettingWriteGenerations[key] == generation
          else {
            return
          }
          self.finishPendingSettingWrite(for: key, generation: generation)
          self.retryingSettingsStoreWriteKeys.remove(key)
          self.refreshSettingsSaveState()
        }
      } catch {
        await MainActor.run {
          guard let self,
            self.pendingSettingWriteGenerations[key] == generation
          else {
            return
          }
          self.finishPendingSettingWrite(for: key, generation: generation)
          self.recordFailedSettingsStoreWrite(retryableWrite, for: key)
        }
      }
    }
    pendingSettingWriteTasks[key] = task
    registerPersistenceWrite(task)
  }

  public func retryUnsavedSettingsSave() {
    let writes = failedSettingsStoreWrites.sorted { lhs, rhs in
      lhs.key.rawValue < rhs.key.rawValue
    }
    guard !writes.isEmpty else { return }
    guard let settingsStore else {
      appendSettingsSaveFailureEvent()
      return
    }

    retryingSettingsStoreWriteKeys.formUnion(writes.map(\.key))
    refreshSettingsSaveState()
    for (key, retryableWrite) in writes {
      scheduleRetryableSettingsStoreWrite(
        retryableWrite,
        for: key,
        settingsStore: settingsStore,
        debounceDuration: .zero
      )
    }
  }

  func recordFailedSettingsStoreWrite(
    _ retryableWrite: RetryableSettingsStoreWrite,
    for key: AppSettingKey
  ) {
    failedSettingsStoreWrites[key] = retryableWrite
    retryingSettingsStoreWriteKeys.remove(key)
    refreshSettingsSaveState()
    appendSettingsSaveFailureEvent()
  }

  func refreshSettingsSaveState() {
    guard !failedSettingsStoreWrites.isEmpty else {
      retryingSettingsStoreWriteKeys.removeAll()
      settingsSaveState = .saved
      return
    }
    let categories = Set(failedSettingsStoreWrites.values.map(\.category))
      .sorted { $0.rawValue < $1.rawValue }
    let summary = UnsavedSettingsSummary(
      affectedChangeCount: failedSettingsStoreWrites.count,
      categories: categories
    )
    settingsSaveState =
      retryingSettingsStoreWriteKeys.isEmpty
      ? .unsaved(summary)
      : .retrying(summary)
  }

  func appendSettingsSaveFailureEvent() {
    append(
      english: L10n.runText(.settingsSaveFailedRetry, language: .english),
      simplifiedChinese: L10n.runText(.settingsSaveFailedRetry, language: .simplifiedChinese)
    )
  }

  static func settingsSaveCategory(for key: AppSettingKey) -> SettingsSaveCategory? {
    switch key {
    case .interfaceLanguage:
      .interface
    case .systemClipboardCaptureEnabled,
      .recordHistoryVisibility,
      .recordPanelHotkey,
      .recordMergeSimilar:
      .systemClipboard
    case .preferredSpeechEngine,
      .ttsModel,
      .localSpeechModel,
      .localSpeechDownloadedModels,
      .localSpeechPrewarm,
      .enabledSpeechModels,
      .residentSpeechModels,
      .residentSpeechBudgetConfirmation,
      .speechModelMeasuredPeaks,
      .openAIBaseURL,
      .openAIModel:
      .speech
    case .builtinPushToTalkOutputMode, .longRecordingModeEnabled, .recordingDurationLimit:
      .input
    case .vocabularyRules, .vocabularyLibrary:
      .vocabulary
    case .customWorkflows, .workflowLibrary, .workflowEnabledStates:
      .workflows
    case .selectedWorkflowID,
      .webhookConfigurationProtectionState,
      .legacyWhisperKitModel,
      .legacyWhisperKitDownloadedModels,
      .legacyWhisperKitCustomModel,
      .legacyWhisperKitModelRepo,
      .legacyWhisperKitModelToken,
      .legacyWhisperKitModelFolder,
      .legacyWhisperKitLanguage,
      .legacyWhisperKitDownloadIfNeeded,
      .legacyWhisperKitPrewarm,
      .retiredDeepgramAPIKey,
      .retiredDeepgramBaseURL,
      .retiredDeepgramModel,
      .retiredDeepgramLanguage,
      .openAIAPIKey,
      .privacySensitiveAppRules,
      .privacyCloudConfirmationRequired,
      .privacyCloudProcessingAuthorizations,
      .privacyHistoryPreviewMode,
      .privacySecureInputConservativeMode,
      .recordRetentionPeriod,
      .runHistoryRetentionPeriod,
      .localHistoryMaintenanceState,
      .failedAudioRecoveryEnabled,
      .benchmarkRecordingArchiveEnabled,
      .legacyClipboardGlobalMode,
      .legacyClipboardAppModes,
      .legacyClipboardRoutePreferences,
      .legacyClipboardPersistedState,
      .legacyClipboardHistoryRetentionPeriod,
      .legacyClipboardCaptureEnabled,
      .legacyClipboardMergeSimilarItems,
      .legacyClipboardHistoryVisibility,
      .legacyClipboardPanelHotkey:
      nil
    }
  }

  func finishPendingSettingWrite(for key: AppSettingKey, generation: Int) {
    guard pendingSettingWriteGenerations[key] == generation else { return }
    pendingSettingWriteTasks[key] = nil
    pendingSettingWriteGenerations[key] = nil
  }

  func registerPersistenceWrite(_ task: Task<Void, Never>) {
    let previousBarrier = pendingPersistenceWriteBarrierTask
    persistenceWriteBarrierGeneration += 1
    let generation = persistenceWriteBarrierGeneration
    pendingPersistenceWriteBarrierTask = Task { [weak self, previousBarrier, task] in
      await previousBarrier?.value
      await task.value
      guard let self, self.persistenceWriteBarrierGeneration == generation else { return }
      self.pendingPersistenceWriteBarrierTask = nil
    }
  }

  func performTrackedPersistenceWrite(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    let writeTask = Task {
      try await operation()
    }
    let completionTask = Task {
      _ = try? await writeTask.value
    }
    registerPersistenceWrite(completionTask)
    try await writeTask.value
  }

  public func flushPendingPersistenceWrites() async {
    while let barrier = pendingPersistenceWriteBarrierTask {
      await barrier.value
    }
  }

  /// The global hotkey producer must not become available until the initial
  /// durable settings snapshot has atomically selected its workflow, speech
  /// engine, and hold/toggle mode. Manual UI remains usable while this waits.
  public func waitForInitialVoiceConfiguration() async {
    await settingsReadTaskOwner.waitForActiveTask(in: .initialSettingsLoad)
  }

  public func stopSettingsReadTasksForApplicationShutdown() async {
    hasBegunApplicationShutdown = true
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

    while !failedSettingsStoreWrites.isEmpty {
      guard !Task.isCancelled else { return }
      retryUnsavedSettingsSave()
      await flushPendingPersistenceWrites()
      guard !failedSettingsStoreWrites.isEmpty else { return }

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

  public func stopInteractiveWorkflowRunsForApplicationShutdown() async {
    hasBegunApplicationShutdown = true
    let task = pendingInteractiveWorkflowTask
    task?.cancel()
    await task?.value
    pendingInteractiveWorkflowTask = nil
    let audioTasks = Array(workflowAudioActionTasks.values)
    for audioTask in audioTasks {
      audioTask.cancel()
    }
    for audioTask in audioTasks {
      await audioTask.value
    }
    workflowAudioActionTasks.removeAll()
    isRunning = false
    workflowAudioRunState = .idle
    workflowAudioCaptureRunID = nil
  }

  /// Waits for the interactive workflow accepted before this call to finish.
  ///
  /// Unlike the application-shutdown drain, this does not cancel the run or
  /// mutate presentation state. It is a deterministic completion boundary for
  /// callers that need to observe the result of an explicitly launched run.
  public func waitForInteractiveWorkflowRun() async {
    while let task = pendingInteractiveWorkflowTask {
      await task.value
    }
  }

  /// Waits for accepted start/finish actions for an interactive captured-audio
  /// workflow without changing the run state.
  public func waitForWorkflowAudioActions() async {
    while !workflowAudioActionTasks.isEmpty {
      let tasks = Array(workflowAudioActionTasks.values)
      for task in tasks {
        await task.value
      }
    }
  }

  /// Waits for local speech preparation, including cancelled provider work
  /// that is still unwinding, without changing the selected model or state.
  public func waitForLocalSpeechPreparation() async {
    await localSpeechPreparationTaskOwner.waitUntilIdle()
  }

  public func stopLocalSpeechPreparationForApplicationShutdown() async {
    hasBegunApplicationShutdown = true
    localSpeechReadinessGeneration += 1
    localSpeechPreparationGeneration += 1

    localSpeechPreparationState = .idle
    localSpeechPreparationProgress = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil

    localSpeechPreparationTaskOwner.stopForApplicationShutdown()
    await stopLocalSpeechRuntimeAction()
  }

  func resetLocalSpeechPreparationStatus() {
    localSpeechReadinessGeneration += 1
    localSpeechPreparationGeneration += 1
    localSpeechPreparationTaskOwner.cancelActive()
    localSpeechPreparationState = .idle
    localSpeechPreparationProgress = 0
    localSpeechPreparedModelIdentifier = nil
    localSpeechPreparationError = nil
    if !isRestoringSettings {
      releaseLocalSpeechRuntimeAction()
    }
    queueLocalSpeechReadinessIfNeeded()
  }

  func hasLiveSubtitleSemanticChange(
    from current: LiveSubtitleSnapshot?,
    to snapshot: LiveSubtitleSnapshot?
  ) -> Bool {
    guard let current, let snapshot else {
      return current != nil || snapshot != nil
    }
    return current.runID != snapshot.runID || current.workflow != snapshot.workflow
      || current.phase != snapshot.phase || current.confirmedText != snapshot.confirmedText
      || current.hypothesisText != snapshot.hypothesisText
      || current.statusText != snapshot.statusText || current.providerID != snapshot.providerID
      || current.networkUsage != snapshot.networkUsage
      || current.livePreviewPlacement != snapshot.livePreviewPlacement
      || current.queuedRunCount != snapshot.queuedRunCount
      || current.prefersCompactLayout != snapshot.prefersCompactLayout
  }

  func shouldUpdateLiveSubtitleSnapshot(_ snapshot: LiveSubtitleSnapshot) -> Bool {
    guard let current = currentCaptureLiveSubtitleSnapshot else { return true }
    if hasLiveSubtitleSemanticChange(from: current, to: snapshot) {
      lastLiveSubtitleMeterRefreshAt = ContinuousClock.now
      return true
    }
    guard current.levelMeter != snapshot.levelMeter else {
      cancelPendingLiveSubtitleMeterRefresh()
      return false
    }
    let now = ContinuousClock.now
    if let lastLiveSubtitleMeterRefreshAt,
      now - lastLiveSubtitleMeterRefreshAt < liveSubtitleMeterRefreshInterval
    {
      let elapsed = now - lastLiveSubtitleMeterRefreshAt
      scheduleLiveSubtitleMeterRefresh(
        snapshot,
        after: liveSubtitleMeterRefreshInterval - elapsed
      )
      return false
    }
    cancelPendingLiveSubtitleMeterRefresh()
    lastLiveSubtitleMeterRefreshAt = now
    return true
  }

  func scheduleLiveSubtitleMeterRefresh(
    _ snapshot: LiveSubtitleSnapshot,
    after delay: Duration
  ) {
    guard !hasBegunApplicationShutdown else { return }
    if pendingLiveSubtitleMeterSnapshot?.runID == snapshot.runID,
      pendingLiveSubtitleMeterRefreshTask != nil
    {
      pendingLiveSubtitleMeterSnapshot = snapshot
      return
    }

    cancelPendingLiveSubtitleMeterRefresh()
    liveSubtitleMeterRefreshGeneration &+= 1
    let generation = liveSubtitleMeterRefreshGeneration
    let runID = snapshot.runID
    let wait = waitForLiveSubtitleMeterRefresh
    pendingLiveSubtitleMeterSnapshot = snapshot
    pendingLiveSubtitleMeterRefreshTask = Task { @MainActor [weak self, wait] in
      do {
        try await wait(delay)
      } catch {
        self?.discardPendingLiveSubtitleMeterRefresh(generation: generation)
        return
      }
      guard !Task.isCancelled else { return }
      self?.applyPendingLiveSubtitleMeterRefresh(runID: runID, generation: generation)
    }
  }

  func applyPendingLiveSubtitleMeterRefresh(runID: UUID, generation: Int) {
    guard generation == liveSubtitleMeterRefreshGeneration else { return }
    pendingLiveSubtitleMeterRefreshTask = nil
    guard
      !hasBegunApplicationShutdown,
      let pendingSnapshot = pendingLiveSubtitleMeterSnapshot,
      pendingSnapshot.runID == runID,
      let currentSnapshot = currentCaptureLiveSubtitleSnapshot,
      currentSnapshot.runID == runID,
      !hasLiveSubtitleSemanticChange(from: currentSnapshot, to: pendingSnapshot)
    else {
      pendingLiveSubtitleMeterSnapshot = nil
      return
    }

    pendingLiveSubtitleMeterSnapshot = nil
    lastLiveSubtitleMeterRefreshAt = ContinuousClock.now
    currentCaptureLiveSubtitleSnapshot = pendingSnapshot
    refreshLiveSubtitlePresentation()
  }

  func discardPendingLiveSubtitleMeterRefresh(generation: Int) {
    guard generation == liveSubtitleMeterRefreshGeneration else { return }
    pendingLiveSubtitleMeterRefreshTask = nil
    pendingLiveSubtitleMeterSnapshot = nil
  }

  func cancelPendingLiveSubtitleMeterRefresh() {
    guard
      pendingLiveSubtitleMeterRefreshTask != nil || pendingLiveSubtitleMeterSnapshot != nil
    else { return }
    liveSubtitleMeterRefreshGeneration &+= 1
    pendingLiveSubtitleMeterRefreshTask?.cancel()
    pendingLiveSubtitleMeterRefreshTask = nil
    pendingLiveSubtitleMeterSnapshot = nil
  }

  func applyLiveSubtitleUpdate(_ snapshot: LiveSubtitleSnapshot) {
    let currentLiveRunID = currentCaptureLiveSubtitleSnapshot?.runID
    if snapshot.isVisible || currentLiveRunID == nil || currentLiveRunID == snapshot.runID {
      pendingLiveSubtitleHideTask?.cancel()
    }
    if snapshot.isVisible {
      if workflowAudioCaptureRunID == nil, workflowAudioRunState != .idle {
        workflowAudioCaptureRunID = snapshot.runID
      }
      if shouldUpdateLiveSubtitleSnapshot(snapshot) {
        currentCaptureLiveSubtitleSnapshot = snapshot
        refreshLiveSubtitlePresentation()
        if snapshot.phase == .failed {
          scheduleLiveSubtitleHide()
        } else if snapshot.phase == .preparing {
          scheduleLiveSubtitleHide(after: liveSubtitlePreparingHideDelay)
        }
      }
    } else if currentCaptureLiveSubtitleSnapshot?.runID == snapshot.runID {
      if case .recording(let workflowID) = workflowAudioRunState {
        workflowAudioRunState = .transcribing(workflowID: workflowID)
      }
      currentCaptureLiveSubtitleSnapshot = nil
      lastLiveSubtitleMeterRefreshAt = nil
      refreshLiveSubtitlePresentation()
    }
  }

  func refreshLiveSubtitlePresentation() {
    if var captureSnapshot = currentCaptureLiveSubtitleSnapshot, captureSnapshot.isVisible {
      captureSnapshot.queuedRunCount = queuedBackgroundRunCount(from: audioProcessingQueueSnapshot)
      setLiveSubtitlePresentation(captureSnapshot)
      return
    }
    // The floating surface belongs only to live capture. Background
    // recognition and output remain observable in the menu bar/history, but
    // never open a second panel that can fight with the next recording.
    setLiveSubtitlePresentation(nil)
  }

  func setLiveSubtitlePresentation(_ snapshot: LiveSubtitleSnapshot?) {
    liveSubtitleSnapshot = snapshot
    syncLiveSubtitlePanel()
  }

  func syncLiveSubtitlePanel() {
    updateLiveSubtitlePanelAction(liveSubtitleSnapshot, language)
  }

  func queuedBackgroundRunCount(from snapshot: AudioProcessingQueueSnapshot?) -> Int {
    snapshot?.pendingCount ?? 0
  }

  func applyDiagnosticEvents(_ events: [DiagnosticEvent]) {
    guard !events.isEmpty else { return }
    diagnosticEvents = Array(
      Self.sortedDiagnosticEvents(diagnosticEvents + events).prefix(200)
    )
    for event in events {
      append(
        english: "[\(UIStrings.subsystem(event.subsystem, language: .english))] \(event.message)",
        simplifiedChinese:
          "[\(UIStrings.subsystem(event.subsystem, language: .simplifiedChinese))] \(event.message)"
      )
    }
  }

  static func sortedDiagnosticEvents(_ events: [DiagnosticEvent]) -> [DiagnosticEvent] {
    events.sorted { $0.timestamp > $1.timestamp }
  }

  func updateLocalSpeechPreparationProgress(
    _ progress: Progress,
    operationID: UUID
  ) {
    guard !hasBegunApplicationShutdown,
      localSpeechPreparationTaskOwner.isActive(id: operationID),
      localSpeechPreparationState == .preparing
    else {
      return
    }
    let fraction = progress.fractionCompleted
    if fraction.isFinite {
      localSpeechPreparationProgress = min(max(fraction, 0), 1)
    }
    localSpeechPreparationCompletedUnitCount = max(progress.completedUnitCount, 0)
    localSpeechPreparationTotalUnitCount = max(progress.totalUnitCount, 0)
  }

  func rebuildWorkflowLibrary() {
    invalidateWorkflowExplanation()
    let builtInWorkflowIDs = Set(builtInWorkflows.map(\.id))
    let builtInOverridesByID = Dictionary(
      uniqueKeysWithValues: customWorkflows
        .filter { builtInWorkflowIDs.contains($0.id) }
        .map { ($0.id, $0) }
    )
    let sortedCustomWorkflows = customWorkflows
      .filter { !builtInWorkflowIDs.contains($0.id) }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    let effectiveBuiltInWorkflows = builtInWorkflows.map {
      builtInOverridesByID[$0.id] ?? $0
    }
    workflows = (sortedCustomWorkflows + effectiveBuiltInWorkflows).map {
      workflowApplyingVocabularyCustomization($0)
    }
    synchronizeWorkflowEnabledStates()
    workflowLibraryChangedAction()
  }

  private func workflowApplyingVocabularyCustomization(
    _ workflow: WorkflowDefinition
  ) -> WorkflowDefinition {
    var workflow = workflow
    if let customization = workflowCustomizations.first(where: {
      $0.workflowID == workflow.id
    }), let bindings = customization.vocabularyBindings {
      workflow.plan.setup.vocabularyBindings = bindings
    } else if workflow.plan.setup.speechRoute != nil {
      workflow.plan.setup.vocabularyBindings = vocabularyCollectionBindings
    }
    return workflow
  }

  func applyPreferredSpeechEngineSelectionIfNeeded() {
    // Workflow enablement no longer tracks a selected workflow.
  }

  func persistCustomWorkflows() {
    persistWorkflowLibrary()
  }

  func persistWorkflowLibrary() {
    markSettingModifiedDuringInitialLoad(Self.workflowLibrarySettingKey)
    guard !isRestoringSettings, isWorkflowLibraryAvailable else { return }
    let document = WorkflowLibraryDocument(
      customWorkflows: usesWorkflowFilesAsSource ? [] : customWorkflows,
      customizations: workflowCustomizations
    )
    persistRetryableSettingsStoreWrite(
      for: Self.workflowLibrarySettingKey,
      category: .workflows
    ) { settingsStore in
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(document)
      try await settingsStore.setString(
        String(decoding: data, as: UTF8.self),
        forKey: Self.workflowLibrarySettingKey
      )
    }
  }

  static func loadCustomWorkflows(
    from rawValue: String?
  ) throws -> [WorkflowDefinition] {
    guard let rawValue, !rawValue.isEmpty else { return [] }
    let data = Data(rawValue.utf8)
    let decoded = try JSONDecoder().decode([WorkflowDefinition].self, from: data)
    guard Set(decoded.map(\.id)).count == decoded.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    return decoded.map(Self.normalizeCustomWorkflow)
  }

  static func loadWorkflowLibrary(
    from rawValue: String?
  ) throws -> WorkflowLibraryDocument? {
    guard let rawValue, !rawValue.isEmpty else { return nil }
    let document = try JSONDecoder().decode(
      WorkflowLibraryDocument.self,
      from: Data(rawValue.utf8)
    )
    guard document.schemaVersion == WorkflowLibraryDocument.currentSchemaVersion else {
      throw StoredSettingsCollectionValidationError.invalidIdentifier
    }
    guard Set(document.customWorkflows.map(\.id)).count
      == document.customWorkflows.count
    else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    guard Set(document.customizations.map(\.workflowID)).count
      == document.customizations.count
    else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    for workflow in document.customWorkflows {
      let input: WorkflowPlanInput =
        workflow.plan.setup.speechRoute == nil ? .text : .audio
      try WorkflowPlanValidator.validate(workflow.plan, input: input)
    }
    for customization in document.customizations {
      guard let bindings = customization.vocabularyBindings else { continue }
      guard Set(bindings.map(\.id)).count == bindings.count else {
        throw StoredSettingsCollectionValidationError.duplicateIdentifier
      }
    }
    var normalized = document
    normalized.customWorkflows = normalized.customWorkflows.map(Self.normalizeCustomWorkflow)
    return normalized
  }

  static func loadWorkflowEnabledStates(
    from rawValue: String?
  ) throws -> [UUID: Bool] {
    guard let rawValue, !rawValue.isEmpty else { return [:] }
    let data = Data(rawValue.utf8)
    let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
    var enabledStates: [UUID: Bool] = [:]
    for entry in decoded {
      guard let workflowID = UUID(uuidString: entry.key) else {
        throw StoredSettingsCollectionValidationError.invalidIdentifier
      }
      guard enabledStates.updateValue(entry.value, forKey: workflowID) == nil else {
        throw StoredSettingsCollectionValidationError.duplicateIdentifier
      }
    }
    return enabledStates
  }

  static func loadDownloadedLocalSpeechModels(
    from rawValue: String?
  ) throws -> [String] {
    guard let rawValue, !rawValue.isEmpty else { return [] }
    let data = Data(rawValue.utf8)
    let decoded = try JSONDecoder().decode([String].self, from: data)
    guard Set(decoded).count == decoded.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    return decoded.sorted()
  }

  static func loadMeasuredSpeechModelPeaks(
    from rawValue: String?
  ) throws -> [String: UInt64] {
    guard let rawValue, !rawValue.isEmpty else { return [:] }
    let decoded = try JSONDecoder().decode(
      [String: UInt64].self,
      from: Data(rawValue.utf8)
    )
    guard decoded.allSatisfy({ entry in
      let identifier = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
      return identifier == entry.key
        && !identifier.isEmpty
        && identifier.utf8.count <= 256
        && entry.value > 0
    }) else {
      throw StoredSettingsCollectionValidationError.invalidIdentifier
    }
    return decoded
  }

  static func loadVocabularyRules(from rawValue: String?) throws -> [VocabularyRule] {
    guard let rawValue, !rawValue.isEmpty else { return [] }
    let data = Data(rawValue.utf8)
    let decoded = try JSONDecoder().decode([VocabularyRule].self, from: data)
    guard Set(decoded.map(\.id)).count == decoded.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    return sortedVocabularyRules(decoded)
  }

  static func loadVocabularyLibrary(
    from rawValue: String?
  ) throws -> VocabularyLibraryDocument? {
    guard let rawValue, !rawValue.isEmpty else { return nil }
    let document = try JSONDecoder().decode(
      VocabularyLibraryDocument.self,
      from: Data(rawValue.utf8)
    )
    guard document.schemaVersion == VocabularyLibraryDocument.currentSchemaVersion else {
      throw StoredSettingsCollectionValidationError.invalidIdentifier
    }
    guard Set(document.collections.map(\.id)).count == document.collections.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    let entries = document.collections.flatMap(\.entries)
    guard Set(entries.map(\.id)).count == entries.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    return document
  }

  private static func loadRecoverableStoredSettingsDomains(
    from settingsStore: any SettingsStore,
    workflowFileStore: (any WorkflowFileStore)? = nil
  ) async throws -> RecoverableStoredSettingsDomains {
    let keys: [AppSettingKey] = [
      .customWorkflows,
      .workflowEnabledStates,
      .localSpeechDownloadedModels,
      .legacyWhisperKitDownloadedModels,
      vocabularyRulesSettingKey,
    ]
    let snapshot = try await settingsStore.settingsSnapshot(forKeys: keys)
    let unavailableKeys = snapshot.unavailableKeys

    let workflowDomainIsReadable = unavailableKeys.isDisjoint(with: [
      .customWorkflows,
      .workflowEnabledStates,
    ])
    let workflowFiles = await workflowFileStore?.load()
    var customWorkflows: [WorkflowDefinition]?
    var workflowEnabledStates: [UUID: Bool]?
    if workflowDomainIsReadable {
      do {
        customWorkflows = workflowFiles == nil
          ? try loadCustomWorkflows(from: snapshot.values[.customWorkflows])
          : nil
        workflowEnabledStates = try loadWorkflowEnabledStates(
          from: snapshot.values[.workflowEnabledStates]
        )
      } catch {
        customWorkflows = nil
        workflowEnabledStates = nil
      }
    } else {
      customWorkflows = nil
      workflowEnabledStates = nil
    }

    let downloadedResolution = resolveLegacyLocalSpeechSetting(
      currentKey: .localSpeechDownloadedModels,
      legacyKey: .legacyWhisperKitDownloadedModels,
      in: snapshot
    )
    let downloadedLocalSpeechModels: [String]?
    if downloadedResolution.isUnavailable {
      downloadedLocalSpeechModels = nil
    } else {
      downloadedLocalSpeechModels = try? loadDownloadedLocalSpeechModels(
        from: downloadedResolution.value
      )
      if downloadedResolution.usedLegacyValue,
        downloadedLocalSpeechModels != nil,
        let value = downloadedResolution.value
      {
        try await settingsStore.setStringsAtomically([
          .localSpeechDownloadedModels: value
        ])
      }
    }

    let vocabularyRules: [VocabularyRule]?
    if unavailableKeys.contains(vocabularyRulesSettingKey) {
      vocabularyRules = nil
    } else {
      vocabularyRules = try? loadVocabularyRules(
        from: snapshot.values[vocabularyRulesSettingKey]
      )
    }

    return RecoverableStoredSettingsDomains(
      customWorkflows: customWorkflows,
      workflowFiles: workflowFiles,
      workflowEnabledStates: workflowEnabledStates,
      downloadedLocalSpeechModels: downloadedLocalSpeechModels,
      vocabularyRules: vocabularyRules
    )
  }

  static func sortedVocabularyRules(_ rules: [VocabularyRule]) -> [VocabularyRule] {
    rules.sorted { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  static func normalizeCustomWorkflow(_ workflow: WorkflowDefinition) -> WorkflowDefinition {
    var workflow = workflow
    workflow.titleKey = nil
    workflow.metadata[workflowOriginMetadataKey] = userWorkflowOriginMetadataValue
    if ["whisperkit.local", "auto", sherpaOnnxRecognizerID, sherpaStreamingRecognizerID]
      .contains(workflow.plan.setup.speechRoute?.recognizerID ?? "")
    {
      workflow.plan.setup.speechRoute?.recognizerID = localSpeechRecognizerID
    }
    if workflow.plan.setup.speechRoute?.recognizerID == "deepgram.prerecorded" {
      workflow.plan.setup.speechRoute?.recognizerID = localSpeechRecognizerID
      workflow.plan.setup.speechRoute?.providerModel = nil
      workflow.metadata["provider"] = "local-speech"
      workflow.metadata.removeValue(forKey: "deepgram.model")
    }
    if workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride] == nil,
      let legacyModelOverride = workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride]
    {
      workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride] = legacyModelOverride
    }
    workflow.metadata.removeValue(forKey: WorkflowMetadataKey.legacyWhisperKitModelOverride)
    return workflow
  }

  func currentLocalSpeechSettings() -> LocalSpeechSettings {
    if !trustedLocalSpeechModels.isEmpty {
      return LocalSpeechSettings(
        model: selectedTrustedLocalSpeechModelIdentifier,
        modelRepo: "",
        modelToken: "",
        modelFolder: "",
        language: "",
        downloadIfNeeded: true,
        prewarm: localSpeechPrewarm,
        enabledModelIDs: enabledSpeechModelIDs,
        residentModelIDs: residentSpeechModelIDs,
        residentBudgetConfirmation: residentSpeechBudgetConfirmation
      )
    }
    return LocalSpeechSettings(
      model: localSpeechModel,
      modelRepo: legacyWhisperKitModelRepo,
      modelToken: legacyWhisperKitModelToken,
      modelFolder: legacyWhisperKitModelFolder,
      language: legacyWhisperKitLanguage,
      downloadIfNeeded: legacyWhisperKitDownloadIfNeeded,
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

  /// Compatibility warmup for installations that do not expose the v5 model
  /// pool. Current builds synchronize `residentModelIDs` directly and keep
  /// microphone initialization entirely outside model preparation.
  func queueLocalSpeechReadinessIfNeeded() {
    localSpeechPreparationTaskOwner.cancelActive()
    localSpeechReadinessGeneration += 1
    let generation = localSpeechReadinessGeneration
    guard !hasBegunApplicationShutdown,
      !isLoadingSettings,
      !isRestoringSettings,
      !hasUnavailableScalarSettings(in: .localSpeech),
      localSpeechTrustMaterialAvailable,
      preferredSpeechEngine == .local,
      !trustedLocalSpeechModels.contains(where: { $0.engine == .mlxAudioSwift })
    else {
      return
    }
    let settings = currentLocalSpeechSettings()
    guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    let operationID = UUID()
    let progressRelay = LocalSpeechPreparationProgressRelay(
      model: self,
      operationID: operationID
    )
    let taskOwner = localSpeechPreparationTaskOwner
    let task = Task { [weak self, warmLocalSpeechForCaptureAction, taskOwner] in
      let shouldStartProvider = await MainActor.run {
        guard let self,
          !self.hasBegunApplicationShutdown,
          taskOwner.isActive(id: operationID),
          self.localSpeechReadinessGeneration == generation
        else {
          return false
        }
        self.localSpeechPreparationState = .preparing
        self.localSpeechPreparationProgress = 0
        self.localSpeechPreparedModelIdentifier = nil
        self.localSpeechPreparationError = nil
        return true
      }
      guard shouldStartProvider, !Task.isCancelled else {
        await MainActor.run {
          taskOwner.finish(id: operationID)
        }
        return
      }
      let result: Result<String, Error>
      do {
        result = .success(
          try await warmLocalSpeechForCaptureAction(
            settings,
            { progress in
              Task {
                await progressRelay.update(progress: progress)
              }
            }
          ))
      } catch {
        result = .failure(error)
      }
      let wasCancelled = Task.isCancelled
      await MainActor.run {
        let shouldPublish =
          !wasCancelled
          && taskOwner.isActive(id: operationID)
          && self?.hasBegunApplicationShutdown == false
          && self?.localSpeechReadinessGeneration == generation
        taskOwner.finish(id: operationID)
        guard shouldPublish, let self else { return }

        switch result {
        case .success(let preparedModel):
          guard
            self.acceptsPreparedLocalSpeechModel(
              preparedModel,
              requestedModel: settings.model
            )
          else {
            self.localSpeechPreparationState = .idle
            self.localSpeechPreparationProgress = 0
            self.localSpeechPreparedModelIdentifier = nil
            self.applyLocalSpeechPreparationFailure(
              LocalSpeechPreparationFailure(stage: .trustRoot)
            )
            return
          }
          self.localSpeechPreparationState = .ready
          self.localSpeechPreparationProgress = 1
          self.localSpeechPreparedModelIdentifier = preparedModel
          self.localSpeechPreparationError = nil
          self.recordDownloadedLocalSpeechModel(preparedModel)
        case .failure(is CancellationError):
          self.localSpeechPreparationState = .idle
          self.localSpeechPreparationProgress = 0
          self.localSpeechPreparedModelIdentifier = nil
        case .failure(let error):
          self.localSpeechPreparationState = .idle
          self.localSpeechPreparationProgress = 0
          self.localSpeechPreparedModelIdentifier = nil
          self.applyLocalSpeechPreparationFailure(error)
        }
      }
    }
    _ = taskOwner.replaceActive(id: operationID, with: task)
  }

  func addVocabularyRule(
    kind: VocabularyRuleKind,
    pattern: String,
    replacement: String,
    matchMode: VocabularyMatchMode,
    caseSensitive: Bool,
    scope: VocabularyRuleScope,
    priority: Int = 0
  ) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPattern.isEmpty else { return }
    let rule = VocabularyRule(
      kind: kind,
      enabled: true,
      pattern: trimmedPattern,
      replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
      matchMode: matchMode,
      caseSensitive: caseSensitive,
      scope: scope,
      priority: priority
    )
    insertVocabularyRule(rule)
  }

  func createVocabularyCollection(named name: String) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    vocabularyCollections.append(VocabularyCollection(name: name))
    commitVocabularyLibraryChange()
  }

  func setVocabularyCollectionEnabled(_ collectionID: UUID, isEnabled: Bool) {
    guard let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) else { return }
    vocabularyCollections[index].enabled = isEnabled
    vocabularyCollections[index].updatedAt = Date()
    commitVocabularyLibraryChange()
  }

  func deleteVocabularyCollection(_ collectionID: UUID) {
    guard collectionID != VocabularyCollection.personalID else { return }
    vocabularyCollections.removeAll { $0.id == collectionID }
    vocabularyCollectionBindings.removeAll { $0.collectionID == collectionID }
    workflowCustomizations = workflowCustomizations.map { customization in
      var customization = customization
      customization.vocabularyBindings?.removeAll {
        $0.collectionID == collectionID
      }
      return customization
    }
    commitVocabularyLibraryChange()
    persistWorkflowLibrary()
  }

  func setVocabularyBindings(
    _ bindings: [VocabularyCollectionBinding],
    for workflowID: UUID
  ) {
    if let index = workflowCustomizations.firstIndex(where: {
      $0.workflowID == workflowID
    }) {
      workflowCustomizations[index].vocabularyBindings = bindings
    } else {
      workflowCustomizations.append(
        WorkflowCustomization(
          workflowID: workflowID,
          vocabularyBindings: bindings
        )
      )
    }
    rebuildWorkflowLibrary()
    persistWorkflowLibrary()
  }

  func addVocabularyEntry(
    to collectionID: UUID,
    kind: VocabularyRuleKind,
    pattern: String,
    replacement: String = ""
  ) {
    guard let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) else { return }
    let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return }
    let content: VocabularyEntryContent =
      kind == .hotword
      ? .hotword(phrase: pattern)
      : .replacement(
        pattern: pattern,
        replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
        matchMode: .exactPhrase,
        caseSensitive: false
      )
    vocabularyCollections[index].entries.append(
      VocabularyEntry(content: content)
    )
    vocabularyCollections[index].updatedAt = Date()
    commitVocabularyLibraryChange()
  }

  func deleteVocabularyEntry(_ entryID: UUID, from collectionID: UUID) {
    guard let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) else { return }
    vocabularyCollections[index].entries.removeAll { $0.id == entryID }
    vocabularyCollections[index].updatedAt = Date()
    commitVocabularyLibraryChange()
  }

  private func commitVocabularyLibraryChange() {
    isApplyingVocabularyLibrary = true
    let scopeByCollectionID = Dictionary(
      uniqueKeysWithValues: vocabularyCollectionBindings.map { binding in
        (
          binding.collectionID,
          VocabularyRuleScope(
            bundleIdentifier: binding.condition.bundleIdentifier,
            recordCollectionID: binding.condition.recordCollectionID,
            locale: binding.condition.locale
          )
        )
      }
    )
    vocabularyRules = Self.sortedVocabularyRules(
      vocabularyCollections.flatMap { collection in
        let scope = scopeByCollectionID[collection.id] ?? VocabularyRuleScope()
        return collection.entries.map { $0.legacyRule(scope: scope) }
      }
    )
    isApplyingVocabularyLibrary = false
    vocabularyRuleSource.updateCollections(vocabularyCollections)
    rebuildWorkflowLibrary()
    persistVocabularyLibrary()
  }

  @discardableResult
  public func saveVocabularyCorrectionRule(_ proposedRule: VocabularyRule)
    -> VocabularyCorrectionSaveOutcome
  {
    saveVocabularyCorrectionRule(proposedRule, to: nil)
  }

  @discardableResult
  public func saveVocabularyCorrectionRule(
    _ proposedRule: VocabularyRule,
    to targetCollectionID: UUID?
  ) -> VocabularyCorrectionSaveOutcome
  {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return .notReady }
    let pattern = proposedRule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return .invalid }

    var rule = proposedRule
    rule.pattern = pattern
    rule.replacement = proposedRule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    if rule.kind == .hotword {
      rule.replacement = ""
      rule.matchMode = .exactPhrase
      rule.caseSensitive = false
    }

    if let existing = vocabularyRules.first(where: { existing in
      existing.kind == rule.kind && existing.pattern == rule.pattern
        && existing.matchMode == rule.matchMode && existing.caseSensitive == rule.caseSensitive
        && existing.scope == rule.scope
    }) {
      guard existing.replacement == rule.replacement else {
        return .conflict(existingRuleID: existing.id)
      }
      if !existing.enabled {
        setVocabularyRuleEnabled(existing.id, isEnabled: true)
      }
      return .reused(ruleID: existing.id)
    }

    if let targetCollectionID {
      let condition = WorkflowBindingCondition(
        bundleIdentifier: rule.scope.bundleIdentifier,
        recordCollectionID: rule.scope.recordCollectionID,
        locale: rule.scope.locale
      )
      guard vocabularyCollections.contains(where: { $0.id == targetCollectionID }),
        vocabularyCollectionBindings.contains(where: {
          $0.collectionID == targetCollectionID && $0.condition == condition
        })
      else {
        return .invalid
      }
    }

    insertVocabularyRule(rule, targetCollectionID: targetCollectionID)
    return .created(ruleID: rule.id)
  }

  func vocabularyCollectionIDs(compatibleWith scope: VocabularyRuleScope) -> [UUID] {
    let condition = WorkflowBindingCondition(
      bundleIdentifier: scope.bundleIdentifier,
      recordCollectionID: scope.recordCollectionID,
      locale: scope.locale
    )
    let compatibleIDs = Set(
      vocabularyCollectionBindings.lazy
        .filter { $0.condition == condition }
        .map(\.collectionID)
    )
    return vocabularyCollections
      .filter { compatibleIDs.contains($0.id) }
      .map(\.id)
  }

  func setVocabularyRuleEnabled(_ ruleID: UUID, isEnabled: Bool) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    for collectionIndex in vocabularyCollections.indices {
      guard let entryIndex = vocabularyCollections[collectionIndex].entries.firstIndex(
        where: { $0.id == ruleID }
      ) else { continue }
      vocabularyCollections[collectionIndex].entries[entryIndex].enabled = isEnabled
      vocabularyCollections[collectionIndex].updatedAt = Date()
      commitVocabularyLibraryChange()
      return
    }
  }

  func deleteVocabularyRule(_ ruleID: UUID) {
    guard !isLoadingSettings, areVocabularyRulesAvailable else { return }
    for index in vocabularyCollections.indices {
      let oldCount = vocabularyCollections[index].entries.count
      vocabularyCollections[index].entries.removeAll { $0.id == ruleID }
      if vocabularyCollections[index].entries.count != oldCount {
        vocabularyCollections[index].updatedAt = Date()
        commitVocabularyLibraryChange()
        return
      }
    }
  }

  private func insertVocabularyRule(
    _ rule: VocabularyRule,
    targetCollectionID: UUID? = nil
  ) {
    let condition = WorkflowBindingCondition(
      bundleIdentifier: rule.scope.bundleIdentifier,
      recordCollectionID: rule.scope.recordCollectionID,
      locale: rule.scope.locale
    )
    let collectionID: UUID
    if let targetCollectionID {
      collectionID = targetCollectionID
    } else if rule.scope == VocabularyRuleScope() {
      collectionID = VocabularyCollection.personalID
    } else if let binding = vocabularyCollectionBindings.first(where: {
      $0.condition == condition
    }) {
      collectionID = binding.collectionID
    } else {
      let migration = VocabularyLegacyMigrator.migrate([rule])
      guard let collection = migration.collections.first,
        let binding = migration.bindings.first
      else { return }
      vocabularyCollections.append(
        VocabularyCollection(
          id: collection.id,
          name: collection.name,
          entries: []
        )
      )
      vocabularyCollectionBindings.append(binding)
      collectionID = collection.id
    }

    if let index = vocabularyCollections.firstIndex(where: {
      $0.id == collectionID
    }) {
      vocabularyCollections[index].entries.append(VocabularyEntry(rule: rule))
      vocabularyCollections[index].updatedAt = Date()
    } else {
      vocabularyCollections.append(
        .personal(entries: [VocabularyEntry(rule: rule)])
      )
    }
    commitVocabularyLibraryChange()
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
    let document = VocabularyLibraryDocument(collections: vocabularyCollections)
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
      collections: vocabularyCollections
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
      values = try Self.privacySettingsStorageValues(for: policy)
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
    registerPersistenceWrite(task)
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
        let policy = try Self.decodePrivacyPolicySettings(from: snapshot.values)
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

  static func privacySettingsStorageValues(
    for policy: PrivacyPolicySettings
  ) throws -> [AppSettingKey: String] {
    let rules = try SensitiveAppRule.mergingRecommendedDefaults(with: policy.sensitiveAppRules)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(rules)
    return [
      .privacySensitiveAppRules: String(decoding: data, as: UTF8.self),
      .privacyCloudConfirmationRequired: policy.cloudConfirmationRequired ? "true" : "false",
      .privacyCloudProcessingAuthorizations: String(
        decoding: try encoder.encode(policy.cloudProcessingAuthorizations),
        as: UTF8.self
      ),
      .privacyHistoryPreviewMode: policy.historyPreviewMode.rawValue,
      .privacySecureInputConservativeMode: policy.secureInputConservativeMode ? "true" : "false",
    ]
  }

  static func decodePrivacyPolicySettings(
    from values: [AppSettingKey: String]
  ) throws -> PrivacyPolicySettings {
    var policy = PrivacyPolicySettings.defaults
    if let rawRules = values[.privacySensitiveAppRules], !rawRules.isEmpty {
      let decoded = try JSONDecoder().decode(
        [SensitiveAppRule].self,
        from: Data(rawRules.utf8)
      )
      policy.sensitiveAppRules = try SensitiveAppRule.mergingRecommendedDefaults(with: decoded)
    }
    if let rawCloudConfirmation = values[.privacyCloudConfirmationRequired] {
      policy.cloudConfirmationRequired = storedBoolean(
        rawCloudConfirmation,
        defaultValue: true
      )
    }
    if let rawAuthorizations = values[.privacyCloudProcessingAuthorizations],
      !rawAuthorizations.isEmpty
    {
      let authorizations = try JSONDecoder().decode(
        [CloudProcessingAuthorization].self,
        from: Data(rawAuthorizations.utf8)
      )
      guard Set(authorizations.map(\.id)).count == authorizations.count,
        Set(authorizations.map(\.workflowID)).count == authorizations.count,
        authorizations.allSatisfy({ !$0.scopeFingerprint.isEmpty })
      else {
        throw PrivacyPolicySettingsSourceError.unavailable(
          "Cloud-processing authorizations are invalid."
        )
      }
      policy.cloudProcessingAuthorizations = authorizations
    }
    if let rawHistoryPreviewMode = values[.privacyHistoryPreviewMode],
      let historyPreviewMode = PrivacyHistoryPreviewMode(rawValue: rawHistoryPreviewMode)
    {
      policy.historyPreviewMode = historyPreviewMode
    }
    if let rawSecureInputMode = values[.privacySecureInputConservativeMode] {
      policy.secureInputConservativeMode = storedBoolean(
        rawSecureInputMode,
        defaultValue: true
      )
    }
    return policy
  }

  private func localizedPrivacySettingsSaveFailure() -> String {
    L10n.runText(.privacySaveFailedSessionOnly, language: language)
  }

  static func storedBoolean(_ value: String, defaultValue: Bool) -> Bool {
    storedBooleanIfValid(value) ?? defaultValue
  }

  static func storedBooleanIfValid(_ value: String) -> Bool? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": true
    case "0", "false", "no", "off": false
    default: nil
    }
  }

  static func invalidScalarSettingKeys(
    in values: [AppSettingKey: String]
  ) -> Set<AppSettingKey> {
    var invalidKeys: Set<AppSettingKey> = []

    if let value = values[.interfaceLanguage], AppLanguage(rawValue: value) == nil {
      invalidKeys.insert(.interfaceLanguage)
    }
    if let value = values[.recordHistoryVisibility],
      RecordHistoryVisibility(rawValue: value) == nil
    {
      invalidKeys.insert(.recordHistoryVisibility)
    }
    if let value = values[.systemClipboardCaptureEnabled], storedBooleanIfValid(value) == nil {
      invalidKeys.insert(.systemClipboardCaptureEnabled)
    }
    if let value = values[.recordMergeSimilar], storedBooleanIfValid(value) == nil {
      invalidKeys.insert(.recordMergeSimilar)
    }
    if let value = values[.recordPanelHotkey],
      HotkeyBindingDescriptor(storageString: value).storageString != value
    {
      invalidKeys.insert(.recordPanelHotkey)
    }
    if let value = values[.preferredSpeechEngine],
      PreferredSpeechEngine(rawValue: value) == nil
    {
      invalidKeys.insert(.preferredSpeechEngine)
    }
    if let value = values[.localSpeechPrewarm], storedBooleanIfValid(value) == nil {
      invalidKeys.insert(.localSpeechPrewarm)
    }
    if let value = values[.speechModelMeasuredPeaks],
      (try? loadMeasuredSpeechModelPeaks(from: value)) == nil
    {
      invalidKeys.insert(.speechModelMeasuredPeaks)
    }
    if let value = values[.builtinPushToTalkOutputMode],
      BuiltinPushToTalkOutputMode(rawValue: value) == nil
    {
      invalidKeys.insert(.builtinPushToTalkOutputMode)
    }
    if let value = values[.longRecordingModeEnabled], storedBooleanIfValid(value) == nil {
      invalidKeys.insert(.longRecordingModeEnabled)
    }
    if let value = values[.recordingDurationLimit],
      RecordingDurationLimit(rawValue: value) == nil
    {
      invalidKeys.insert(.recordingDurationLimit)
    }
    if let value = values[.openAIBaseURL],
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !OpenAISettings.isValidBaseURL(value)
    {
      invalidKeys.insert(.openAIBaseURL)
    }
    if let value = values[.openAIModel],
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !OpenAISettings.isValidModelIdentifier(value)
    {
      invalidKeys.insert(.openAIModel)
    }

    return invalidKeys
  }

  func persistWorkflowEnabledStates() {
    markSettingModifiedDuringInitialLoad(.workflowEnabledStates)
    guard !isRestoringSettings, isWorkflowLibraryAvailable else { return }
    let disabledStates =
      workflowEnabledStates
      .filter { !$0.value }
      .reduce(into: [String: Bool]()) { partialResult, entry in
        partialResult[entry.key.uuidString] = entry.value
      }

    persistRetryableSettingsStoreWrite(
      for: .workflowEnabledStates,
      category: .workflows
    ) { settingsStore in
      if disabledStates.isEmpty {
        try await settingsStore.removeValue(forKey: .workflowEnabledStates)
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(disabledStates)
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
