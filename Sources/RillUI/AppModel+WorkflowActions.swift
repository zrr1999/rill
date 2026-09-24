import Foundation
import RillCore
import RillRuntime

private enum WorkflowExecutionSupportIssue: Equatable {
  case legacyClipboardAutomationUnsupported
  case invalidEventType
  case plannedCapabilityUnavailable
  case missingProductionTransformer
  case unregisteredOutputAction(String)
  case openAIUnavailable(OpenAICredentialAvailability)
  case openAIConfigurationInvalid
  case openAIVerificationFailed(OpenAIVerificationFailure?)
  case microphonePermissionRequired
  case wakeWordModelNotReady
  case privacySettingsUnavailable
  case localSpeechUnavailable(LocalSpeechAvailability)
}

private enum WorkflowOperationFailureStage {
  case workflowStart
  case audioCaptureStart
  case audioTranscription
  case recordReplay

  var presentation: LocalizedText {
    switch self {
    case .workflowStart:
      LocalizedText(
        english: "Workflow could not start. Review Privacy and provider settings, then retry.",
        simplifiedChinese: "工作流无法启动。请检查隐私与服务商设置后重试。"
      )
    case .audioCaptureStart:
      LocalizedText(
        english:
          "Workflow recording could not start. Check microphone access and provider settings, then retry.",
        simplifiedChinese: "无法开始工作流录音。请检查麦克风权限与服务商设置后重试。"
      )
    case .audioTranscription:
      LocalizedText(
        english:
          "The recorded workflow could not be transcribed. Check provider settings, then retry.",
        simplifiedChinese: "无法转写这段工作流录音。请检查服务商设置后重试。"
      )
    case .recordReplay:
      LocalizedText(
        english:
          "The record could not be replayed. Review Privacy and workflow settings, then retry.",
        simplifiedChinese: "无法重新运行这条记录。请检查隐私与工作流设置后重试。"
      )
    }
  }
}

extension AppModel {
  public func stopInteractiveWorkflowRunsForApplicationShutdown() async {
    hasBegunApplicationShutdown = true
    let task = pendingInteractiveWorkflowTask
    task?.cancel()
    await task?.value
    pendingInteractiveWorkflowTask = nil
    let audioTasks = Array(workflowAudioActionTasks.values)
    for audioTask in audioTasks {
      audioTask.cancel()
    }
    for audioTask in audioTasks {
      await audioTask.value
    }
    workflowAudioActionTasks.removeAll()
    isRunning = false
    workflowAudioRunState = .idle
    workflowAudioCaptureRunID = nil
  }

  /// Waits for the interactive workflow accepted before this call to finish.
  ///
  /// Unlike the application-shutdown drain, this does not cancel the run or
  /// mutate presentation state. It is a deterministic completion boundary for
  /// callers that need to observe the result of an explicitly launched run.
  public func waitForInteractiveWorkflowRun() async {
    while let task = pendingInteractiveWorkflowTask {
      await task.value
    }
  }

  /// Waits for accepted start/finish actions for an interactive captured-audio
  /// workflow without changing the run state.
  public func waitForWorkflowAudioActions() async {
    while !workflowAudioActionTasks.isEmpty {
      let tasks = Array(workflowAudioActionTasks.values)
      for task in tasks {
        await task.value
      }
    }
  }

  private func workflowLibraryIsReadyForMutation(reportingToEditor: Bool) -> Bool {
    guard !isLoadingSettings else {
      let message = L10n.runText(.workflowLibraryLoading, language: language)
      if reportingToEditor {
        workflowEditorError = message
      } else {
        workflowLibraryError = message
      }
      return false
    }
    guard isWorkflowLibraryAvailable else {
      refreshUnavailableStoredSettingsDomainErrors()
      let message =
        workflowLibraryError
        ?? L10n.runText(.workflowLibraryUnavailable, language: language)
      if reportingToEditor {
        workflowEditorError = message
      } else {
        workflowLibraryError = message
      }
      return false
    }
    return true
  }

  public func isWorkflowEnabled(_ workflow: WorkflowDefinition) -> Bool {
    workflowLibrary.isWorkflowEnabled(workflow)
  }

  public func setWorkflowEnabled(_ isEnabled: Bool, for workflowID: UUID) {
    guard !hasBegunApplicationShutdown, !isUpdatingWorkflowEnabledStates else { return }
    guard workflowLibraryIsReadyForMutation(reportingToEditor: false) else { return }
    guard let workflow = workflows.first(where: { $0.id == workflowID }) else { return }

    if isEnabled, let activationError = workflowEnablementError(for: workflow) {
      workflowLibraryError = activationError
      return
    }

    if isEnabled {
      let conflicts = conflictingEnabledWorkflowsForActivation(of: workflow)
      guard conflicts.isEmpty else {
        workflowLibraryError = UIStrings.workflowEnableConflict(
          trigger: workflow.trigger,
          names: conflicts.map { localizedWorkflowName(for: $0) },
          language: language
        )
        return
      }
    }

    hasModifiedWorkflowLibrary = true
    var changes = [workflowID: isEnabled]
    if isEnabled, let exclusiveGroup = workflow.exclusiveGroupIdentifier {
      for candidate in workflows
      where
        candidate.id != workflowID && candidate.exclusiveGroupIdentifier == exclusiveGroup
      {
        changes[candidate.id] = false
      }
    }
    workflowLibraryError = nil
    if persistWorkflowFileEnabledStates(changes) { return }
    workflowEnabledStates.merge(changes) { _, new in new }
    updateWorkflowTriggerConflicts()
    persistWorkflowEnabledStates()
    workflowLibraryChangedAction()
  }

  private func persistWorkflowFileEnabledStates(_ changes: [UUID: Bool]) -> Bool {
    guard let workflowFileStore else { return false }
    let records = customWorkflows.compactMap { workflow -> (WorkflowDefinition, Bool, URL?, String?)? in
      guard let enabled = changes[workflow.id] else { return nil }
      return (
        workflow,
        enabled,
        workflowFileURLsByID[workflow.id],
        workflowFileSourcesByID[workflow.id]
      )
    }
    guard !records.isEmpty else { return false }

    isUpdatingWorkflowEnabledStates = true
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isUpdatingWorkflowEnabledStates = false }
      // Persist deactivations first so a reload cannot enable both Fn workflows.
      for (workflow, isEnabled, existingURL, source) in records.sorted(by: { !$0.1 && $1.1 }) {
        do {
          let record = try await workflowFileStore.saveDocument(
            WorkflowDocument(workflow: workflow, isEnabled: isEnabled),
            replacing: existingURL,
            expected: source.map(WorkflowFileExpectation.source) ?? .missing
          )
          self.workflowFileURLsByID[workflow.id] = record.fileURL
          self.workflowFileSourcesByID[workflow.id] = record.source
        } catch {
          await self.reloadWorkflowFiles()
          self.workflowLibraryError = String(
            format: L10n.runText(.workflowTOMLStateSaveFailedFormat, language: self.language),
            error.localizedDescription
          )
          return
        }
      }
      // Commit built-in selection only after every file change has succeeded.
      self.workflowEnabledStates.merge(changes) { _, new in new }
      self.persistWorkflowEnabledStates()
      await self.reloadWorkflowFiles()
    }
    persistenceWrites.track(task)
    return true
  }

  public func enabledWorkflows(for trigger: TriggerBinding) -> [WorkflowDefinition] {
    workflows
      .filter { workflow in
        workflow.trigger == trigger
          && isWorkflowEnabled(workflow)
          && isWorkflowExecutionSupported(workflow)
          && (workflowConflictIDsByWorkflowID[workflow.id]?.isEmpty ?? true)
      }
      .compactMap { workflow in
        resolvedWorkflowForExecution(workflow, trigger: trigger)
      }
  }

  public func conflictingWorkflows(for workflow: WorkflowDefinition) -> [WorkflowDefinition] {
    guard
      triggerRequiresExclusiveBinding(workflow.trigger),
      isWorkflowEnabled(workflow),
      let conflictWorkflowIDs = workflowConflictIDsByWorkflowID[workflow.id]
    else {
      return []
    }

    return workflows.filter { candidate in
      candidate.id != workflow.id && conflictWorkflowIDs.contains(candidate.id)
    }
  }

  public var workflowSelectableLocalSpeechModels: [String] {
    trustedLocalSpeechModels.map(\.id).filter(enabledSpeechModelIDs.contains)
  }

  public var workflowSelectableTTSModels: [String] {
    ttsModelOptions.map(\.id).filter(enabledSpeechModelIDs.contains)
  }

  public func isLocalSpeechModelDownloaded(_ modelIdentifier: String) -> Bool {
    downloadedLocalSpeechModels.contains(modelIdentifier)
  }

  public func localSpeechModelDisplayName(
    _ modelIdentifier: String,
    includeStatus: Bool = false
  ) -> String {
    let baseName: String
    if let descriptor = trustedLocalSpeechModels.first(where: { $0.id == modelIdentifier }) {
      baseName =
        language == .english
        ? descriptor.englishName
        : descriptor.simplifiedChineseName
    } else {
      baseName = modelIdentifier
    }
    guard includeStatus, trustedLocalSpeechModels.isEmpty else { return baseName }
    let status =
      isLocalSpeechModelDownloaded(modelIdentifier)
      ? UIStrings.text(.localSpeechDownloaded, language: language)
      : UIStrings.text(.localSpeechNotDownloaded, language: language)
    return "\(baseName) · \(status)"
  }



  public func useDownloadedLocalSpeechModel(_ modelIdentifier: String) {
    guard areDownloadedLocalSpeechModelsAvailable else {
      refreshUnavailableStoredSettingsDomainErrors()
      return
    }
    workflowLibraryError = nil
    selectTrustedLocalSpeechModel(modelIdentifier)
  }

  public var selectedTrustedLocalSpeechModelIdentifier: String {
    if trustedLocalSpeechModels.contains(where: { $0.id == localSpeechModel }) {
      return localSpeechModel
    }
    return defaultLocalSpeechModelIdentifier ?? ""
  }

  public var recommendedLocalSpeechModelIdentifier: String? {
    let fittingModels = trustedLocalSpeechModels.filter {
      $0.recommendedSystemMemoryGiB <= localSpeechPhysicalMemoryGiB
    }
    if let recommended = fittingModels.max(by: {
      if $0.hardwareRecommendationPriority == $1.hardwareRecommendationPriority {
        return $0.recommendedSystemMemoryGiB < $1.recommendedSystemMemoryGiB
      }
      return $0.hardwareRecommendationPriority < $1.hardwareRecommendationPriority
    }) {
      return recommended.id
    }
    return nil
  }

  public func localSpeechModelHardwareDescription(
    _ descriptor: LocalSpeechModelDescriptor
  ) -> String {
    let category: String =
      switch (language, descriptor.category) {
      case (.english, .performance): "Performance"
      case (.english, .intelligent): "Intelligent"
      case (.english, .multilingual): "Multilingual"
      case (_, .performance): "性能型"
      case (_, .intelligent): "智能型"
      case (_, .multilingual): "多语言"
      }
    let capacity: String
    if descriptor.parameterCountMillions >= 1_000 {
      let billions = Double(descriptor.parameterCountMillions) / 1_000
      capacity = billions.rounded() == billions ? "\(Int(billions))B" : "\(billions)B"
    } else {
      capacity = "\(descriptor.parameterCountMillions)M"
    }
    let profile = "\(category) · \(capacity) · \(descriptor.quantization.rawValue)"
    if descriptor.id == recommendedLocalSpeechModelIdentifier {
      return String(
        format: L10n.runText(.localSpeechHardwareRecommendedFormat, language: language),
        localSpeechPhysicalMemoryGiB,
        profile
      )
    }
    if localSpeechPhysicalMemoryGiB < descriptor.minimumSystemMemoryGiB {
      return String(
        format: L10n.runText(.localSpeechHardwareMemoryRequiredFormat, language: language),
        profile,
        descriptor.minimumSystemMemoryGiB
      )
    }
    return String(
      format: L10n.runText(.localSpeechHardwareMemoryRecommendedFormat, language: language),
      profile,
      descriptor.recommendedSystemMemoryGiB
    )
  }

  public func selectRecommendedLocalSpeechModel() {
    guard let recommendedLocalSpeechModelIdentifier else { return }
    selectTrustedLocalSpeechModel(recommendedLocalSpeechModelIdentifier)
  }

  public func selectTrustedLocalSpeechModel(_ modelIdentifier: String) {
    guard trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier }) else {
      return
    }
    if localSpeechModel != modelIdentifier {
      localSpeechModel = modelIdentifier
    }
    guard !isRestoringSettings else { return }
    if isLoadingSettings {
      shouldPrepareLocalSpeechModelAfterInitialSettingsLoad = true
      return
    }
    prepareLocalSpeechModel()
  }

  public func copyTextToClipboard(_ text: String) {
    writeClipboardTextAction(text)
  }

  public func copyHistoryFailure(_ record: WorkflowResultRecord) {
    guard let failureMessage = record.failureMessage else { return }
    let payload = [
      "workflow: \(UIStrings.workflowName(record.workflow, language: language))",
      "timestamp: \(record.timestamp.formatted(date: .numeric, time: .standard))",
      "failure: \(failureMessage)",
    ].joined(separator: "\n")
    copyTextToClipboard(payload)
  }

  public func copyDiagnosticEvent(_ event: DiagnosticEvent) {
    let metadata = event.metadata
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "\n")
    let payload = [
      "level: \(UIStrings.diagnosticLevel(event.level, language: .english))",
      "subsystem: \(UIStrings.subsystem(event.subsystem, language: .english))",
      "time: \(event.timestamp.formatted(date: .numeric, time: .standard))",
      "event: \(event.event)",
      "message: \(event.message)",
      metadata.isEmpty ? nil : "metadata:\n\(metadata)",
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
    copyTextToClipboard(payload)
  }

  public func runWorkflow(_ workflow: WorkflowDefinition) {
    runWorkflow(workflow, initiatedBy: .manual)
  }

  public func runWorkflow(_ workflow: WorkflowDefinition, initiatedBy binding: TriggerBinding) {
    guard !hasBegunApplicationShutdown, !isLoadingSettings else { return }
    if isRecordingWorkflowAudioRun(for: workflow) {
      finishCapturedAudioWorkflowRun(for: workflow)
      return
    }

    guard !isRunning else { return }
    if let issue = workflowExecutionSupportIssue(
      for: workflow,
      includeRuntimeAvailability: true
    ) {
      lastFailure = workflowRunError(for: issue, language: language)
      append(
        english: workflowRunError(for: issue, language: .english),
        simplifiedChinese: workflowRunError(for: issue, language: .simplifiedChinese)
      )
      return
    }
    guard isWorkflowEnabled(workflow) else {
      lastFailure = L10n.runText(.runWorkflowDisabledNotice, language: language)
      append(
        english: L10n.runText(.runWorkflowDisabledNotice, language: .english),
        simplifiedChinese: L10n.runText(.runWorkflowDisabledNotice, language: .simplifiedChinese)
      )
      return
    }
    if workflow.prefersAutomaticRecognizerSelection,
      hasUnavailableScalarSettings(in: .speechRoute)
    {
      lastFailure = L10n.runText(.speechRoutingSettingsUnavailable, language: language)
      append(
        english: L10n.runText(.speechRoutingSettingsUnavailable, language: .english),
        simplifiedChinese: L10n.runText(
          .speechRoutingSettingsUnavailable,
          language: .simplifiedChinese
        )
      )
      return
    }

    guard
      let workflowForExecution = resolvedWorkflowForExecution(
        workflow,
        trigger: binding
      )
    else {
      lastFailure = L10n.runText(.workflowRoutingUnresolvable, language: language)
      append(
        english: L10n.runText(.workflowRoutingUnresolvable, language: .english),
        simplifiedChinese: L10n.runText(.workflowRoutingUnresolvable, language: .simplifiedChinese)
      )
      return
    }
    if requiresCapturedAudioForInteractiveRun(workflowForExecution) {
      startCapturedAudioWorkflowRun(for: workflowForExecution, initiatedBy: binding)
      return
    }

    launchWorkflowRun(workflowForExecution, initiatedBy: binding)
  }

  func canTriggerWorkflow(_ workflow: WorkflowDefinition?) -> Bool {
    guard !hasBegunApplicationShutdown, !isLoadingSettings else { return false }
    guard let workflow else { return false }
    guard isWorkflowEnabled(workflow) else { return false }
    guard
      !workflow.prefersAutomaticRecognizerSelection
        || !hasUnavailableScalarSettings(in: .speechRoute)
    else {
      return false
    }
    guard isWorkflowExecutionSupported(workflow) else { return false }

    if isRecordingWorkflowAudioRun(for: workflow) {
      return true
    }

    return !isRunning
  }

  func isWorkflowExecutionSupported(_ workflow: WorkflowDefinition) -> Bool {
    workflowExecutionSupportIssue(
      for: workflow,
      includeRuntimeAvailability: true
    ) == nil
  }

  private func workflowExecutionSupportIssue(
    for workflow: WorkflowDefinition,
    includeRuntimeAvailability: Bool = false
  ) -> WorkflowExecutionSupportIssue? {
    switch WorkflowExecutionPolicy.issue(for: workflow) {
    case .legacyClipboardAutomationUnsupported:
      return .legacyClipboardAutomationUnsupported
    case .invalidEventType:
      return .invalidEventType
    case .plannedCapabilityUnavailable:
      return .plannedCapabilityUnavailable
    case nil:
      break
    }
    if workflow.plan.process.allSteps.compactMap(\.postProcessStep).contains(where: {
      !Self.productionPostProcessStepKinds.contains($0.kind)
    }) {
      return .missingProductionTransformer
    }
    if let actionID = workflow.plan.output.actions.lazy
      .map(\.id)
      .first(where: { outputActionRegistry.action(for: $0) == nil })
    {
      return .unregisteredOutputAction(actionID)
    }
    if workflow.trigger == .wakeWord {
      guard permissionSnapshot.microphone == .granted else {
        return .microphonePermissionRequired
      }
      guard case .ready = wakeWordResourceState else {
        return .wakeWordModelNotReady
      }
    }
    if workflow.plan.process.allSteps.contains(where: {
      $0.kind == .llmRewrite || $0.kind == .llmAnswer
    }) {
      guard openAICredentialAvailability == .available,
        !hasUnavailableScalarSettings(in: .openAI)
      else {
        return .openAIUnavailable(openAICredentialAvailability)
      }
      guard OpenAISettings.isValidBaseURL(openAIBaseURL),
        OpenAISettings.isValidModelIdentifier(openAIModel)
      else {
        return .openAIConfigurationInvalid
      }
      if openAIConfigurationVerificationState == .failed {
        return .openAIVerificationFailed(openAIVerificationFailure)
      }
      guard !isLoadingPrivacySettings, privacySettingsLoadError == nil else {
        return .privacySettingsUnavailable
      }
    }
    if includeRuntimeAvailability,
      !localSpeechTrustMaterialAvailable,
      workflowUsesCurrentLocalSpeechRoute(workflow)
    {
      return .localSpeechUnavailable(localSpeechAvailability)
    }
    return nil
  }

  func workflowEnablementError(for workflow: WorkflowDefinition) -> String? {
    guard let issue = workflowExecutionSupportIssue(for: workflow) else {
      return nil
    }
    return workflowEnableError(for: issue, language: language)
  }

  private func workflowUsesCurrentLocalSpeechRoute(_ workflow: WorkflowDefinition) -> Bool {
    if workflow.prefersAutomaticRecognizerSelection {
      return preferredSpeechEngine == .local
    }
    return workflow.plan.setup.speechRoute?.recognizerID == Self.localSpeechRecognizerID
      || workflow.plan.setup.speechRoute?.recognizerID == Self.sherpaOnnxRecognizerID
      || workflow.plan.setup.speechRoute?.recognizerID == Self.sherpaStreamingRecognizerID
  }

  private func workflowEnableError(
    for issue: WorkflowExecutionSupportIssue,
    language: AppLanguage
  ) -> String {
    switch (language, issue) {
    case (.english, .legacyClipboardAutomationUnsupported):
      return
        "Legacy collection-event workflows remain disabled; use record routes for production delivery."
    case (.simplifiedChinese, .legacyClipboardAutomationUnsupported):
      return "旧版记录集事件工作流已停用；生产投递请使用记录路由。"
    case (.english, .invalidEventType):
      return "This workflow declares an invalid event type and remains disabled."
    case (.simplifiedChinese, .invalidEventType):
      return "此工作流声明了无效事件类型，已保持停用。"
    case (.english, .plannedCapabilityUnavailable):
      return "This preset is planned but is not available in the current build."
    case (.simplifiedChinese, .plannedCapabilityUnavailable):
      return "此预设尚在规划中，当前版本不可用。"
    case (.english, .missingProductionTransformer):
      return "This workflow uses a text step that has no production transformer."
    case (.simplifiedChinese, .missingProductionTransformer):
      return "此工作流使用了尚未配置生产级 transformer 的文本步骤。"
    case (.english, .unregisteredOutputAction(let actionID)):
      return "This workflow uses an output action that is unavailable in this build: \(actionID)."
    case (.simplifiedChinese, .unregisteredOutputAction(let actionID)):
      return "此工作流使用了当前版本不可用的输出动作：\(actionID)。"
    case (.english, .openAIUnavailable(_)):
      return "Add an LLM Provider API key in Settings before enabling this workflow."
    case (.simplifiedChinese, .openAIUnavailable(_)):
      return "请先在设置中添加 API Key，再启用此工作流。"
    case (.english, .openAIConfigurationInvalid):
      return "Enter a valid OpenAI-compatible endpoint and model ID before enabling this workflow."
    case (.simplifiedChinese, .openAIConfigurationInvalid):
      return "请先填写有效的 OpenAI-compatible 地址与模型 ID，再启用此工作流。"
    case (.english, .openAIVerificationFailed):
      return "The current LLM configuration failed verification. Fix it or verify it again before enabling this workflow."
    case (.simplifiedChinese, .openAIVerificationFailed):
      return "当前 LLM 配置验证失败。请修复配置或重新验证后再启用此工作流。"
    case (.english, .microphonePermissionRequired):
      return "Grant microphone access before enabling wake-word listening."
    case (.simplifiedChinese, .microphonePermissionRequired):
      return "请先授予麦克风权限，再启用唤醒监听。"
    case (.english, .wakeWordModelNotReady):
      return "Prepare the selected local ASR model before enabling wake-word listening."
    case (.simplifiedChinese, .wakeWordModelNotReady):
      return "请先准备当前本地 ASR 模型，再启用唤醒监听。"
    case (.english, .privacySettingsUnavailable):
      return "Cloud privacy settings are unavailable. Repair them before enabling this assistant workflow."
    case (.simplifiedChinese, .privacySettingsUnavailable):
      return "云端隐私设置当前不可用。请修复后再启用语音助手工作流。"
    case (_, .localSpeechUnavailable(let availability)):
      return localSpeechWorkflowEnableError(availability, language: language)
    }
  }

  private func workflowRunError(
    for issue: WorkflowExecutionSupportIssue,
    language: AppLanguage
  ) -> String {
    switch (language, issue) {
    case (.english, .legacyClipboardAutomationUnsupported):
      return "This legacy clipboard event workflow is disabled and cannot run."
    case (.simplifiedChinese, .legacyClipboardAutomationUnsupported):
      return "此旧版记录集事件工作流已停用，无法运行。"
    case (.english, .invalidEventType):
      return "This workflow cannot run because its event type is invalid."
    case (.simplifiedChinese, .invalidEventType):
      return "此工作流的事件类型无效，无法运行。"
    case (.english, .plannedCapabilityUnavailable):
      return "This planned preset cannot run in the current build."
    case (.simplifiedChinese, .plannedCapabilityUnavailable):
      return "此规划中预设暂时无法运行。"
    case (.english, .missingProductionTransformer):
      return "This workflow cannot run because a production text transformer is missing."
    case (.simplifiedChinese, .missingProductionTransformer):
      return "此工作流缺少生产级文本 transformer，无法运行。"
    case (.english, .unregisteredOutputAction(let actionID)):
      return
        "This workflow cannot run because no production output action is registered for \(actionID)."
    case (.simplifiedChinese, .unregisteredOutputAction(let actionID)):
      return "此工作流无法运行，因为没有为 \(actionID) 注册生产级输出动作。"
    case (.english, .openAIUnavailable(_)):
      return "LLM Provider is unavailable. Open Settings and save an API key."
    case (.simplifiedChinese, .openAIUnavailable(_)):
      return "LLM Provider当前不可用。请打开设置并保存 API Key。"
    case (.english, .openAIConfigurationInvalid):
      return "The OpenAI-compatible endpoint or model ID is invalid. Review Speech settings and retry."
    case (.simplifiedChinese, .openAIConfigurationInvalid):
      return "OpenAI-compatible 地址或模型 ID 无效。请检查语音设置后重试。"
    case (.english, .openAIVerificationFailed):
      return "The current LLM configuration failed verification. Review Speech settings and retry."
    case (.simplifiedChinese, .openAIVerificationFailed):
      return "当前 LLM 配置验证失败。请检查语音设置后重试。"
    case (.english, .microphonePermissionRequired):
      return "Wake-word listening requires microphone access."
    case (.simplifiedChinese, .microphonePermissionRequired):
      return "唤醒监听需要麦克风权限。"
    case (.english, .wakeWordModelNotReady):
      return "Wake-word listening requires the selected local ASR model to be ready."
    case (.simplifiedChinese, .wakeWordModelNotReady):
      return "唤醒监听需要先准备当前本地 ASR 模型。"
    case (.english, .privacySettingsUnavailable):
      return "Cloud privacy settings are unavailable, so this assistant workflow cannot run."
    case (.simplifiedChinese, .privacySettingsUnavailable):
      return "云端隐私设置当前不可用，因此语音助手工作流无法运行。"
    case (_, .localSpeechUnavailable(let availability)):
      return localSpeechWorkflowRunError(availability, language: language)
    }
  }

  private func localSpeechWorkflowEnableError(
    _ availability: LocalSpeechAvailability,
    language: AppLanguage
  ) -> String {
    switch (language, availability) {
    case (.english, .architectureUnsupported):
      return
        "This build does not include a compatible local speech worker. Enable a supported local model before enabling this workflow."
    case (.simplifiedChinese, .architectureUnsupported):
      return
        "此构建未包含兼容的本地语音 worker。启用此工作流前，请先启用受支持的本地模型。"
    case (.english, .trustMaterialUnavailable):
      return
        "This build has no reviewed local speech model. Choose Cloud speech before enabling this workflow."
    case (.simplifiedChinese, .trustMaterialUnavailable):
      return "当前版本没有经审核的本地语音模型。请先将此工作流改为云端识别。"
    case (.english, .available):
      return "Local speech is currently unavailable for this workflow."
    case (.simplifiedChinese, .available):
      return "本地语音当前无法用于此工作流。"
    }
  }

  private func localSpeechWorkflowRunError(
    _ availability: LocalSpeechAvailability,
    language: AppLanguage
  ) -> String {
    switch (language, availability) {
    case (.english, .architectureUnsupported):
      return
        "This workflow cannot run because the compatible local speech worker is unavailable. Enable a supported local model and retry."
    case (.simplifiedChinese, .architectureUnsupported):
      return
        "此工作流无法运行，因为兼容的本地语音 worker 不可用。请启用受支持的本地模型后重试。"
    case (.english, .trustMaterialUnavailable):
      return
        "This workflow cannot run because this build has no reviewed local speech model. Choose Cloud speech and retry."
    case (.simplifiedChinese, .trustMaterialUnavailable):
      return "此工作流无法运行，因为当前版本没有经审核的本地语音模型。请选择云端识别后重试。"
    case (.english, .available):
      return "This workflow cannot run because local speech is currently unavailable."
    case (.simplifiedChinese, .available):
      return "此工作流无法运行，因为本地语音当前不可用。"
    }
  }

  func workflowRunButtonTitle(for workflow: WorkflowDefinition?) -> String {
    guard let workflow else {
      return UIStrings.text(.runSelectedWorkflow, language: language)
    }

    if isPreparingWorkflowAudioRun(for: workflow) {
      return UIStrings.text(.workflowPreparingAudio, language: language)
    }

    if isRecordingWorkflowAudioRun(for: workflow) {
      return UIStrings.text(.workflowStopAndTranscribe, language: language)
    }

    if isTranscribingWorkflowAudioRun(for: workflow) {
      return UIStrings.text(.workflowTranscribing, language: language)
    }

    if isRunning {
      return UIStrings.text(.running, language: language)
    }

    if requiresCapturedAudioForInteractiveRun(workflow) {
      return UIStrings.text(.workflowRecordAndRun, language: language)
    }

    return UIStrings.text(.runSelectedWorkflow, language: language)
  }

  func workflowMenuButtonTitle(for workflow: WorkflowDefinition) -> String {
    let name = localizedWorkflowName(for: workflow)

    if isPreparingWorkflowAudioRun(for: workflow) {
      return "\(name) · \(UIStrings.text(.workflowPreparingAudio, language: language))"
    }

    if isRecordingWorkflowAudioRun(for: workflow) {
      return "\(name) · \(UIStrings.text(.workflowStopAndTranscribe, language: language))"
    }

    if isTranscribingWorkflowAudioRun(for: workflow) {
      return "\(name) · \(UIStrings.text(.workflowTranscribing, language: language))"
    }

    return name
  }

  func launchWorkflowRun(_ workflow: WorkflowDefinition, initiatedBy binding: TriggerBinding) {
    guard !hasBegunApplicationShutdown else { return }
    isRunning = true
    lastFailure = nil

    interactiveWorkflowTaskGeneration &+= 1
    let generation = interactiveWorkflowTaskGeneration
    let task = Task { [weak self, sessionCoordinator, authorizeWorkflowRunAction] in
      guard let self else { return }
      defer { self.finishInteractiveWorkflowTask(generation: generation) }
      do {
        try Task.checkCancellation()
        try await self.persistProviderSettingsForRun(workflow)
        let authorized = try await authorizeWorkflowRunAction(workflow)
        try Task.checkCancellation()
        await sessionCoordinator.run(
          triggerEvent: Self.makeInteractiveTriggerEvent(for: workflow, binding: binding),
          authorizedContext: authorized
        )
      } catch is CancellationError {
        self.isRunning = false
      } catch {
        self.isRunning = false
        let failure = WorkflowOperationFailureStage.workflowStart.presentation
        self.lastFailure = failure.string(for: self.language)
        self.append(
          english: failure.english,
          simplifiedChinese: failure.simplifiedChinese
        )
      }
    }
    pendingInteractiveWorkflowTask = task
  }

  func startCapturedAudioWorkflowRun(
    for workflow: WorkflowDefinition, initiatedBy binding: TriggerBinding
  ) {
    isRunning = true
    lastFailure = nil
    workflowAudioRunState = .preparing(workflowID: workflow.id)

    let taskID = UUID()
    let task = Task { [weak self, startWorkflowAudioRunAction] in
      guard let self else { return }
      defer { self.finishWorkflowAudioActionTask(id: taskID) }
      do {
        try await self.persistProviderSettingsForRun(workflow)
        try await startWorkflowAudioRunAction(workflow, binding)
        await MainActor.run {
          guard self.isPreparingWorkflowAudioRun(for: workflow) else { return }
          self.workflowAudioRunState = .recording(workflowID: workflow.id)
          self.append(
            english: L10n.runText(.recordingStartedAutoStop, language: .english),
            simplifiedChinese: L10n.runText(
              .recordingStartedAutoStop,
              language: .simplifiedChinese
            )
          )
        }
      } catch is CancellationError {
        await MainActor.run {
          guard self.isPreparingWorkflowAudioRun(for: workflow) else { return }
          self.isRunning = false
          self.workflowAudioRunState = .idle
          self.workflowAudioCaptureRunID = nil
        }
      } catch {
        await MainActor.run {
          guard self.isPreparingWorkflowAudioRun(for: workflow) else { return }
          self.isRunning = false
          self.workflowAudioRunState = .idle
          self.workflowAudioCaptureRunID = nil
          let failure = WorkflowOperationFailureStage.audioCaptureStart.presentation
          self.lastFailure = failure.string(for: self.language)
          self.append(
            english: failure.english,
            simplifiedChinese: failure.simplifiedChinese
          )
        }
      }
    }
    workflowAudioActionTasks[taskID] = task
  }

  func finishCapturedAudioWorkflowRun(for workflow: WorkflowDefinition) {
    guard isRecordingWorkflowAudioRun(for: workflow) else { return }
    workflowAudioRunState = .transcribing(workflowID: workflow.id)

    let taskID = UUID()
    let task = Task { [weak self, finishWorkflowAudioRunAction] in
      guard let self else { return }
      defer { self.finishWorkflowAudioActionTask(id: taskID) }
      do {
        try await finishWorkflowAudioRunAction()
        await MainActor.run {
          self.workflowAudioRunState = .idle
        }
      } catch {
        await MainActor.run {
          self.isRunning = false
          self.workflowAudioRunState = .idle
          self.workflowAudioCaptureRunID = nil
          let failure = WorkflowOperationFailureStage.audioTranscription.presentation
          self.lastFailure = failure.string(for: self.language)
          self.append(
            english: failure.english,
            simplifiedChinese: failure.simplifiedChinese
          )
        }
      }
    }
    workflowAudioActionTasks[taskID] = task
  }

  func finishWorkflowAudioActionTask(id: UUID) {
    workflowAudioActionTasks.removeValue(forKey: id)
  }

  func requiresCapturedAudioForInteractiveRun(_ workflow: WorkflowDefinition) -> Bool {
    guard
      let resolvedWorkflow = resolvedWorkflowForExecution(
        workflow,
        trigger: workflow.trigger
      )
    else {
      return false
    }
    return Self.recognizerIDsRequiringCapturedAudio.contains(
      resolvedWorkflow.plan.setup.speechRoute?.recognizerID ?? ""
    )
  }

  func isPreparingWorkflowAudioRun(for workflow: WorkflowDefinition) -> Bool {
    guard case .preparing(let workflowID) = workflowAudioRunState else { return false }
    return workflowID == workflow.id
  }

  func isRecordingWorkflowAudioRun(for workflow: WorkflowDefinition) -> Bool {
    guard case .recording(let workflowID) = workflowAudioRunState else { return false }
    return workflowID == workflow.id
  }

  func isTranscribingWorkflowAudioRun(for workflow: WorkflowDefinition) -> Bool {
    guard case .transcribing(let workflowID) = workflowAudioRunState else { return false }
    return workflowID == workflow.id
  }

  func persistProviderSettingsForRun(_ workflow: WorkflowDefinition) async throws {
    guard !isLoadingSettings else { throw CancellationError() }
    _ = workflow
  }

  static func makeInteractiveTriggerEvent(
    for workflow: WorkflowDefinition,
    binding: TriggerBinding
  ) -> WorkflowTriggerEvent {
    WorkflowTriggerEvent(
      binding: binding,
      workflowID: workflow.id,
      sourceID: interactiveTriggerSourceID(for: binding),
      metadata: ["requestedTrigger": workflow.trigger.rawValue]
    )
  }

  static func interactiveTriggerSourceID(for binding: TriggerBinding) -> String {
    switch binding {
    case .manual:
      return "dashboard.run"
    case .menuBar:
      return "menu-bar.run"
    case .hotkey:
      return "hotkey.run"
    case .wakeWord:
      return "wake-word.run"
    }
  }

  public func deliverNextRecord() {
    deliverNextRecordAction()
  }

  public func refreshPermissions() {
    refreshPermissionsAction()
  }

  public func requestAccessibilityPermission() {
    requestAccessibilityAction()
  }

  public func requestMicrophonePermission() {
    requestMicrophoneAction()
  }

  public func openAccessibilitySettings() {
    openAccessibilitySettingsAction()
  }

  public func openMicrophoneSettings() {
    openMicrophoneSettingsAction()
  }

  public func installRecordPanelAction(_ action: @escaping () -> Void) {
    showRecordPanelAction = action
  }

  public func installSystemClipboardCaptureControlActions(
    setEnabled: @escaping (Bool, UInt64) -> Void,
    ignoreNextExternalChange: @escaping () -> Void
  ) {
    setSystemClipboardCaptureEnabledAction = setEnabled
    ignoreNextExternalClipboardChangeAction = ignoreNextExternalChange
    setEnabled(systemClipboardCaptureEnabled, clipboardCapturePreferenceRevision)
  }

  public func toggleClipboardCaptureEnabled() {
    _ = setSystemClipboardCaptureEnabled(!systemClipboardCaptureEnabled)
  }

  @available(*, deprecated, message: "Use toggleClipboardCaptureEnabled().")
  public func toggleClipboardCapturePaused() {
    toggleClipboardCaptureEnabled()
  }

  public func ignoreNextExternalClipboardChange() {
    guard systemClipboardCaptureEnabled,
      systemClipboardCaptureControlSnapshot.state == .active
    else { return }
    ignoreNextExternalClipboardChangeAction()
  }

  public func updateSystemClipboardCaptureControlState(_ snapshot: SystemClipboardCaptureControlSnapshot) {
    guard
      snapshot.revision > systemClipboardCaptureControlSnapshot.revision
        || snapshot == systemClipboardCaptureControlSnapshot
    else { return }
    systemClipboardCaptureControlSnapshot = snapshot
  }

  public func installRecordPanelHotkeyAction(
    _ action: @escaping (HotkeyBindingDescriptor) -> Void
  ) {
    updateRecordPanelHotkeyAction = action
    action(recordPanelHotkeyBinding)
  }

  public func showRecordPanel() {
    showRecordPanelAction()
  }

  public func selectSidebarSection(_ section: SidebarSection) {
    // A plain sidebar selection is a fresh user navigation, not a request
    // to resume an older search/CTA deep link that may still be waiting
    // for its destination view to appear.
    if section == .settings { presentSettings(); return }
    if section == .diagnostics { showSettings(.diagnostics); return }
    historyNavigationRequest = nil
    recordWorkspace.cancelNavigation()
    selectedSidebarSection = section
    if section == .records {
      recordWorkspace.selectCollection(nil)
    }
    if section == .stream {
      runHistoryScope = .recentRuns
    }
  }

  public func showRecordCollection(_ collectionID: RecordCollectionID) {
    historyNavigationRequest = nil
    selectedSidebarSection = .records
    recordWorkspace.selectCollection(collectionID)
  }

  public func showWorkflow(_ workflowID: UUID) {
    guard workflows.contains(where: { $0.id == workflowID }) else { return }
    historyNavigationRequest = nil
    recordWorkspace.cancelNavigation()
    selectedSidebarSection = .workflows
    workflowEditorNavigationRequest = WorkflowEditorNavigationRequest(
      workflowID: workflowID
    )
  }

  public func showRunHistory() {
    selectSidebarSection(.stream)
  }

  public func presentSettings() {
    settingsPresentationGeneration &+= 1
  }

  public func consumeSettingsPresentation() -> Bool {
    guard handledSettingsPresentationGeneration != settingsPresentationGeneration else { return false }
    handledSettingsPresentationGeneration = settingsPresentationGeneration
    return true
  }

  public func showSettings(_ section: SettingsSection, item: SettingsItem? = nil) {
    let request = SettingsNavigationRequest(section: section, item: item)
    selectedSettingsPane = request.section.pane
    settingsNavigationRequest = request
    presentSettings()
  }

  public func showRecord(_ id: RecordID) async {
    selectSidebarSection(.records)
    await recordWorkspace.revealRecord(id)
  }

  public func installRecordCopyAction(
    _ action: @escaping @MainActor (RecordReuseSubject) async -> RecordReuseOutcome
  ) {
    copyRecordAction = action
  }

  public func copyRecord(_ subject: RecordReuseSubject) async -> RecordReuseOutcome {
    await copyRecordAction(subject)
  }

  public func showHistoryEntry(_ entryID: UUID) {
    recordWorkspace.cancelNavigation()
    selectedSidebarSection = .stream
    runHistoryScope = .recentRuns
    runHistoryDeepLinkState = .idle
    historyNavigationRequest = HistoryNavigationRequest(
      entryID: entryID,
      scope: .recentRuns
    )
  }

  public func openWorkflowEditor() {
    historyNavigationRequest = nil
    recordWorkspace.cancelNavigation()
    selectedSidebarSection = .workflows
    workflowEditorNavigationRequest = nil
  }

  public func openWorkflowEditor(workflowID: UUID) {
    showWorkflow(workflowID)
  }

  public func setRecordPanelHotkeyShortcut(_ shortcut: KeyboardShortcut) {
    guard GlobalHotkeyPolicy.accepts(shortcut) else { return }
    recordPanelHotkeyBinding = .keyboardShortcut(shortcut)
  }

  public func resetRecordPanelHotkeyBinding() {
    recordPanelHotkeyBinding = .doubleCommand
  }

  public func reportRecordPanelPasteFailure() {
    lastFailure = L10n.runText(.recordDeliveryFocusFailure, language: language)
  }

  public func updatePermissionSnapshot(_ snapshot: PermissionSnapshot) {
    let microphoneChanged = permissionSnapshot.microphone != snapshot.microphone
    permissionSnapshot = snapshot
    if microphoneChanged {
      workflowLibraryChangedAction()
    }
  }

  public func localizedWorkflowName(for workflow: WorkflowDefinition) -> String {
    UIStrings.workflowName(workflow.presentation, language: language)
  }

  public func defaultWorkflowDraft() -> WorkflowEditorDraft {
    WorkflowEditorDraft(recognizer: .localSpeech)
  }

  public func isCustomWorkflow(_ workflow: WorkflowDefinition) -> Bool {
    !isBuiltInWorkflow(workflow)
      && workflow.metadata[Self.workflowOriginMetadataKey] == Self.userWorkflowOriginMetadataValue
  }

  public func isBuiltInWorkflow(_ workflow: WorkflowDefinition) -> Bool {
    builtInWorkflows.contains { $0.id == workflow.id }
  }

  public var userCreatedWorkflows: [WorkflowDefinition] {
    let builtInIDs = Set(builtInWorkflows.map(\.id))
    return customWorkflows.filter { !builtInIDs.contains($0.id) }
  }

  public var editableBuiltInWorkflows: [WorkflowDefinition] {
    // Shadowed built-ins (replaced by a same-named custom) stay hidden until
    // the custom is deleted; only built-ins present in the effective library
    // are editable surfaces.
    builtInWorkflows.compactMap { builtInWorkflow in
      workflows.first(where: { $0.id == builtInWorkflow.id })
    }
  }

  public func canRestoreBuiltInWorkflow(_ workflow: WorkflowDefinition) -> Bool {
    guard let defaultWorkflow = builtInWorkflows.first(where: { $0.id == workflow.id }) else {
      return false
    }
    return customWorkflows.contains(where: { $0.id == workflow.id })
      || workflowCustomizations.contains(where: { $0.workflowID == workflow.id })
      || workflowEnabledStates[workflow.id] != defaultWorkflow.isEnabledByDefault
  }

  public func saveWorkflowDraft(
    _ draft: WorkflowEditorDraft,
    editing workflowID: UUID? = nil
  ) async {
    guard workflowLibraryIsReadyForMutation(reportingToEditor: true) else { return }
    let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      workflowEditorError = L10n.runText(.workflowNameRequired, language: language)
      return
    }

    let resolvedName: String
    if let workflowID {
      resolvedName = trimmedName
      // Renaming onto another workflow's name is an explicit error; edits
      // that keep the current name (even a duplicated one) save as-is.
      let isRename = workflows.first(where: { $0.id == workflowID }).map {
        WorkflowNameDuplicationPolicy.normalizedName(localizedWorkflowName(for: $0))
          != WorkflowNameDuplicationPolicy.normalizedName(trimmedName)
      } ?? true
      if isRename, workflowNameIsTaken(trimmedName, excluding: workflowID) {
        workflowEditorError = L10n.workflowText(.workflowNameTakenError, language: language)
        return
      }
    } else {
      resolvedName = uniqueWorkflowName(for: trimmedName)
    }

    let existingMetadata = workflowID.flatMap { id in
      customWorkflows.first(where: { $0.id == id })?.metadata
        ?? builtInWorkflows.first(where: { $0.id == id })?.metadata
    } ?? [:]
    var sanitizedDraft = draft
    sanitizedDraft.name = resolvedName
    if let validationError = sanitizedDraft.outputValidationError(language: language) {
      workflowEditorError = validationError
      return
    }
    if sanitizedDraft.eventType == .wakeWord {
      do {
        try await validateWakeWordConfigurationAction(
          WakeWordConfiguration(phrases: sanitizedDraft.wakePhrases)
        )
      } catch {
        workflowEditorError = L10n.runWakeWordWorkflowSaveFailed(
          detail: error.localizedDescription,
          language: language
        )
        return
      }
    }

    let workflow = sanitizedDraft.makeWorkflow(
      id: workflowID ?? UUID(),
      existingMetadata: existingMetadata,
      hotkeyGesture: Self.defaultHotkeyGesture
    )

    let enableConflicts = conflictingEnabledWorkflowsForActivation(of: workflow)
    let desiredEnabledState = workflowEnabledStates[workflow.id]
      ?? builtInWorkflows.first(where: { $0.id == workflow.id })?.isEnabledByDefault
      ?? true
    let supportIssue = desiredEnabledState
      ? workflowExecutionSupportIssue(for: workflow)
      : nil
    let savedEnabledState = desiredEnabledState
      && supportIssue == nil
      && enableConflicts.isEmpty

    if let workflowFileStore {
      do {
        let fileURL = workflowFileURLsByID[workflow.id]
        let expected: WorkflowFileExpectation
        if fileURL != nil {
          guard let source = workflowFileSourcesByID[workflow.id] else { throw WorkflowFileConflict.changed }
          expected = .source(source)
        } else { expected = .missing }
        let record = try await workflowFileStore.saveDocument(
          WorkflowDocument(workflow: workflow, isEnabled: savedEnabledState), replacing: fileURL, expected: expected)
        workflowFileURLsByID[workflow.id] = record.fileURL
        workflowFileSourcesByID[workflow.id] = record.source
      } catch {
        workflowEditorError = String(
          format: L10n.runText(.workflowTOMLFileSaveFailedFormat, language: language),
          error.localizedDescription
        )
        return
      }
    }

    hasModifiedWorkflowLibrary = true
    if let workflowID, let index = customWorkflows.firstIndex(where: { $0.id == workflowID }) {
      customWorkflows[index] = workflow
    } else {
      customWorkflows.insert(workflow, at: 0)
    }

    if desiredEnabledState, let supportIssue {
      workflowEnabledStates[workflow.id] = false
      workflowLibraryError = workflowEnableError(for: supportIssue, language: language)
    } else if desiredEnabledState && !enableConflicts.isEmpty {
      workflowEnabledStates[workflow.id] = false
      workflowLibraryError = UIStrings.workflowEnableConflict(
        trigger: workflow.trigger,
        names: enableConflicts.map { localizedWorkflowName(for: $0) },
        language: language
      )
    } else {
      if workflowEnabledStates[workflow.id] == nil {
        workflowEnabledStates[workflow.id] = true
      }
      workflowLibraryError = nil
    }

    workflowEditorError = nil
    rebuildWorkflowLibrary()
    persistWorkflowEnabledStates()
    persistCustomWorkflows()
    append(
      english: String(
        format: L10n.runText(.workflowSavedFormat, language: .english),
        workflow.name
      ),
      simplifiedChinese: String(
        format: L10n.runText(.workflowSavedFormat, language: .simplifiedChinese),
        workflow.name
      )
    )
  }

  // Only custom names are reserved for true customs: naming a custom
  // workflow after a built-in shadows that built-in (see
  // rebuildWorkflowLibrary), so a built-in name must not trigger a suffix or
  // an error. Editing a built-in (an ID-override) cannot shadow anything, so
  // every other visible name stays reserved for it.
  private func workflowNameIsTaken(_ name: String, excluding workflowID: UUID) -> Bool {
    let normalized = WorkflowNameDuplicationPolicy.normalizedName(name)
    let candidates =
      builtInWorkflows.contains(where: { $0.id == workflowID }) ? workflows : customWorkflows
    return candidates.contains { candidate in
      candidate.id != workflowID
        && workflowLibrary.workflowShadowNameKeys(candidate).contains(normalized)
    }
  }

  private func uniqueWorkflowName(for baseName: String) -> String {
    let takenNames = Set(customWorkflows.flatMap(workflowLibrary.workflowShadowNameKeys))
    guard takenNames.contains(WorkflowNameDuplicationPolicy.normalizedName(baseName)) else {
      return baseName
    }
    var suffix = 2
    while takenNames.contains(WorkflowNameDuplicationPolicy.normalizedName("\(baseName) \(suffix)"))
    {
      suffix += 1
    }
    return "\(baseName) \(suffix)"
  }

  public func deleteCustomWorkflow(_ workflow: WorkflowDefinition) async {
    guard workflowLibraryIsReadyForMutation(reportingToEditor: false) else { return }
    guard !isBuiltInWorkflow(workflow) else { return }
    guard let index = customWorkflows.firstIndex(where: { $0.id == workflow.id }) else { return }
    if let workflowFileStore, let fileURL = workflowFileURLsByID[workflow.id] {
      do {
        guard let source = workflowFileSourcesByID[workflow.id] else { throw WorkflowFileConflict.changed }
        try await workflowFileStore.delete(fileURL: fileURL, expected: .source(source))
      } catch {
        workflowLibraryError = String(
          format: L10n.runText(.workflowTOMLFileRemoveFailedFormat, language: language),
          error.localizedDescription
        )
        return
      }
    }
    hasModifiedWorkflowLibrary = true
    customWorkflows.remove(at: index)
    workflowFileURLsByID.removeValue(forKey: workflow.id)
    workflowEnabledStates.removeValue(forKey: workflow.id)
    workflowEditorError = nil
    workflowLibraryError = nil
    rebuildWorkflowLibrary()
    persistWorkflowEnabledStates()
    persistCustomWorkflows()
    append(
      english: String(
        format: L10n.runText(.workflowRemovedFormat, language: .english),
        workflow.name
      ),
      simplifiedChinese: String(
        format: L10n.runText(.workflowRemovedFormat, language: .simplifiedChinese),
        workflow.name
      )
    )
  }

  public func restoreBuiltInWorkflowToDefault(_ workflow: WorkflowDefinition) async {
    guard workflowLibraryIsReadyForMutation(reportingToEditor: true) else { return }
    guard let defaultWorkflow = builtInWorkflows.first(where: { $0.id == workflow.id }) else {
      return
    }

    if let workflowFileStore, let fileURL = workflowFileURLsByID[workflow.id] {
      do {
        guard let source = workflowFileSourcesByID[workflow.id] else { throw WorkflowFileConflict.changed }
        try await workflowFileStore.delete(fileURL: fileURL, expected: .source(source))
      } catch {
        workflowEditorError = String(
          format: L10n.runText(.builtInWorkflowOverrideRemoveFailedFormat, language: language),
          error.localizedDescription
        )
        return
      }
    }

    hasModifiedWorkflowLibrary = true
    customWorkflows.removeAll { $0.id == workflow.id }
    workflowFileURLsByID.removeValue(forKey: workflow.id)
    workflowCustomizations.removeAll { $0.workflowID == workflow.id }
    workflowEnabledStates[workflow.id] = defaultWorkflow.isEnabledByDefault
    workflowEditorError = nil
    workflowLibraryError = nil
    rebuildWorkflowLibrary()
    persistWorkflowEnabledStates()
    persistCustomWorkflows()
    append(
      english: String(
        format: L10n.runText(.builtInWorkflowRestoredFormat, language: .english),
        localizedWorkflowName(for: defaultWorkflow)
      ),
      simplifiedChinese: String(
        format: L10n.runText(.builtInWorkflowRestoredFormat, language: .simplifiedChinese),
        localizedWorkflowName(for: defaultWorkflow)
      )
    )
  }

  public func acceptResolution(selections: [UUID: UUID]) {
    guard let pendingResolution else { return }
    Task {
      _ = await candidateResolver.accept(caseID: pendingResolution.id, selections: selections)
    }
  }

  public func dismissResolution() {
    guard let pendingResolution else { return }
    Task {
      _ = await candidateResolver.dismiss(caseID: pendingResolution.id)
    }
  }

  func finishInteractiveWorkflowTask(generation: Int) {
    guard interactiveWorkflowTaskGeneration == generation else { return }
    pendingInteractiveWorkflowTask = nil
  }

}
