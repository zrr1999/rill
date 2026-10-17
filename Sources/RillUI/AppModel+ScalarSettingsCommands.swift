import RillCore

extension AppModel {
  @discardableResult
  public func setInterfaceLanguage(_ newLanguage: AppLanguage) -> Bool {
    guard settings.canMutateScalarSettings(in: .interface) else { return false }
    applyLanguage(newLanguage)
    return true
  }

  @discardableResult
  public func setSystemClipboardCaptureEnabled(_ isEnabled: Bool) -> Bool {
    guard settings.canMutateScalarSettings(in: .systemClipboard) else { return false }
    applySystemClipboardCaptureEnabled(isEnabled)
    return true
  }

  @discardableResult
  public func setPreferredSpeechEngine(_ engine: PreferredSpeechEngine) -> Bool {
    guard settings.canMutateScalarSettings(in: .speechRoute),
      engine != .local || localSpeechTrustMaterialAvailable
    else {
      return false
    }
    applyPreferredSpeechEngine(engine)
    return true
  }

  @discardableResult
  public func setPreferredLocalSpeechModel(_ modelIdentifier: String) -> Bool {
    guard settings.canMutateScalarSettings(in: .speechRoute),
      settings.canMutateScalarSettings(in: .localSpeech),
      localSpeechTrustMaterialAvailable,
      trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier })
    else {
      return false
    }

    if self.settings.preferredSpeechEngine == .local {
      selectTrustedLocalSpeechModel(modelIdentifier)
    } else {
      // Set the exact model before enabling the local route so the route
      // transition prepares only the newly selected backend.
      if self.settings.localSpeechModel != modelIdentifier {
        applyLocalSpeechModel(modelIdentifier)
      }
      applyPreferredSpeechEngine(.local)
    }
    return true
  }

  @discardableResult
  public func setPreferredTTSModel(_ modelIdentifier: String) -> Bool {
    guard ttsModelOptions.contains(where: { $0.id == modelIdentifier }) else {
      return false
    }
    applyTTSModelIdentifier(modelIdentifier)
    return true
  }

  @discardableResult
  public func setBuiltinPushToTalkOutputMode(
    _ mode: BuiltinPushToTalkOutputMode
  ) -> Bool {
    guard settings.canMutateScalarSettings(in: .input) else { return false }
    applyBuiltinPushToTalkOutputMode(mode)
    return true
  }

  @discardableResult
  public func setLongRecordingModeEnabled(_ isEnabled: Bool) -> Bool {
    guard settings.canMutateScalarSettings(in: .input) else { return false }
    applyLongRecordingModeEnabled(isEnabled)
    return true
  }

  @discardableResult
  public func setRecordingDurationLimit(_ limit: RecordingDurationLimit) -> Bool {
    guard settings.canMutateScalarSettings(in: .input) else { return false }
    applyRecordingDurationLimit(limit)
    return true
  }
}

extension AppModel {
  public func setOpenAIAPIKey(_ value: String) { setLanguageModelAPIKey(value, for: .fast) }
  public func setOpenAIBaseURL(_ value: String) { setLanguageModelBaseURL(value, for: .fast) }
  public func setOpenAIModel(_ value: String) { setLanguageModelIdentifier(value, for: .fast) }

  public func setLanguageModelAPIKey(_ value: String, for role: LanguageModelRole) {
    guard !hasBegunApplicationShutdown, settings.credentialAvailability(for: role) != .inaccessible else { return }
    applyLanguageModelAPIKey(value, for: role)
  }

  public func setLanguageModelBaseURL(_ value: String, for role: LanguageModelRole) {
    guard settings.canMutateScalarSettings(in: role.settingsDomain) else { return }
    applyLanguageModelBaseURL(value, for: role)
  }

  public func setLanguageModelIdentifier(_ value: String, for role: LanguageModelRole) {
    guard settings.canMutateScalarSettings(in: role.settingsDomain) else { return }
    applyLanguageModelIdentifier(value, for: role)
  }

  func applyLanguageModelAPIKey(_ value: String, for role: LanguageModelRole) {
    guard settings.languageModelSettings(for: role).apiKey != value else { return }
    if role == .fast { settings.openAIAPIKey = value } else { settings.intelligentAPIKey = value }
    if !settings.isRestoringSettings {
      settings.credentialLoadGenerations[role, default: 0] &+= 1
      settings.setCredentialAvailability(credentialStore == nil ? .inaccessible : .saving, for: role)
    }
    languageModelConfigurationChanged(for: role)
    persistSecureCredential(value, for: role.credentialKey, taskKey: role.credentialKey.legacySettingKey)
  }

  func applyLanguageModelBaseURL(_ value: String, for role: LanguageModelRole) {
    guard settings.languageModelSettings(for: role).baseURL != value else { return }
    if role == .fast { settings.openAIBaseURL = value } else { settings.intelligentBaseURL = value }
    languageModelConfigurationChanged(for: role)
    persistStringSetting(value, for: role.baseURLKey)
  }

  func applyLanguageModelIdentifier(_ value: String, for role: LanguageModelRole) {
    guard settings.languageModelSettings(for: role).model != value else { return }
    if role == .fast { settings.openAIModel = value } else { settings.intelligentModel = value }
    languageModelConfigurationChanged(for: role)
    persistStringSetting(value, for: role.modelKey)
  }

  private func languageModelConfigurationChanged(for role: LanguageModelRole) {
    settings.invalidateOpenAIVerification(for: role)
    if !settings.isLoading { contextMemory?.invalidateAuthorization() }
    publishLanguageModelSettings(for: role)
    workflowLibraryChangedAction()
  }

  func publishLanguageModelSettings(for role: LanguageModelRole) {
    let availability = settings.credentialAvailability(for: role)
    let isAvailable = availability == .available || availability == .saving || availability == .missing
    languageModelSettingsSource.update(
      !hasBegunApplicationShutdown && isAvailable && !settings.hasUnavailableScalarSettings(in: role.settingsDomain)
        ? settings.languageModelSettings(for: role) : nil,
      for: role)
  }
}
