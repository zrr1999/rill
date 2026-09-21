import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct LLMProviderSettingsTests {
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
            verifyOpenAIConfigurationAction: { await verification.record($0) }
        ).model
        await model.waitForInitialVoiceConfiguration()
        #expect(model.openAIAPIKey == "existing-key")
        #expect(model.openAIBaseURL == "https://gateway.example/v1")
        SettingsView(model: model).llmModelSelection.wrappedValue = .deepSeek
        await model.flushPendingPersistenceWrites()
        #expect(try await settings.string(forKey: .openAIModel) == "deepseek-flash")
        #expect(try await credentials.credential(for: .openAIAPIKey) == "existing-key")
        #expect(model.openAIBaseURL == "https://gateway.example/v1")
        model.verifyOpenAIConfiguration()
        await model.openAIVerificationTask?.value
        #expect(model.openAIConfigurationVerificationState == .verified)
        #expect(await verification.settings == OpenAISettings(
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
        model.openAIModel = "vendor/custom-model"
        #expect(selection.wrappedValue == .custom)
        selection.wrappedValue = .luna
        #expect(model.openAIModel == OpenAIModelOption.luna.rawValue)
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
