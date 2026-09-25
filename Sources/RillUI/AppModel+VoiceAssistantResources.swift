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
    if case .preparing = self.voice.wakeWordResourceState {
      return
    }
    self.voice.wakeWordResourceState = .preparing(progress: nil)
    Task {
      do {
        let preparedModel = try await prepareWakeWordModelAction { progress in
          Task { @MainActor in
            self.voice.wakeWordResourceState = .preparing(progress: progress)
          }
        }
        recordDownloadedLocalSpeechModel(preparedModel)
        self.voice.wakeWordResourceState = .ready
        workflowLibraryChangedAction()
      } catch is CancellationError {
        self.voice.wakeWordResourceState = .notInstalled
        workflowLibraryChangedAction()
      } catch let reason as VoiceAssistantResourceUnavailableReason {
        self.voice.wakeWordResourceState = .unavailable(reason)
        workflowLibraryChangedAction()
      } catch {
        self.voice.wakeWordResourceState = .failed(error.localizedDescription)
        workflowLibraryChangedAction()
      }
    }
  }

  public func prepareTTSModel() {
    if case .preparing = self.voice.ttsResourceState {
      return
    }
    let modelIdentifier = ttsModelIdentifier
    self.voice.ttsResourceState = .preparing(progress: nil)
    Task {
      do {
        try await prepareTTSModelAction(modelIdentifier) { progress in
          Task { @MainActor in
            guard self.ttsModelIdentifier == modelIdentifier else { return }
            self.voice.ttsResourceState = .preparing(progress: progress)
          }
        }
        self.voice.downloadedTTSModelIdentifiers.insert(modelIdentifier)
        guard ttsModelIdentifier == modelIdentifier else { return }
        self.voice.ttsResourceState = .ready
      } catch is CancellationError {
        guard ttsModelIdentifier == modelIdentifier else { return }
        self.voice.ttsResourceState = .notInstalled
      } catch {
        guard ttsModelIdentifier == modelIdentifier else { return }
        self.voice.ttsResourceState = .failed(error.localizedDescription)
      }
    }
  }

  public func disableWakeWordListening() {
    for workflow in self.workflowLibrary.workflows where
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
      try await validateWakeWordConfigurationAction(
        WakeWordConfiguration(phrases: normalizedPhrases)
      )
    } catch {
      return .failed(localizedWakeWordSettingsError(error))
    }

    let sourceWorkflow = wakeWordSettingsWorkflow
    if enableListening,
      let sourceWorkflow,
      let activationError = workflowEnablementError(for: sourceWorkflow)
    {
      return .failed(activationError)
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
        return .failed(L10n.runText(.workflowLibraryUnavailable, language: language))
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
      self.workflowLibrary.workflowEditorError = nil
      self.workflowLibrary.workflowLibraryError = nil
      rebuildWorkflowLibrary()
      persistWorkflowEnabledStates()
      persistCustomWorkflows()
      append(
        english: String(
          format: L10n.runText(.wakePhrasesUpdatedFormat, language: .english),
          editableWorkflow.name
        ),
        simplifiedChinese: String(
          format: L10n.runText(.wakePhrasesUpdatedFormat, language: .simplifiedChinese),
          editableWorkflow.name
        )
      )
      savedWorkflowID = editableWorkflow.id
    } else if let sourceWorkflow {
      guard !self.settings.isLoading, isWorkflowLibraryAvailable else {
        return .failed(L10n.runText(.workflowLibraryUnavailable, language: language))
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
      self.workflowLibrary.workflowEditorError = nil
      self.workflowLibrary.workflowLibraryError = nil
      rebuildWorkflowLibrary()
      persistCustomWorkflows()
      append(
        english: String(
          format: L10n.runText(.builtInWakeWorkflowUpdatedFormat, language: .english),
          customizedWorkflow.name
        ),
        simplifiedChinese: String(
          format: L10n.runText(.builtInWakeWorkflowUpdatedFormat, language: .simplifiedChinese),
          customizedWorkflow.name
        )
      )
      savedWorkflowID = customizedWorkflow.id
    } else {
      var draft =
        defaultWorkflowDraft()
      draft.name = L10n.runText(.wakeDictationDraftName, language: language)
      draft.eventType = .wakeWord
      draft.wakePhrasesText = normalizedPhrases.joined(separator: "\n")

      let previousCustomWorkflowIDs = Set(self.workflowLibrary.customWorkflows.map(\.id))
      self.workflowLibrary.workflowEditorError = nil
      await saveWorkflowDraft(draft)
      if let editorError = self.workflowLibrary.workflowEditorError {
        return .failed(editorError)
      }
      savedWorkflowID = self.workflowLibrary.customWorkflows.first(where: {
        $0.trigger == .wakeWord
          && !previousCustomWorkflowIDs.contains($0.id)
      })?.id
    }
    guard let savedWorkflowID else {
      return .failed(L10n.runText(.wakeWorkflowNotFound, language: language))
    }

    for workflow in self.workflowLibrary.workflows where
      workflow.trigger == .wakeWord
        && workflow.id != savedWorkflowID
        && isWorkflowEnabled(workflow)
    {
      setWorkflowEnabled(false, for: workflow.id)
    }
    setWorkflowEnabled(enableListening, for: savedWorkflowID)
    if let libraryError = self.workflowLibrary.workflowLibraryError {
      return .failed(libraryError)
    }
    return .saved
  }

  @discardableResult
  public func stopSpeechPlaybackIfActive() -> Bool {
    stopSpeechPlaybackAction()
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
    let requiresLLM = workflow?.plan.process.allSteps.contains(where: {
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
          !hasUnavailableScalarSettings(in: .openAI),
          OpenAISettings.isValidBaseURL(openAIBaseURL),
          OpenAISettings.isValidModelIdentifier(openAIModel)
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
    } else if isLoadingPrivacySettings {
      privacy = .loading
    } else if privacySettingsLoadError != nil {
      privacy = .unavailable
    } else {
      privacy = .ready(
        cloudConfirmationRequired: privacyPolicySettings.cloudConfirmationRequired
      )
    }

    let usesSpeechOutput = workflow?.plan.output.actions.contains(where: {
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

  private func localizedWakeWordSettingsError(_ error: Error) -> String {
    L10n.runWakeWordSettingsSaveFailed(
      detail: error.localizedDescription,
      language: language
    )
  }

  private func localizedWorkflowFileSaveError(_ error: Error) -> String {
    String(
      format: L10n.runText(.workflowTOMLFileSaveFailedFormat, language: language),
      error.localizedDescription
    )
  }
}
