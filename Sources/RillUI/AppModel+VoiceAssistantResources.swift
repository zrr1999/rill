import Foundation
import RillCore

extension AppModel {
  func synchronizeWakeWordResourceWithLocalSpeechModel() {
    if case .preparing = wakeWordResourceState {
      return
    }
    let selectedModel = selectedTrustedLocalSpeechModelIdentifier
    let updatedState: VoiceAssistantResourceState =
      !selectedModel.isEmpty && downloadedLocalSpeechModels.contains(selectedModel)
      ? .ready
      : .notInstalled
    guard updatedState != wakeWordResourceState else { return }
    wakeWordResourceState = updatedState
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
    if case .preparing = wakeWordResourceState {
      return
    }
    wakeWordResourceState = .preparing(progress: nil)
    Task {
      do {
        let preparedModel = try await prepareWakeWordModelAction { progress in
          Task { @MainActor in
            self.wakeWordResourceState = .preparing(progress: progress)
          }
        }
        recordDownloadedLocalSpeechModel(preparedModel)
        wakeWordResourceState = .ready
        workflowLibraryChangedAction()
      } catch is CancellationError {
        wakeWordResourceState = .notInstalled
        workflowLibraryChangedAction()
      } catch let reason as VoiceAssistantResourceUnavailableReason {
        wakeWordResourceState = .unavailable(reason)
        workflowLibraryChangedAction()
      } catch {
        wakeWordResourceState = .failed(error.localizedDescription)
        workflowLibraryChangedAction()
      }
    }
  }

  public func prepareTTSModel() {
    if case .preparing = ttsResourceState {
      return
    }
    let modelIdentifier = ttsModelIdentifier
    ttsResourceState = .preparing(progress: nil)
    Task {
      do {
        try await prepareTTSModelAction(modelIdentifier) { progress in
          Task { @MainActor in
            guard self.ttsModelIdentifier == modelIdentifier else { return }
            self.ttsResourceState = .preparing(progress: progress)
          }
        }
        downloadedTTSModelIdentifiers.insert(modelIdentifier)
        guard ttsModelIdentifier == modelIdentifier else { return }
        ttsResourceState = .ready
      } catch is CancellationError {
        guard ttsModelIdentifier == modelIdentifier else { return }
        ttsResourceState = .notInstalled
      } catch {
        guard ttsModelIdentifier == modelIdentifier else { return }
        ttsResourceState = .failed(error.localizedDescription)
      }
    }
  }

  public func disableWakeWordListening() {
    for workflow in workflows where
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
      customWorkflows.first(where: { $0.id == workflow.id })
    }
    let savedWorkflowID: UUID?
    if let editableWorkflow,
      let index = customWorkflows.firstIndex(where: {
        $0.id == editableWorkflow.id
      })
    {
      guard !isLoadingSettings, isWorkflowLibraryAvailable else {
        return .failed(
          language == .english
            ? "The saved workflow library is unavailable. Repair storage, then retry."
            : "已保存的工作流库不可用。请修复存储后重试。"
        )
      }
      hasModifiedWorkflowLibrary = true
      var updatedWorkflow = customWorkflows[index]
      updatedWorkflow.plan.setup.wakeWord = WakeWordConfiguration(
        phrases: normalizedPhrases
      )
      if let workflowFileStore {
        do {
          let fileURL = try await workflowFileStore.save(
            workflow: updatedWorkflow,
            isEnabled: workflowEnabledStates[updatedWorkflow.id] ?? true,
            replacing: workflowFileURLsByID[updatedWorkflow.id]
          )
          workflowFileURLsByID[updatedWorkflow.id] = fileURL
        } catch {
          return .failed(localizedWorkflowFileSaveError(error))
        }
      }
      customWorkflows[index] = updatedWorkflow
      workflowEditorError = nil
      workflowLibraryError = nil
      rebuildWorkflowLibrary()
      persistWorkflowEnabledStates()
      persistCustomWorkflows()
      append(
        english: "Wake phrases updated: \(editableWorkflow.name)",
        simplifiedChinese: "唤醒短语已更新：\(editableWorkflow.name)"
      )
      savedWorkflowID = editableWorkflow.id
    } else if let sourceWorkflow {
      guard !isLoadingSettings, isWorkflowLibraryAvailable else {
        return .failed(
          language == .english
            ? "The saved workflow library is unavailable. Repair storage, then retry."
            : "已保存的工作流库不可用。请修复存储后重试。"
        )
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
            isEnabled: workflowEnabledStates[customizedWorkflow.id] ?? false,
            replacing: nil
          )
          workflowFileURLsByID[customizedWorkflow.id] = fileURL
        } catch {
          return .failed(localizedWorkflowFileSaveError(error))
        }
      }

      hasModifiedWorkflowLibrary = true
      customWorkflows.insert(customizedWorkflow, at: 0)
      workflowEditorError = nil
      workflowLibraryError = nil
      rebuildWorkflowLibrary()
      persistCustomWorkflows()
      append(
        english: "Built-in wake workflow updated: \(customizedWorkflow.name)",
        simplifiedChinese: "内置唤醒工作流已更新：\(customizedWorkflow.name)"
      )
      savedWorkflowID = customizedWorkflow.id
    } else {
      var draft =
        defaultWorkflowDraft()
      draft.name =
        language == .english
        ? "Wake Dictation"
        : "唤醒听写"
      draft.eventType = .wakeWord
      draft.wakePhrasesText = normalizedPhrases.joined(separator: "\n")

      let previousCustomWorkflowIDs = Set(customWorkflows.map(\.id))
      workflowEditorError = nil
      await saveWorkflowDraft(draft)
      if let workflowEditorError {
        return .failed(workflowEditorError)
      }
      savedWorkflowID = customWorkflows.first(where: {
        $0.trigger == .wakeWord
          && !previousCustomWorkflowIDs.contains($0.id)
      })?.id
    }
    guard let savedWorkflowID else {
      return .failed(
        language == .english
          ? "Rill could not locate the saved wake-word workflow."
          : "Rill 无法找到刚保存的唤醒词工作流。"
      )
    }

    for workflow in workflows where
      workflow.trigger == .wakeWord
        && workflow.id != savedWorkflowID
        && isWorkflowEnabled(workflow)
    {
      setWorkflowEnabled(false, for: workflow.id)
    }
    setWorkflowEnabled(enableListening, for: savedWorkflowID)
    if let workflowLibraryError {
      return .failed(workflowLibraryError)
    }
    return .saved
  }

  @discardableResult
  public func stopSpeechPlaybackIfActive() -> Bool {
    stopSpeechPlaybackAction()
  }

  private var wakeWordSettingsWorkflow: WorkflowDefinition? {
    workflows.first(where: {
      $0.trigger == .wakeWord && isWorkflowEnabled($0)
    })
      ?? customWorkflows.first(where: { $0.trigger == .wakeWord })
      ?? workflows.first(where: { $0.trigger == .wakeWord })
  }

  private func voiceAssistantReadiness(
    for workflow: WorkflowDefinition?
  ) -> VoiceAssistantReadiness {
    let requiresLLM = workflow?.plan.process.steps.contains(where: {
      $0.kind == .llmRewrite || $0.kind == .llmAnswer
    }) ?? false

    let llm: VoiceAssistantLLMReadiness
    if !requiresLLM {
      llm = .notRequired
    } else if isLoadingSettings {
      llm = .loading
    } else {
      switch openAICredentialAvailability {
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
        switch openAIConfigurationVerificationState {
        case .idle:
          llm = .configured
        case .verifying:
          llm = .verifying
        case .verified:
          llm = .verified
        case .failed:
          llm = .verificationFailed(openAIVerificationFailure)
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
      switch ttsResourceState {
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
      localSpeech: wakeWordResourceState,
      llm: llm,
      privacy: privacy,
      speechOutput: speechOutput
    )
  }

  private func localizedWakeWordSettingsError(_ error: Error) -> String {
    if language == .english {
      return error.localizedDescription
    }
    return "无法保存唤醒词设置：\(error.localizedDescription)"
  }

  private func localizedWorkflowFileSaveError(_ error: Error) -> String {
    language == .english
      ? "The workflow TOML file could not be saved: \(error.localizedDescription)"
      : "无法保存工作流 TOML 文件：\(error.localizedDescription)"
  }
}
