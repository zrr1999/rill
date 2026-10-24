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
  public func setLanguageModelAPIKey(_ value: String) {
    guard !hasBegunApplicationShutdown, settings.credentialAvailability() != .inaccessible else { return }
    applyLanguageModelAPIKey(value)
  }

  public func setLanguageModelBaseURL(_ value: String) {
    guard settings.canMutateScalarSettings(in: .openAI) else { return }
    applyLanguageModelBaseURL(value)
  }

  public func setLanguageModelIdentifier(_ value: String) {
    guard settings.canMutateScalarSettings(in: .openAI) else { return }
    applyLanguageModelIdentifier(value)
  }

  func applyLanguageModelAPIKey(_ value: String) {
    guard settings.languageModelSettings().apiKey != value else { return }
    settings.openAIAPIKey = value
    if !settings.isRestoringSettings {
      settings.credentialLoadGeneration &+= 1
      settings.setCredentialAvailability(credentialStore == nil ? .inaccessible : .saving)
    }
    languageModelConfigurationChanged()
    persistSecureCredential(value, for: SecureCredentialKey.openAIAPIKey, taskKey: SecureCredentialKey.openAIAPIKey.legacySettingKey)
  }

  func applyLanguageModelBaseURL(_ value: String) {
    guard settings.languageModelSettings().baseURL != value else { return }
    settings.openAIBaseURL = value
    languageModelConfigurationChanged()
    persistStringSetting(value, for: AppSettingKey.openAIBaseURL)
  }

  func applyLanguageModelIdentifier(_ value: String) {
    guard settings.languageModelSettings().model != value else { return }
    settings.openAIModel = value
    languageModelConfigurationChanged()
    persistStringSetting(value, for: AppSettingKey.openAIModel)
  }

  private func languageModelConfigurationChanged() {
    settings.invalidateOpenAIVerification()
    if !settings.isLoading { contextMemory?.invalidateAuthorization() }
    publishLanguageModelSettings()
    workflowLibraryChangedAction()
  }

  func publishLanguageModelSettings() {
    let availability = settings.credentialAvailability()
    let isAvailable = availability == .available || availability == .saving || availability == .missing
    languageModelSettingsSource.update(
      !hasBegunApplicationShutdown && isAvailable && !settings.hasUnavailableScalarSettings(in: .openAI)
        ? settings.languageModelSettings() : nil)
  }
}
