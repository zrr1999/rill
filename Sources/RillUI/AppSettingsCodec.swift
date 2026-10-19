import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge

enum AppSettingsCodec {
  static let vocabularyRulesSettingKey = AppSettingKey(rawValue: "vocabulary.rules")!
  static let vocabularyLibrarySettingKey = AppSettingKey.vocabularyLibrary
  static let workflowLibrarySettingKey = AppSettingKey.workflowLibrary
  static let settingsLoadKeys: [AppSettingKey] = [
    .interfaceLanguage,
    .customWorkflows,
    .workflowLibrary,
    .systemClipboardCaptureEnabled,
    .legacyClipboardCaptureEnabled,
    .recordMergeSimilar,
    .legacyClipboardMergeSimilarItems,
    .recordHistoryVisibility,
    .legacyClipboardHistoryVisibility,
    .recordPanelHotkey,
    .bufferOutputHotkey,
    .legacyClipboardPanelHotkey,
    .preferredSpeechEngine,
    .localSpeechModel,
    .localSpeechDownloadedModels,
    .localSpeechPrewarm,
    .enabledSpeechModels,
    .residentSpeechModels,
    .residentSpeechBudgetConfirmation,
    .speechModelMeasuredPeaks,
    .ttsModel,
    .legacyWhisperKitModel,
    .legacyWhisperKitDownloadedModels,
    .legacyWhisperKitCustomModel,
    .legacyWhisperKitModelRepo,
    .legacyWhisperKitModelFolder,
    .legacyWhisperKitLanguage,
    .legacyWhisperKitDownloadIfNeeded,
    .legacyWhisperKitPrewarm,
    .openAIBaseURL,
    .openAIModel,

    vocabularyRulesSettingKey,
    vocabularyLibrarySettingKey,
    .privacySensitiveAppRules,
    .privacyCloudConfirmationRequired,
    .privacyCloudProcessingAuthorizations,
    .privacyHistoryPreviewMode,
    .privacySecureInputConservativeMode,
    .recordRetentionPeriod,
    .legacyClipboardHistoryRetentionPeriod,
    .runHistoryRetentionPeriod,
    .failedAudioRecoveryEnabled,
    .corpusRecordingArchiveEnabled,
    .longRecordingModeEnabled,
    .recordingDurationLimit,
  ]
  static let localSpeechRecognizerID = "local-speech"
  static let sherpaOnnxRecognizerID = "sherpa-onnx.local"
  static let sherpaStreamingRecognizerID = "sherpa-onnx.streaming"
  static let privacySettingKeys: Set<AppSettingKey> = [
    .privacySensitiveAppRules,
    .privacyCloudConfirmationRequired,
    .privacyCloudProcessingAuthorizations,
    .privacyHistoryPreviewMode,
    .privacySecureInputConservativeMode,
  ]
  static let openAIConfigurationSettingKeys: Set<AppSettingKey> = [
    .openAIBaseURL,
    .openAIModel,
  ]

  static func resolveLegacyLocalSpeechSetting(
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
    if [AppSettingKey.customWorkflows, .workflowLibrary].contains(where: { !(storedSettings[$0] ?? "").isEmpty }) {
      loadWarnings.append(.legacyWorkflowFormatUnsupported)
    }
    if !unavailableSettingKeys.isEmpty {
      loadWarnings.append(.storedValuesUnavailable)
    }
    if !unavailableSettingKeys.isDisjoint(with: [
      Self.workflowLibrarySettingKey
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
        vocabularyBindings =
          library.defaultBindings
          ?? library.collections.map { collection in
            VocabularyCollectionBinding(collectionID: collection.id)
          }
        vocabularyRules = sortedVocabularyRules(
          VocabularyLegacyMigrator.project(vocabularyCollections, bindings: vocabularyBindings))
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
        VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID)
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
      systemClipboardCaptureEnabled: storedSettings[.systemClipboardCaptureEnabled]
        ?? storedSettings[.legacyClipboardCaptureEnabled],
      recordHistoryVisibility: storedSettings[.recordHistoryVisibility]
        ?? storedSettings[.legacyClipboardHistoryVisibility],
      bufferOutputHotkey: storedSettings[.bufferOutputHotkey],
      recordPanelHotkey: storedSettings[.recordPanelHotkey]
        ?? storedSettings[.legacyClipboardPanelHotkey],
      preferredSpeechEngine: storedSettings[.preferredSpeechEngine],
      ttsModel: storedSettings[.ttsModel],
      localSpeechModel: storedSettings[.localSpeechModel],
      downloadedLocalSpeechModels: downloadedLocalSpeechModels,
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
      corpusRecordingArchiveEnabled: storedSettings[.corpusRecordingArchiveEnabled],
      longRecordingModeEnabled: storedSettings[.longRecordingModeEnabled],
      recordingDurationLimit: storedSettings[.recordingDurationLimit],
      loadWarnings: loadWarnings,
      unavailableDomains: unavailableDomains
    )
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

  static func settingsSaveCategory(for key: AppSettingKey) -> SettingsSaveCategory? {
    switch key {
    case .inputMethodLearning: .input
    case .interfaceLanguage:
      .interface
    case .systemClipboardCaptureEnabled,
      .recordHistoryVisibility,
      .recordPanelHotkey,
      .bufferOutputHotkey,
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
      .openAIBaseURL, .openAIModel:
      .speech
    case .longRecordingModeEnabled, .recordingDurationLimit:
      .input
    case .vocabularyRules, .vocabularyLibrary:
      .vocabulary
    case .customWorkflows, .workflowLibrary, .workflowEnabledStates:
      .workflows
    case .intelligentBaseURL, .intelligentModel, .intelligentAPIKey, .languageModelRolesMigrated, .builtinPushToTalkOutputMode,
      .contextFeatureSettings, .selectedWorkflowID,
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
      .corpusRecordingArchiveEnabled,
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
    guard
      decoded.allSatisfy({ entry in
        let identifier = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier == entry.key
          && !identifier.isEmpty
          && identifier.utf8.count <= 256
          && entry.value > 0
      })
    else {
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
    if let bindings = document.defaultBindings {
      guard Set(bindings.map(\.id)).count == bindings.count else {
        throw StoredSettingsCollectionValidationError.duplicateIdentifier
      }
      let collectionIDs = Set(document.collections.map(\.id))
      guard bindings.allSatisfy({ collectionIDs.contains($0.collectionID) }) else {
        throw StoredSettingsCollectionValidationError.invalidIdentifier
      }
    }
    let entries = document.collections.flatMap(\.entries)
    guard Set(entries.map(\.id)).count == entries.count else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    return document
  }

  static func loadRecoverableStoredSettingsDomains(
    from settingsStore: any SettingsStore,
    workflowFileStore: (any WorkflowFileStore)? = nil
  ) async throws -> RecoverableStoredSettingsDomains {
    let keys: [AppSettingKey] = [
      .localSpeechDownloadedModels,
      .legacyWhisperKitDownloadedModels,
      vocabularyRulesSettingKey,
    ]
    let snapshot = try await settingsStore.settingsSnapshot(forKeys: keys)
    let unavailableKeys = snapshot.unavailableKeys

    let workflowFiles = await workflowFileStore?.load()
    let downloadedResolution = resolveLegacyLocalSpeechSetting(
      currentKey: .localSpeechDownloadedModels, legacyKey: .legacyWhisperKitDownloadedModels, in: snapshot
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
      workflowFiles: workflowFiles,
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
    if let value = values[.bufferOutputHotkey],
      (HotkeyBindingDescriptor(storageString: value).storageString != value
        || value == HotkeyBindingDescriptor.doubleCommand.storageString)
    {
      invalidKeys.insert(.bufferOutputHotkey)
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
    if let value = values[.longRecordingModeEnabled], storedBooleanIfValid(value) == nil {
      invalidKeys.insert(.longRecordingModeEnabled)
    }
    if let value = values[.recordingDurationLimit],
      RecordingDurationLimit(rawValue: value) == nil
    {
      invalidKeys.insert(.recordingDurationLimit)
    }
    do {
      if let value = values[AppSettingKey.openAIBaseURL],
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !OpenAISettings.isValidBaseURL(value)
      {
        invalidKeys.insert(AppSettingKey.openAIBaseURL)
      }
      if let value = values[AppSettingKey.openAIModel],
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !OpenAISettings.isValidModelIdentifier(value)
      {
        invalidKeys.insert(AppSettingKey.openAIModel)
      }
    }

    return invalidKeys
  }

}
