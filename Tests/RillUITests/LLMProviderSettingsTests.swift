import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct LLMProviderSettingsTests {
  @Test(arguments: ["", " \t\n"])
  func blankSelectionsRemainEditableAfterReload(blank: String) async throws {
    let store = UITestSettingsStore(storage: [:])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "synthetic-test-key"])
    let model = makeHarness(settingsStore: store, credentialStore: credentials, settingsWriteDebounceDuration: .zero).model
    await model.waitForInitialVoiceConfiguration()
    model.setLanguageModelBaseURL(blank)
    model.setLanguageModelIdentifier(blank)
    await model.flushPendingPersistenceWrites()
    await model.stopSettingsReadTasksForApplicationShutdown()

    let reloaded = makeHarness(settingsStore: store, credentialStore: credentials, settingsWriteDebounceDuration: .zero).model
    await reloaded.waitForInitialVoiceConfiguration()
    #expect(reloaded.settings.languageModelSettings().baseURL == blank)
    #expect(reloaded.settings.languageModelSettings().model == blank)
    #expect(reloaded.settings.canMutateScalarSettings(in: .openAI))
    #expect(reloaded.settings.credentialAvailability() == .available)
    #expect(!reloaded.settings.canVerifyLanguageModel())
    #expect(throws: LanguageModelConfigurationError.invalidConfiguration) {
      try reloaded.languageModelSettingsSource.currentSettings()
    }

    reloaded.setLanguageModelBaseURL("https://api.deepseek.com")
    reloaded.setLanguageModelIdentifier("deepseek-flash")
    await reloaded.flushPendingPersistenceWrites()
    #expect(reloaded.settings.canVerifyLanguageModel())
    #expect(try await store.string(forKey: .openAIBaseURL) == "https://api.deepseek.com")
    #expect(try await store.string(forKey: .openAIModel) == "deepseek-flash")
    #expect(try reloaded.languageModelSettingsSource.currentSettings().baseURL == "https://api.deepseek.com")
    await reloaded.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test
  func retryRestoresBlankSelectionsWithoutUsingDefaults() async {
    let store = UITestSettingsStore(
      storage: [.openAIBaseURL: "", .openAIModel: ""],
      unavailableKeys: [.openAIBaseURL, .openAIModel])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "synthetic-test-key"])
    let model = makeHarness(settingsStore: store, credentialStore: credentials).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.credentialAvailability() == .inaccessible)
    await store.setUnavailableKeys([])
    model.retryUnavailableScalarSettings(in: .openAI)
    await model.settings.settingsReadTaskOwner.waitForActiveTask(in: .scalarSettingsRetry(.openAI))
    #expect(model.settings.languageModelSettings().baseURL == "")
    #expect(model.settings.languageModelSettings().model == "")
    #expect(model.settings.credentialAvailability() == .available)
    #expect(model.settings.canMutateScalarSettings(in: .openAI))
    #expect(!model.settings.canVerifyLanguageModel())
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test
  func malformedNonblankSelectionsRemainUnavailable() async {
    let store = UITestSettingsStore(storage: [
      .openAIBaseURL: "http://public.example/v1", .openAIModel: "invalid model",
    ])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "synthetic-test-key"])
    let model = makeHarness(settingsStore: store, credentialStore: credentials).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.credentialAvailability() == .inaccessible)
    #expect(!model.settings.canMutateScalarSettings(in: .openAI))
    #expect(!model.settings.canVerifyLanguageModel())
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func failedSettingsLoadMakesServiceUnavailable() async {
    let model = makeHarness(settingsStore: UITestSettingsStore(failBatchReads: true)).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.credentialAvailability() == .inaccessible)
    #expect(!model.settings.canVerifyLanguageModel())
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func unifiedServiceKeepsFastConnectionAndDoesNotRewriteStorage() async throws {
    let stored = OpenAISettings(apiKey: "original-key", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
    let store = UITestSettingsStore(storage: [.openAIBaseURL: stored.baseURL, .openAIModel: stored.model])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: stored.apiKey])
    let model = makeHarness(settingsStore: store, credentialStore: credentials, settingsWriteDebounceDuration: .zero).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.languageModelSettings() == stored)
    #expect(try model.languageModelSettingsSource.currentSettings() == stored)
    model.setLanguageModelIdentifier("gpt-6-astra")
    await model.flushPendingPersistenceWrites()
    let reloaded = makeHarness(settingsStore: store, credentialStore: credentials).model
    await reloaded.waitForInitialVoiceConfiguration()
    #expect(reloaded.settings.openAIModel == "gpt-6-astra")
    #expect(reloaded.settings.openAIAPIKey == "original-key")
    await model.stopSettingsReadTasksForApplicationShutdown()
    await reloaded.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func oldIntelligentConnectionIsNeverUsedAsFallback() async throws {
    let settings = UITestSettingsStore(storage: [.intelligentBaseURL: "https://api.deepseek.com", .intelligentModel: "deepseek-flash"])
    let credentials = UITestSecureCredentialStore(storage: [.intelligentAPIKey: "retired-key"])
    let model = makeHarness(settingsStore: settings, credentialStore: credentials).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.openAIAPIKey.isEmpty)
    #expect(model.settings.openAIBaseURL == OpenAISettings.defaultBaseURL)
    #expect(model.settings.credentialAvailability() == .missing)
    #expect(try await credentials.credential(for: .intelligentAPIKey) == "retired-key")
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func sharedSettingsKeepExistingStorageAndVerifyTheConfiguredProvider() async throws {
    let settings = UITestSettingsStore(storage: [
      .openAIBaseURL: "https://api.deepseek.com",
      .openAIModel: "existing-model",
    ])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "existing-key"])
    let verification = LLMVerificationProbe()
    let model = makeHarness(
      settingsStore: settings, credentialStore: credentials,
      settingsWriteDebounceDuration: .zero,
      verifyOpenAIConfigurationAction: { settings in await verification.record(settings) }
    ).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.openAIAPIKey == "existing-key")
    #expect(model.settings.openAIBaseURL == "https://api.deepseek.com")
    SettingsView(model: model).llmModelSelection.wrappedValue = .deepSeek
    await model.flushPendingPersistenceWrites()
    #expect(try await settings.string(forKey: .openAIModel) == "deepseek-flash")
    #expect(try await credentials.credential(for: .openAIAPIKey) == "existing-key")
    #expect(model.settings.openAIBaseURL == "https://api.deepseek.com")
    model.settings.verifyOpenAIConfiguration()
    await model.settings.waitForOpenAIVerificationTasks()
    #expect(model.settings.openAIConfigurationVerificationState == .verified)
    #expect(
      await verification.settings
        == OpenAISettings(
          apiKey: "existing-key", baseURL: "https://api.deepseek.com", model: "deepseek-flash"
        ))
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func deepSeekPresetCanSwitchBackToCustomOrOpenAIModels() async {
    let model = makeHarness(settingsStore: UITestSettingsStore()).model
    await model.waitForInitialVoiceConfiguration()
    let selection = SettingsView(model: model).llmModelSelection
    selection.wrappedValue = .deepSeek
    #expect(selection.wrappedValue == .deepSeek)
    selection.wrappedValue = .custom
    #expect(selection.wrappedValue == .custom)
    model.applyOpenAIModel("vendor/custom-model")
    #expect(selection.wrappedValue == .custom)
    selection.wrappedValue = .luna
    #expect(model.settings.openAIModel == OpenAIModelOption.luna.rawValue)
    #expect(L10n.string(.settingsOpenAITitle, language: .english) == "LLM Service")
    #expect(L10n.string(.settingsOpenAITitle, language: .simplifiedChinese) == "LLM 服务")
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }
}

private actor LLMVerificationProbe {
  private(set) var settings: OpenAISettings?
  func record(_ settings: OpenAISettings) { self.settings = settings }
}
