import Foundation
import RillCore

extension SettingsPersistenceModel {
  public func languageModelSettings() -> OpenAISettings {
    OpenAISettings(apiKey: openAIAPIKey, baseURL: openAIBaseURL, model: openAIModel)
  }
  public func credentialAvailability() -> OpenAICredentialAvailability { openAICredentialAvailability }
  func setCredentialAvailability(_ value: OpenAICredentialAvailability) { openAICredentialAvailability = value }
  public func verificationState() -> OpenAIConfigurationVerificationState { openAIConfigurationVerificationState }
  public func verificationFailure() -> OpenAIVerificationFailure? { openAIVerificationFailure }
  func verificationTaskOwner() -> ReplacingTaskOwner { openAIVerificationTaskOwner }
  func setVerification(_ state: OpenAIConfigurationVerificationState, failure: OpenAIVerificationFailure?) {
    openAIConfigurationVerificationState = state
    openAIVerificationFailure = failure
  }
  public var canVerifyOpenAIConfiguration: Bool { canVerifyLanguageModel() }
  public func canVerifyLanguageModel() -> Bool {
    !hasBegunApplicationShutdown && !isLoading
      && openAICredentialAvailability == .available && !hasUnavailableScalarSettings(in: .openAI)
      && (try? LanguageModelConfiguration(migrating: languageModelSettings()).validate()) != nil
      && !LanguageModelConfiguration(migrating: languageModelSettings()).supportedReasoningLevels.isEmpty
      && openAIConfigurationVerificationState != .verifying
  }
  public func verifyOpenAIConfiguration() {
    guard canVerifyLanguageModel() else { return }
    let owner = openAIVerificationTaskOwner
    owner.cancel()
    verificationGeneration &+= 1
    let generation = verificationGeneration
    let settings = languageModelSettings()
    setVerification(.verifying, failure: nil)
    let taskID = UUID()
    let task = Task { @MainActor [weak self, owner] in
      defer { owner.finish(id: taskID) }
      guard let self else { return }
      do {
        try await self.verifyOpenAIConfigurationAction(settings)
        guard !Task.isCancelled, !self.hasBegunApplicationShutdown, self.verificationGeneration == generation else { return }
        self.setVerification(.verified, failure: nil)
        self.configurationChanged()
      } catch is CancellationError {
        guard self.verificationGeneration == generation else { return }
        self.setVerification(.idle, failure: nil)
      } catch {
        guard !self.hasBegunApplicationShutdown, self.verificationGeneration == generation else { return }
        self.setVerification(.failed, failure: (error as? any OpenAIVerificationFailureProviding)?.openAIVerificationFailure ?? .unknown)
        self.configurationChanged()
      }
    }
    owner.replace(id: taskID, with: task)
  }
}
