import RillCore

enum WorkflowExplanationCopy {
  case button
  case sheetTitle
  case previewNotice
  case savedVersionNotice
  case saveBeforePreview
  case loading
  case refresh
  case close
  case retry
  case trigger
  case inputs
  case transforms
  case outputs
  case destinations
  case privacyConditions
  case issues
  case none
  case providerUnavailable
  case workflowUnavailable
  case invalidReceipt
}

extension L10n {
  static func workflowExplanationCopy(
    _ copy: WorkflowExplanationCopy,
    language: AppLanguage
  ) -> String {
    switch copy {
    case .button: return catalogString("workflowExplanationCopy.button", language: language)
    case .sheetTitle: return catalogString("workflowExplanationCopy.sheetTitle", language: language)
    case .previewNotice: return catalogString("workflowExplanationCopy.previewNotice", language: language)
    case .savedVersionNotice: return catalogString("workflowExplanationCopy.savedVersionNotice", language: language)
    case .saveBeforePreview: return catalogString("workflowExplanationCopy.saveBeforePreview", language: language)
    case .loading: return catalogString("workflowExplanationCopy.loading", language: language)
    case .refresh: return catalogString("workflowExplanationCopy.refresh", language: language)
    case .close: return catalogString("workflowExplanationCopy.close", language: language)
    case .retry: return catalogString("workflowExplanationCopy.retry", language: language)
    case .trigger: return catalogString("workflowExplanationCopy.trigger", language: language)
    case .inputs: return catalogString("workflowExplanationCopy.inputs", language: language)
    case .transforms: return catalogString("workflowExplanationCopy.transforms", language: language)
    case .outputs: return catalogString("workflowExplanationCopy.outputs", language: language)
    case .destinations: return catalogString("workflowExplanationCopy.destinations", language: language)
    case .privacyConditions: return catalogString("workflowExplanationCopy.privacyConditions", language: language)
    case .issues: return catalogString("workflowExplanationCopy.issues", language: language)
    case .none: return catalogString("workflowExplanationCopy.none", language: language)
    case .providerUnavailable: return catalogString("workflowExplanationCopy.providerUnavailable", language: language)
    case .workflowUnavailable: return catalogString("workflowExplanationCopy.workflowUnavailable", language: language)
    case .invalidReceipt: return catalogString("workflowExplanationCopy.invalidReceipt", language: language)
    }
  }

  static func workflowExplanationFailure(
    _ failure: WorkflowExplanationFailure,
    language: AppLanguage
  ) -> String {
    switch failure {
    case .workflowUnavailable:
      workflowExplanationCopy(.workflowUnavailable, language: language)
    case .providerUnavailable:
      workflowExplanationCopy(.providerUnavailable, language: language)
    case .invalidReceipt:
      workflowExplanationCopy(.invalidReceipt, language: language)
    }
  }

  static func workflowExplanationStatusTitle(
    _ status: WorkflowExplanationStatus,
    language: AppLanguage
  ) -> String {
    switch status {
    case .ready: return catalogString("workflowExplanationStatusTitle.ready", language: language)
    case .requiresConfirmation: return catalogString("workflowExplanationStatusTitle.requiresConfirmation", language: language)
    case .blocked: return catalogString("workflowExplanationStatusTitle.blocked", language: language)
    }
  }

  static func workflowExplanationStatusDetail(
    _ status: WorkflowExplanationStatus,
    language: AppLanguage
  ) -> String {
    switch status {
    case .ready: return catalogString("workflowExplanationStatusDetail.ready", language: language)
    case .requiresConfirmation: return catalogString("workflowExplanationStatusDetail.requiresConfirmation", language: language)
    case .blocked: return catalogString("workflowExplanationStatusDetail.blocked", language: language)
    }
  }

  static func workflowExplanationTrigger(
    _ trigger: WorkflowExplanationTriggerCategory,
    language: AppLanguage
  ) -> String {
    switch trigger {
    case .manual: return catalogString("workflowExplanationTrigger.manual", language: language)
    case .hotkey: return catalogString("workflowExplanationTrigger.hotkey", language: language)
    case .menuBar: return catalogString("workflowExplanationTrigger.menuBar", language: language)
    case .wakeWord: return catalogString("workflowExplanationTrigger.wakeWord", language: language)
    }
  }

  static func workflowExplanationInput(
    _ category: WorkflowExplanationInputCategory,
    language: AppLanguage
  ) -> String {
    switch category {
    case .microphoneAudio: return catalogString("workflowExplanationInput.microphoneAudio", language: language)
    case .recognitionHints: return catalogString("workflowExplanationInput.recognitionHints", language: language)
    case .focusedSelection: return catalogString("workflowExplanationInput.focusedSelection", language: language)
    case .clipboardText: return catalogString("workflowExplanationInput.clipboardText", language: language)
    case .unclassified: return catalogString("workflowExplanationInput.unclassified", language: language)
    }
  }

  static func workflowExplanationTransform(
    _ kind: WorkflowExplanationTransformKind,
    language: AppLanguage
  ) -> String {
    switch kind {
    case .vocabularyMapping: return catalogString("workflowExplanationTransform.vocabularyMapping", language: language)
    case .snippetReplacement: return catalogString("workflowExplanationTransform.snippetReplacement", language: language)
    case .languageModelRewrite: return catalogString("workflowExplanationTransform.languageModelRewrite", language: language)
    case .languageModelAnswer: return catalogString("workflowExplanationTransform.languageModelAnswer", language: language)
    case .whitespaceNormalization: return catalogString("workflowExplanationTransform.whitespaceNormalization", language: language)
    }
  }

  static func workflowExplanationOutput(
    _ effect: WorkflowExplanationOutputEffect,
    language: AppLanguage
  ) -> String {
    switch effect {
    case .clipboardWrite: return catalogString("workflowExplanationOutput.clipboardWrite", language: language)
    case .focusedApplicationWrite: return catalogString("workflowExplanationOutput.focusedApplicationWrite", language: language)
    case .recordStoreWrite: return catalogString("workflowExplanationOutput.recordStoreWrite", language: language)
    case .webhookRequest: return catalogString("workflowExplanationOutput.webhookRequest", language: language)
    case .shortcutInvocation: return catalogString("workflowExplanationOutput.shortcutInvocation", language: language)
    case .fileAppend: return catalogString("workflowExplanationOutput.fileAppend", language: language)
    case .speechPlayback: return catalogString("workflowExplanationOutput.speechPlayback", language: language)
    case .unclassified: return catalogString("workflowExplanationOutput.unclassified", language: language)
    }
  }

  static func workflowExplanationDestination(
    _ destination: WorkflowExplanationProcessingDestination,
    language: AppLanguage
  ) -> String {
    switch destination {
    case .onDevice: return catalogString("workflowExplanationDestination.onDevice", language: language)
    case .cloudService: return catalogString("workflowExplanationDestination.cloudService", language: language)
    case .clipboard: return catalogString("workflowExplanationDestination.clipboard", language: language)
    case .focusedApplication: return catalogString("workflowExplanationDestination.focusedApplication", language: language)
    case .localStorage: return catalogString("workflowExplanationDestination.localStorage", language: language)
    case .localAutomation: return catalogString("workflowExplanationDestination.localAutomation", language: language)
    case .localFile: return catalogString("workflowExplanationDestination.localFile", language: language)
    case .remoteEndpoint: return catalogString("workflowExplanationDestination.remoteEndpoint", language: language)
    case .unclassified: return catalogString("workflowExplanationDestination.unclassified", language: language)
    }
  }

  static func workflowExplanationInputDetail(
    _ input: WorkflowExplanationInput,
    privacyRedacted: Bool,
    language: AppLanguage
  ) -> String {
    [
      workflowExplanationUsage(input.usage, language: language),
      workflowExplanationInputAvailability(
        input.availability,
        privacyRedacted: privacyRedacted,
        language: language
      ),
      workflowExplanationDestination(input.processingDestination, language: language),
    ].joined(separator: " • ")
  }

  static func workflowExplanationTransformDetail(
    _ transform: WorkflowExplanationTransform,
    language: AppLanguage
  ) -> String {
    [
      workflowExplanationUsage(transform.usage, language: language),
      workflowExplanationAvailability(transform.availability, language: language),
      workflowExplanationDestination(transform.processingDestination, language: language),
    ].joined(separator: " • ")
  }

  static func workflowExplanationOutputDetail(
    _ output: WorkflowExplanationOutput,
    language: AppLanguage
  ) -> String {
    [
      workflowExplanationAvailability(output.availability, language: language),
      workflowExplanationConfiguration(output.configurationState, language: language),
      workflowExplanationDestination(output.processingDestination, language: language),
    ].joined(separator: " • ")
  }

  static func workflowExplanationIssue(
    _ issue: WorkflowExplanationIssue,
    language: AppLanguage
  ) -> String {
    let component = workflowExplanationComponent(issue.component, language: language)
    let location: String
    if let index = issue.componentIndex {
      location =
        L10n.resource("Localization.WorkflowExplanation.step", defaultValue: "\(String(describing: component)), step \(String(describing: index + 1))").string(
          for: language)
    } else {
      location = component
    }
    return "\(location): \(workflowExplanationIssueKind(issue.kind, language: language))"
  }

  static func workflowExplanationPrivacyReasons(
    _ reasons: [PrivacyRunEvaluationReason],
    language: AppLanguage
  ) -> [String] {
    var unique: [PrivacyRunEvaluationReason] = []
    for reason in reasons where !unique.contains(reason) {
      unique.append(reason)
    }
    if unique.contains(.cloudProcessingBlocked) || unique.contains(.cloudConfirmationRequired) {
      unique.removeAll { $0 == .cloudProviderSelected }
    }
    return unique.map { workflowExplanationPrivacyReason($0, language: language) }
  }

  private static func workflowExplanationPrivacyReason(
    _ reason: PrivacyRunEvaluationReason,
    language: AppLanguage
  ) -> String {
    switch reason {
    case .sensitiveApplication: return catalogString("workflowExplanationPrivacyReason.sensitiveApplication", language: language)
    case .secureInput: return catalogString("workflowExplanationPrivacyReason.secureInput", language: language)
    case .userDisabledClipboardHistory: return catalogString("workflowExplanationPrivacyReason.userDisabledClipboardHistory", language: language)
    case .cloudProviderSelected: return catalogString("workflowExplanationPrivacyReason.cloudProviderSelected", language: language)
    case .itemTaggedExcludeFromWorkflowCapture:
      return catalogString("workflowExplanationPrivacyReason.itemTaggedExcludeFromWorkflowCapture", language: language)
    case .unknownFocusContext: return catalogString("workflowExplanationPrivacyReason.unknownFocusContext", language: language)
    case .concealedClipboard: return catalogString("workflowExplanationPrivacyReason.concealedClipboard", language: language)
    case .transientClipboard: return catalogString("workflowExplanationPrivacyReason.transientClipboard", language: language)
    case .autoGeneratedClipboard: return catalogString("workflowExplanationPrivacyReason.autoGeneratedClipboard", language: language)
    case .cloudProcessingBlocked: return catalogString("workflowExplanationPrivacyReason.cloudProcessingBlocked", language: language)
    case .cloudConfirmationRequired: return catalogString("workflowExplanationPrivacyReason.cloudConfirmationRequired", language: language)
    case .privacySettingsUnavailable: return catalogString("workflowExplanationPrivacyReason.privacySettingsUnavailable", language: language)
    case .processingDestinationUnavailable: return catalogString("workflowExplanationPrivacyReason.processingDestinationUnavailable", language: language)
    }
  }

  private static func workflowExplanationUsage(
    _ usage: WorkflowExplanationUsage,
    language: AppLanguage
  ) -> String {
    switch usage {
    case .required: return catalogString("workflowExplanationUsage.required", language: language)
    case .conditional: return catalogString("workflowExplanationUsage.conditional", language: language)
    case .unclassified: return catalogString("workflowExplanationUsage.unclassified", language: language)
    }
  }

  private static func workflowExplanationAvailability(
    _ availability: WorkflowExplanationAvailability,
    language: AppLanguage
  ) -> String {
    switch availability {
    case .available: return catalogString("workflowExplanationAvailability.available", language: language)
    case .unavailable: return catalogString("workflowExplanationAvailability.unavailable", language: language)
    case .unclassified: return catalogString("workflowExplanationAvailability.unclassified", language: language)
    }
  }

  private static func workflowExplanationInputAvailability(
    _ availability: WorkflowExplanationAvailability,
    privacyRedacted: Bool,
    language: AppLanguage
  ) -> String {
    switch (availability, privacyRedacted) {
    case (.available, _):
      L10n.resource("Localization.WorkflowExplanation.Pipeline.component.available.current.content.and.permission.are.not.checked").string(for: language)
    case (.unavailable, true): L10n.resource("Localization.WorkflowExplanation.Omitted.by.the.current.privacy.preview").string(for: language)
    case (.unavailable, false): L10n.resource("Localization.WorkflowExplanation.Pipeline.component.unavailable").string(for: language)
    case (.unclassified, _): L10n.resource("Localization.WorkflowExplanation.Input.availability.unclassified").string(for: language)
    }
  }

  private static func workflowExplanationConfiguration(
    _ state: WorkflowExplanationConfigurationState,
    language: AppLanguage
  ) -> String {
    switch state {
    case .notRequired: return catalogString("workflowExplanationConfiguration.notRequired", language: language)
    case .configured: return catalogString("workflowExplanationConfiguration.configured", language: language)
    case .missing: return catalogString("workflowExplanationConfiguration.missing", language: language)
    case .invalid: return catalogString("workflowExplanationConfiguration.invalid", language: language)
    case .unclassified: return catalogString("workflowExplanationConfiguration.unclassified", language: language)
    }
  }

  private static func workflowExplanationComponent(
    _ component: WorkflowExplanationComponentKind,
    language: AppLanguage
  ) -> String {
    switch component {
    case .workflow: return catalogString("workflowExplanationComponent.workflow", language: language)
    case .privacyPolicy: return catalogString("workflowExplanationComponent.privacyPolicy", language: language)
    case .recognizer: return catalogString("workflowExplanationComponent.recognizer", language: language)
    case .transformer: return catalogString("workflowExplanationComponent.transformer", language: language)
    case .outputAction: return catalogString("workflowExplanationComponent.outputAction", language: language)
    }
  }

  private static func workflowExplanationIssueKind(
    _ kind: WorkflowExplanationIssueKind,
    language: AppLanguage
  ) -> String {
    switch kind {
    case .executionPlanUnresolved: return catalogString("workflowExplanationIssueKind.executionPlanUnresolved", language: language)
    case .legacyWorkflowUnsupported: return catalogString("workflowExplanationIssueKind.legacyWorkflowUnsupported", language: language)
    case .privacyEvaluationUnavailable: return catalogString("workflowExplanationIssueKind.privacyEvaluationUnavailable", language: language)
    case .privacyConfirmationRequired: return catalogString("workflowExplanationIssueKind.privacyConfirmationRequired", language: language)
    case .privacyProcessingBlocked: return catalogString("workflowExplanationIssueKind.privacyProcessingBlocked", language: language)
    case .privacyInputRedacted: return catalogString("workflowExplanationIssueKind.privacyInputRedacted", language: language)
    case .componentUnavailable: return catalogString("workflowExplanationIssueKind.componentUnavailable", language: language)
    case .componentUnclassified: return catalogString("workflowExplanationIssueKind.componentUnclassified", language: language)
    case .configurationMissing: return catalogString("workflowExplanationIssueKind.configurationMissing", language: language)
    case .configurationInvalid: return catalogString("workflowExplanationIssueKind.configurationInvalid", language: language)
    }
  }
}
