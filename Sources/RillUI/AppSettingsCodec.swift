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
    workflowLibrarySettingKey,
    .workflowEnabledStates,
    .systemClipboardCaptureEnabled,
    .legacyClipboardCaptureEnabled,
    .recordMergeSimilar,
    .legacyClipboardMergeSimilarItems,
    .recordHistoryVisibility,
    .legacyClipboardHistoryVisibility,
    .recordPanelHotkey,
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
    .benchmarkRecordingArchiveEnabled,
    .builtinPushToTalkOutputMode,
    .longRecordingModeEnabled,
    .recordingDurationLimit,
  ]
  static let localSpeechRecognizerID = "local-speech"
  static let sherpaOnnxRecognizerID = "sherpa-onnx.local"
  static let sherpaStreamingRecognizerID = "sherpa-onnx.streaming"
  static let workflowOriginMetadataKey = "workflow.origin"
  static let userWorkflowOriginMetadataValue = "user"
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

  static func loadAndMigrateWorkflowFiles(
    from workflowFileStore: (any WorkflowFileStore)?,
    legacyWorkflows: [WorkflowDefinition],
    enabledStates: [UUID: Bool]
  ) async -> InitialWorkflowFileLoad? {
    guard let workflowFileStore else { return nil }
    var initial = await workflowFileStore.load()
    guard !legacyWorkflows.isEmpty else {
      return InitialWorkflowFileLoad(result: initial, didMigrateLegacyWorkflows: false)
    }
    do {
      guard initial.issues.isEmpty else { throw WorkflowFileMigrationError.verificationFailed }
      let existingIDs = Set(initial.records.map { $0.workflow.id })
      for workflow in legacyWorkflows.sorted(by: { $0.id.uuidString < $1.id.uuidString })
      where !existingIDs.contains(workflow.id) {
        _ = try await workflowFileStore.saveDocument(
          WorkflowDocument(
            workflow: normalizeCustomWorkflow(workflow),
            isEnabled: enabledStates[workflow.id] ?? true),
          replacing: nil, expected: .missing)
      }
      initial = await workflowFileStore.load()
      guard initial.issues.isEmpty,
        Set(legacyWorkflows.map(\.id)).isSubset(of: Set(initial.records.map { $0.workflow.id }))
      else { throw WorkflowFileMigrationError.verificationFailed }
      return InitialWorkflowFileLoad(result: initial, didMigrateLegacyWorkflows: true)
    } catch {
      // A save may have committed before reporting a later failure.
      initial = await workflowFileStore.load()
      initial.issues.append(
        WorkflowFileIssue(
          filename: workflowFileStore.configurationDirectoryURL.lastPathComponent,
          message:
            "Existing workflows could not be migrated to TOML; the legacy library remains active."))
      return InitialWorkflowFileLoad(result: initial, didMigrateLegacyWorkflows: false)
    }
  }

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
        vocabularyBindings =
          library.defaultBindings ?? workflowCustomizations.lazy.compactMap(\.vocabularyBindings)
          .first
          ?? customWorkflows.lazy.map(\.plan.setup.vocabularyBindings).first {
            !$0.isEmpty
          }
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
      customWorkflows: customWorkflows,
      workflowCustomizations: workflowCustomizations,
      workflowLibraryNeedsMigration:
        storedSettings[Self.workflowLibrarySettingKey] == nil
        && storedSettings[.customWorkflows] != nil,
      workflowEnabledStates: workflowEnabledStates,
      systemClipboardCaptureEnabled: storedSettings[.systemClipboardCaptureEnabled]
        ?? storedSettings[.legacyClipboardCaptureEnabled],
      recordHistoryVisibility: storedSettings[.recordHistoryVisibility]
        ?? storedSettings[.legacyClipboardHistoryVisibility],
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
      benchmarkRecordingArchiveEnabled: storedSettings[.benchmarkRecordingArchiveEnabled],
      builtinPushToTalkOutputMode: storedSettings[.builtinPushToTalkOutputMode],
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
    case .contextFeatureSettings, .selectedWorkflowID,
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
        customWorkflows =
          workflowFiles == nil
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
    guard
      Set(document.customWorkflows.map(\.id)).count
        == document.customWorkflows.count
    else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    guard
      Set(document.customizations.map(\.workflowID)).count
        == document.customizations.count
    else {
      throw StoredSettingsCollectionValidationError.duplicateIdentifier
    }
    for workflow in document.customWorkflows {
      let input: WorkflowInputKind =
        workflow.inputKind
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

}
