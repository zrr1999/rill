import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct LLMProviderSettingsTests {
  @Test func failedSettingsLoadMakesBothRolesUnavailable() async {
    let model = makeHarness(settingsStore: UITestSettingsStore(failBatchReads: true)).model
    await model.waitForInitialVoiceConfiguration()
    for role in LanguageModelRole.allCases {
      #expect(model.settings.credentialAvailability(for: role) == .inaccessible)
      #expect(!model.settings.canVerifyLanguageModel(role))
    }
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func migrationRetryDoesNotCopyCredentialsBeforeTheDestinationIsSaved() async throws {
    let store = UITestSettingsStore(storage: [.openAIBaseURL: "https://api.deepseek.com", .openAIModel: "deepseek-flash"])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "original-key"])
    await store.rejectNextAtomicWrite()
    let model = makeHarness(settingsStore: store, credentialStore: credentials).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.intelligentCredentialAvailability == .inaccessible)
    #expect(try await credentials.credential(for: .intelligentAPIKey) == nil)
    #expect(try await store.string(forKey: .languageModelRolesMigrated) == nil)
    model.retryOpenAICredentialLoad(for: .intelligent)
    await model.settings.settingsReadTaskOwner.waitForActiveTask(in: .scalarSettingsRetry(.intelligent))
    #expect(model.settings.intelligentCredentialAvailability == .available)
    #expect(model.settings.intelligentBaseURL == "https://api.deepseek.com")
    #expect(model.settings.intelligentAPIKey == "original-key")
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func migratesOnceAndKeepsIndependentRoleSelections() async throws {
    let store = UITestSettingsStore(storage: [.openAIBaseURL: "https://api.deepseek.com", .openAIModel: "deepseek-flash"])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "original-key"])
    let model = makeHarness(settingsStore: store, credentialStore: credentials, settingsWriteDebounceDuration: .zero).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.languageModelSettings(for: .fast) == model.settings.languageModelSettings(for: .intelligent))
    #expect(try await store.string(forKey: .languageModelRolesMigrated) == "true")
    #expect(try await credentials.credential(for: .intelligentAPIKey) == "original-key")
    model.setLanguageModelBaseURL("https://api.openai.com/v1", for: .intelligent)
    model.setLanguageModelIdentifier("gpt-6-astra", for: .intelligent)
    model.setLanguageModelAPIKey("smart-key", for: .intelligent)
    await model.flushPendingPersistenceWrites()
    #expect(model.settings.openAIModel == "deepseek-flash")
    let reloaded = makeHarness(settingsStore: store, credentialStore: credentials).model
    await reloaded.waitForInitialVoiceConfiguration()
    #expect(reloaded.settings.intelligentModel == "gpt-6-astra")
    #expect(reloaded.settings.intelligentAPIKey == "smart-key")
    #expect(reloaded.settings.openAIAPIKey == "original-key")
    await model.stopSettingsReadTasksForApplicationShutdown()
    await reloaded.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func inaccessibleIntelligentSettingsDoNotBlockFastWorkflows() async throws {
    let store = UITestSettingsStore(storage: [.languageModelRolesMigrated: "true"], unavailableKeys: [.intelligentModel])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "fast-key"])
    let model = makeHarness(settingsStore: store, credentialStore: credentials).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.credentialAvailability(for: .fast) == .available)
    #expect(model.settings.credentialAvailability(for: .intelligent) == .inaccessible)
    #expect(model.settings.canVerifyLanguageModel(.fast))
    #expect(!model.settings.canVerifyLanguageModel(.intelligent))
    await model.stopSettingsReadTasksForApplicationShutdown()
  }

  @Test func sharedSettingsKeepExistingStorageAndVerifyTheConfiguredProvider() async throws {
    let settings = UITestSettingsStore(storage: [
      .openAIBaseURL: "https://gateway.example/v1",
      .openAIModel: "existing-model",
    ])
    let credentials = UITestSecureCredentialStore(storage: [.openAIAPIKey: "existing-key"])
    let verification = LLMVerificationProbe()
    let model = makeHarness(
      settingsStore: settings, credentialStore: credentials,
      settingsWriteDebounceDuration: .zero,
      verifyOpenAIConfigurationAction: { settings, _ in await verification.record(settings) }
    ).model
    await model.waitForInitialVoiceConfiguration()
    #expect(model.settings.openAIAPIKey == "existing-key")
    #expect(model.settings.openAIBaseURL == "https://gateway.example/v1")
    SettingsView(model: model).llmModelSelection.wrappedValue = .deepSeek
    await model.flushPendingPersistenceWrites()
    #expect(try await settings.string(forKey: .openAIModel) == "deepseek-flash")
    #expect(try await credentials.credential(for: .openAIAPIKey) == "existing-key")
    #expect(model.settings.openAIBaseURL == "https://gateway.example/v1")
    model.settings.verifyOpenAIConfiguration()
    await model.settings.waitForOpenAIVerificationTasks()
    #expect(model.settings.openAIConfigurationVerificationState == .verified)
    #expect(
      await verification.settings
        == OpenAISettings(
          apiKey: "existing-key", baseURL: "https://gateway.example/v1", model: "deepseek-flash"
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
    #expect(L10n.string(.settingsOpenAITitle, language: .english) == "LLM Provider")
    #expect(L10n.string(.settingsOpenAITitle, language: .simplifiedChinese) == "LLM Provider")
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }
}

private actor LLMVerificationProbe {
  private(set) var settings: OpenAISettings?
  func record(_ settings: OpenAISettings) { self.settings = settings }
}
