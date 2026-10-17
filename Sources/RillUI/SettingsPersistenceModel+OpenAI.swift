import Foundation
import RillCore

extension SettingsPersistenceModel {
  public func languageModelSettings(for role: LanguageModelRole) -> OpenAISettings {
    switch role {
    case .fast: OpenAISettings(apiKey: openAIAPIKey, baseURL: openAIBaseURL, model: openAIModel)
    case .intelligent: OpenAISettings(apiKey: intelligentAPIKey, baseURL: intelligentBaseURL, model: intelligentModel)
    }
  }

  public func credentialAvailability(for role: LanguageModelRole) -> OpenAICredentialAvailability {
    role == .fast ? openAICredentialAvailability : intelligentCredentialAvailability
  }

  func setCredentialAvailability(_ value: OpenAICredentialAvailability, for role: LanguageModelRole) {
    if role == .fast { openAICredentialAvailability = value } else { intelligentCredentialAvailability = value }
  }

  public func verificationState(for role: LanguageModelRole) -> OpenAIConfigurationVerificationState {
    role == .fast ? openAIConfigurationVerificationState : intelligentVerificationState
  }

  public func verificationFailure(for role: LanguageModelRole) -> OpenAIVerificationFailure? {
    role == .fast ? openAIVerificationFailure : intelligentVerificationFailure
  }

  func verificationTaskOwner(for role: LanguageModelRole) -> ReplacingTaskOwner {
    role == .fast ? openAIVerificationTaskOwner : intelligentVerificationTaskOwner
  }

  func setVerification(_ state: OpenAIConfigurationVerificationState, failure: OpenAIVerificationFailure?, for role: LanguageModelRole) {
    if role == .fast {
      openAIConfigurationVerificationState = state
      openAIVerificationFailure = failure
    } else {
      intelligentVerificationState = state
      intelligentVerificationFailure = failure
    }
  }

  public var canVerifyOpenAIConfiguration: Bool { canVerifyLanguageModel(.fast) }

  public func canVerifyLanguageModel(_ role: LanguageModelRole) -> Bool {
    !hasBegunApplicationShutdown && !isLoading
      && credentialAvailability(for: role) == .available
      && !hasUnavailableScalarSettings(in: role.settingsDomain)
      && (try? LanguageModelConfiguration(migrating: languageModelSettings(for: role)).validate(for: role)) != nil
      && verificationState(for: role) != .verifying
  }

  public func verifyOpenAIConfiguration(for role: LanguageModelRole = .fast) {
    guard canVerifyLanguageModel(role) else { return }
    let owner = verificationTaskOwner(for: role)
    owner.cancel()
    verificationGenerations[role, default: 0] &+= 1
    let generation = verificationGenerations[role]
    let settings = languageModelSettings(for: role)
    setVerification(.verifying, failure: nil, for: role)
    let taskID = UUID()
    let task = Task { @MainActor [weak self, owner] in
      defer { owner.finish(id: taskID) }
      guard let self else { return }
      do {
        try await self.verifyOpenAIConfigurationAction(settings, role)
        guard !Task.isCancelled, !self.hasBegunApplicationShutdown,
          self.verificationGenerations[role] == generation
        else { return }
        self.setVerification(.verified, failure: nil, for: role)
        self.configurationChanged()
      } catch is CancellationError {
        guard self.verificationGenerations[role] == generation else { return }
        self.setVerification(.idle, failure: nil, for: role)
      } catch {
        guard !self.hasBegunApplicationShutdown,
          self.verificationGenerations[role] == generation
        else { return }
        self.setVerification(
          .failed,
          failure: (error as? any OpenAIVerificationFailureProviding)?.openAIVerificationFailure ?? .unknown,
          for: role)
        self.configurationChanged()
      }
    }
    owner.replace(id: taskID, with: task)
  }
}

extension LanguageModelRole {
  public var settingsDomain: ScalarSettingsDomain { self == .fast ? .openAI : .intelligent }
}
