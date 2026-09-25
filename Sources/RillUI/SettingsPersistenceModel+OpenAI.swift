import Foundation
import RillCore

extension SettingsPersistenceModel {
  public var canVerifyOpenAIConfiguration: Bool {
    !hasBegunApplicationShutdown
      && !self.isLoading
      && self.openAICredentialAvailability == .available
      && !hasUnavailableScalarSettings(in: .openAI)
      && OpenAISettings.isValidBaseURL(self.openAIBaseURL)
      && OpenAISettings.isValidModelIdentifier(self.openAIModel)
      && self.openAIConfigurationVerificationState != .verifying
  }

  public func verifyOpenAIConfiguration() {
    guard canVerifyOpenAIConfiguration else { return }
    self.openAIVerificationTaskOwner.cancel()
    self.openAIVerificationGeneration &+= 1
    let generation = self.openAIVerificationGeneration
    let settings = OpenAISettings(
      apiKey: self.openAIAPIKey,
      baseURL: self.openAIBaseURL,
      model: self.openAIModel
    )
    self.openAIVerificationFailure = nil
    self.openAIConfigurationVerificationState = .verifying
    let taskID = UUID()
    let owner = openAIVerificationTaskOwner
    let task = Task { @MainActor [weak self, owner] in
      defer { owner.finish(id: taskID) }
      guard let self else { return }
      do {
        try await self.verifyOpenAIConfigurationAction(settings)
        guard
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.openAIVerificationGeneration == generation
        else {
          return
        }
        self.openAIVerificationFailure = nil
        self.openAIConfigurationVerificationState = .verified
        self.configurationChanged()
      } catch is CancellationError {
        guard self.openAIVerificationGeneration == generation else { return }
        self.openAIVerificationFailure = nil
        self.openAIConfigurationVerificationState = .idle
      } catch {
        guard
          !self.hasBegunApplicationShutdown,
          self.openAIVerificationGeneration == generation
        else {
          return
        }
        self.openAIVerificationFailure =
          (error as? any OpenAIVerificationFailureProviding)?.openAIVerificationFailure
          ?? .unknown
        self.openAIConfigurationVerificationState = .failed
        self.configurationChanged()
      }
    }
    owner.replace(id: taskID, with: task)
  }
}
