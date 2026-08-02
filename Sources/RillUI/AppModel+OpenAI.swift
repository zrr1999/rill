import RillCore

extension AppModel {
  public var canVerifyOpenAIConfiguration: Bool {
    !hasBegunApplicationShutdown
      && !isLoadingSettings
      && openAICredentialAvailability == .available
      && !hasUnavailableScalarSettings(in: .openAI)
      && OpenAISettings.isValidBaseURL(openAIBaseURL)
      && OpenAISettings.isValidModelIdentifier(openAIModel)
      && openAIConfigurationVerificationState != .verifying
  }

  public func verifyOpenAIConfiguration() {
    guard canVerifyOpenAIConfiguration else { return }
    openAIVerificationTask?.cancel()
    openAIVerificationGeneration &+= 1
    let generation = openAIVerificationGeneration
    let settings = OpenAISettings(
      apiKey: openAIAPIKey,
      baseURL: openAIBaseURL,
      model: openAIModel
    )
    openAIVerificationFailure = nil
    openAIConfigurationVerificationState = .verifying
    openAIVerificationTask = Task { @MainActor [weak self] in
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
        self.openAIVerificationTask = nil
        self.workflowLibraryChangedAction()
      } catch is CancellationError {
        guard self.openAIVerificationGeneration == generation else { return }
        self.openAIVerificationFailure = nil
        self.openAIConfigurationVerificationState = .idle
        self.openAIVerificationTask = nil
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
        self.openAIVerificationTask = nil
        self.workflowLibraryChangedAction()
      }
    }
  }
}
