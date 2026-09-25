import RillCore

extension AppModel {
  public var canVerifyOpenAIConfiguration: Bool {
    !hasBegunApplicationShutdown
      && !self.settings.isLoading
      && self.settings.openAICredentialAvailability == .available
      && !hasUnavailableScalarSettings(in: .openAI)
      && OpenAISettings.isValidBaseURL(self.settings.openAIBaseURL)
      && OpenAISettings.isValidModelIdentifier(self.settings.openAIModel)
      && self.settings.openAIConfigurationVerificationState != .verifying
  }

  public func verifyOpenAIConfiguration() {
    guard canVerifyOpenAIConfiguration else { return }
    self.settings.openAIVerificationTask?.cancel()
    self.settings.openAIVerificationGeneration &+= 1
    let generation = self.settings.openAIVerificationGeneration
    let settings = OpenAISettings(
      apiKey: self.settings.openAIAPIKey,
      baseURL: self.settings.openAIBaseURL,
      model: self.settings.openAIModel
    )
    self.settings.openAIVerificationFailure = nil
    self.settings.openAIConfigurationVerificationState = .verifying
    self.settings.openAIVerificationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.verifyOpenAIConfigurationAction(settings)
        guard
          !Task.isCancelled,
          !self.hasBegunApplicationShutdown,
          self.settings.openAIVerificationGeneration == generation
        else {
          return
        }
        self.settings.openAIVerificationFailure = nil
        self.settings.openAIConfigurationVerificationState = .verified
        self.settings.openAIVerificationTask = nil
        self.workflowLibraryChangedAction()
      } catch is CancellationError {
        guard self.settings.openAIVerificationGeneration == generation else { return }
        self.settings.openAIVerificationFailure = nil
        self.settings.openAIConfigurationVerificationState = .idle
        self.settings.openAIVerificationTask = nil
      } catch {
        guard
          !self.hasBegunApplicationShutdown,
          self.settings.openAIVerificationGeneration == generation
        else {
          return
        }
        self.settings.openAIVerificationFailure =
          (error as? any OpenAIVerificationFailureProviding)?.openAIVerificationFailure
          ?? .unknown
        self.settings.openAIConfigurationVerificationState = .failed
        self.settings.openAIVerificationTask = nil
        self.workflowLibraryChangedAction()
      }
    }
  }
}
