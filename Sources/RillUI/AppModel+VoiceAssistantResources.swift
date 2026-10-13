import Foundation
import RillCore

extension AppModel {
  func synchronizeWakeWordResourceWithLocalSpeechModel() {
    if case .preparing = self.voice.wakeWordResourceState {
      return
    }
    let selectedModel = selectedTrustedLocalSpeechModelIdentifier
    let updatedState: VoiceAssistantResourceState =
      !selectedModel.isEmpty && self.voice.downloadedLocalSpeechModels.contains(selectedModel)
      ? .ready
      : .notInstalled
    guard updatedState != self.voice.wakeWordResourceState else { return }
    self.voice.wakeWordResourceState = updatedState
    workflowLibraryChangedAction()
  }

  public var voiceAssistantReadiness: VoiceAssistantReadiness {
    voiceAssistantReadiness(for: wakeWordSettingsWorkflow)
  }

  public var wakeWordSettingsSnapshot: WakeWordSettingsSnapshot {
    let workflow = wakeWordSettingsWorkflow
    return WakeWordSettingsSnapshot(
      phrases:
        workflow?.plan.setup.wakeWord?.phrases
        ?? WakeWordConfiguration.defaultPhrases,
      isEnabled: workflow.map(isWorkflowEnabled) ?? false,
      workflowName: workflow?.name
    )
  }

  public func prepareWakeWordModel() {
    voice.prepareWakeWordModel { [weak self] model in self?.recordDownloadedLocalSpeechModel(model) }
  }

  public func disableWakeWordListening() {
    for workflow in self.workflowLibrary.workflows
    where
      workflow.trigger == .wakeWord && isWorkflowEnabled(workflow)
    {
      setWorkflowEnabled(false, for: workflow.id)
    }
  }

  public func updateWakeWordSettings(
    phrases: [String],
    enableListening: Bool
  ) async -> WakeWordSettingsUpdateResult {
    let configuration = WakeWordConfiguration(phrases: phrases)
    let normalizedPhrases: [String]
    do {
      normalizedPhrases = try configuration.validatedPhrases()
      try await voice.validateWakeWordConfiguration(
        WakeWordConfiguration(phrases: normalizedPhrases)
      )
    } catch {
      return .failed(localizedWakeWordSettingsError(error))
    }

    let sourceWorkflow = wakeWordSettingsWorkflow
    if enableListening,
      let sourceWorkflow,
      let activationFailure = workflowEnablementFailure(for: sourceWorkflow)
    {
      return .failed(activationFailure)
    }
    let editableWorkflow = sourceWorkflow.flatMap { workflow in
      self.workflowLibrary.customWorkflows.first(where: { $0.id == workflow.id })
    }
    let savedWorkflowID: UUID?
    if let editableWorkflow,
      let index = self.workflowLibrary.customWorkflows.firstIndex(where: {
        $0.id == editableWorkflow.id
      })
    {
      guard !self.settings.isLoading, isWorkflowLibraryAvailable else {
        return .failed(L10n.resource("run.workflowLibraryUnavailable"))
      }
      self.workflowLibrary.hasModifiedWorkflowLibrary = true
      var updatedWorkflow = self.workflowLibrary.customWorkflows[index]
      updatedWorkflow.plan.setup.wakeWord = WakeWordConfiguration(
        phrases: normalizedPhrases
      )
      if let workflowFileStore {
        do {
          let fileURL = try await workflowFileStore.save(
            workflow: updatedWorkflow,
            isEnabled: self.workflowLibrary.workflowEnabledStates[updatedWorkflow.id] ?? true,
            replacing: self.workflowLibrary.workflowFileURLsByID[updatedWorkflow.id]
          )
          self.workflowLibrary.workflowFileURLsByID[updatedWorkflow.id] = fileURL
        } catch {
          return .failed(localizedWorkflowFileSaveError(error))
        }
      }
      self.workflowLibrary.customWorkflows[index] = updatedWorkflow
      self.workflowLibrary.workflowEditorErrorPresentation = nil
      self.workflowLibrary.workflowLibraryErrorPresentation = nil
      rebuildWorkflowLibrary()
      persistWorkflowEnabledStates()
      persistCustomWorkflows()
      append(
        L10n.resource("run.wakePhrasesUpdatedFormat", defaultValue: "Wake phrases updated: \(editableWorkflow.name)")
      )
      savedWorkflowID = editableWorkflow.id
    } else if let sourceWorkflow {
      guard !self.settings.isLoading, isWorkflowLibraryAvailable else {
        return .failed(L10n.resource("run.workflowLibraryUnavailable"))
      }
      var customizedWorkflow = sourceWorkflow
      customizedWorkflow.name = localizedWorkflowName(for: sourceWorkflow)
      customizedWorkflow.titleKey = nil
      customizedWorkflow.plan.setup.wakeWord = WakeWordConfiguration(
        phrases: normalizedPhrases
      )
      customizedWorkflow.metadata[Self.workflowOriginMetadataKey] =
        Self.userWorkflowOriginMetadataValue

      if let workflowFileStore {
        do {
          let fileURL = try await workflowFileStore.save(
            workflow: customizedWorkflow,
            isEnabled: self.workflowLibrary.workflowEnabledStates[customizedWorkflow.id] ?? false,
            replacing: nil
          )
          self.workflowLibrary.workflowFileURLsByID[customizedWorkflow.id] = fileURL
        } catch {
          return .failed(localizedWorkflowFileSaveError(error))
        }
      }

      self.workflowLibrary.hasModifiedWorkflowLibrary = true
      self.workflowLibrary.customWorkflows.insert(customizedWorkflow, at: 0)
      self.workflowLibrary.workflowEditorErrorPresentation = nil
      self.workflowLibrary.workflowLibraryErrorPresentation = nil
      rebuildWorkflowLibrary()
      persistCustomWorkflows()
      append(
        L10n.resource("run.builtInWakeWorkflowUpdatedFormat", defaultValue: "Built-in wake workflow updated: \(customizedWorkflow.name)")
      )
      savedWorkflowID = customizedWorkflow.id
    } else {
      var draft =
        defaultWorkflowDraft()
      draft.name = L10n.runText(.wakeDictationDraftName, language: self.settings.language)
      draft.eventType = .wakeWord
      draft.wakePhrasesText = normalizedPhrases.joined(separator: "\n")

      let previousCustomWorkflowIDs = Set(self.workflowLibrary.customWorkflows.map(\.id))
      self.workflowLibrary.workflowEditorErrorPresentation = nil
      await saveWorkflowDraft(draft)
      if self.workflowLibrary.workflowEditorError != nil {
        return .workflowEditorFailed
      }
      savedWorkflowID =
        self.workflowLibrary.customWorkflows.first(where: {
          $0.trigger == .wakeWord
            && !previousCustomWorkflowIDs.contains($0.id)
        })?.id
    }
    guard let savedWorkflowID else {
      return .failed(L10n.resource("run.wakeWorkflowNotFound"))
    }

    for workflow in self.workflowLibrary.workflows
    where
      workflow.trigger == .wakeWord
      && workflow.id != savedWorkflowID
      && isWorkflowEnabled(workflow)
    {
      setWorkflowEnabled(false, for: workflow.id)
    }
    setWorkflowEnabled(enableListening, for: savedWorkflowID)
    if self.workflowLibrary.workflowLibraryError != nil {
      return .workflowLibraryFailed
    }
    return .saved
  }

  private var wakeWordSettingsWorkflow: WorkflowDefinition? {
    self.workflowLibrary.workflows.first(where: {
      $0.trigger == .wakeWord && isWorkflowEnabled($0)
    })
      ?? self.workflowLibrary.customWorkflows.first(where: { $0.trigger == .wakeWord })
      ?? self.workflowLibrary.workflows.first(where: { $0.trigger == .wakeWord })
  }

  private func voiceAssistantReadiness(
    for workflow: WorkflowDefinition?
  ) -> VoiceAssistantReadiness {
    let requiresLLM =
      workflow?.plan.process.allSteps.contains(where: {
        $0.kind == .llmRewrite || $0.kind == .llmAnswer
      }) ?? false

    let llm: VoiceAssistantLLMReadiness
    if !requiresLLM {
      llm = .notRequired
    } else if self.settings.isLoading {
      llm = .loading
    } else {
      switch self.settings.openAICredentialAvailability {
      case .loading, .saving:
        llm = .loading
      case .missing:
        llm = .credentialMissing
      case .inaccessible:
        llm = .credentialInaccessible
      case .available:
        guard
          !settings.hasUnavailableScalarSettings(in: .openAI),
          OpenAISettings.isValidBaseURL(self.settings.openAIBaseURL),
          OpenAISettings.isValidModelIdentifier(self.settings.openAIModel)
        else {
          llm = .configurationInvalid
          break
        }
        switch self.settings.openAIConfigurationVerificationState {
        case .idle:
          llm = .configured
        case .verifying:
          llm = .verifying
        case .verified:
          llm = .verified
        case .failed:
          llm = .verificationFailed(self.settings.openAIVerificationFailure)
        }
      }
    }

    let privacy: VoiceAssistantPrivacyReadiness
    if !requiresLLM {
      privacy = .notRequired
    } else if self.settings.isLoadingPrivacySettings {
      privacy = .loading
    } else if self.settings.privacySettingsLoadError != nil {
      privacy = .unavailable
    } else {
      privacy = .ready(
        cloudConfirmationRequired: self.settings.privacyPolicySettings.cloudConfirmationRequired
      )
    }

    let usesSpeechOutput =
      workflow?.plan.output.actions.contains(where: {
        $0.id == SpeechOutputActionID.speak
      }) ?? false
    let speechOutput: VoiceAssistantSpeechOutputReadiness
    if !usesSpeechOutput {
      speechOutput = .notRequired
    } else {
      switch self.voice.ttsResourceState {
      case .ready:
        speechOutput = .localVoice
      case .preparing:
        speechOutput = .preparingLocalVoice
      case .notInstalled, .failed, .unavailable:
        speechOutput = .systemFallback
      }
    }

    return VoiceAssistantReadiness(
      microphone: permissionSnapshot.microphone,
      localSpeech: self.voice.wakeWordResourceState,
      llm: llm,
      privacy: privacy,
      speechOutput: speechOutput
    )
  }

  private func localizedWakeWordSettingsError(_ error: Error) -> LocalizedStringResource {
    L10n.resource("run.wakeWordSettingsSaveFailedFormat", defaultValue: "Could not save voice activation settings: \(error.localizedDescription)")
  }

  private func localizedWorkflowFileSaveError(_ error: Error) -> LocalizedStringResource {
    L10n.resource(
      "run.workflowTOMLFileSaveFailedFormat", defaultValue: "The workflow TOML file could not be saved: \(L10n.workflowFileFailureDetailResource(error))")
  }
}
