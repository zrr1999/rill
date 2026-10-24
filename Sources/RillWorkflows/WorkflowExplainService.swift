import Foundation
import RillCore

public enum WorkflowRecognizerResolution: Sendable, Equatable {
  case declared
  case localSpeech
  case unresolved
}

public struct WorkflowResolvedExecutionPlan: Sendable, Equatable {
  fileprivate var workflow: WorkflowDefinition
  fileprivate var initiatedBy: TriggerBinding

  public var executionWorkflow: WorkflowDefinition { workflow }

  fileprivate init(workflow: WorkflowDefinition, initiatedBy: TriggerBinding) {
    self.workflow = workflow
    self.initiatedBy = initiatedBy
  }
}

public enum WorkflowExecutionPlanResolution: Sendable, Equatable {
  case resolved(WorkflowResolvedExecutionPlan)
  case blocked(WorkflowExplanationReceipt)
}

/// Resolves user-setting-dependent workflow choices before they cross the
/// explanation boundary. A resolved plan cannot be constructed directly.
public enum WorkflowExecutionPlanResolver {
  public static func resolve(
    _ workflow: WorkflowDefinition,
    initiatedBy trigger: TriggerBinding,
    recognizer: WorkflowRecognizerResolution
  ) -> WorkflowExecutionPlanResolution {
    if WorkflowExecutionPolicy.issue(for: workflow) != nil {
      return .blocked(
        blockedReceipt(
          for: workflow,
          initiatedBy: trigger,
          unresolvedComponents: []
        )
      )
    }
    var resolvedWorkflow = workflow
    var unresolvedComponents: [WorkflowExplanationComponentKind] = []

    switch (workflow.prefersAutomaticRecognizerSelection, recognizer) {
    case (true, .localSpeech):
      resolvedWorkflow.plan.setup.speechRoute?.recognizerID = "local-speech"
    case (false, _):
      break
    case (true, .declared),
      (true, .unresolved):
      unresolvedComponents.append(.recognizer)
    }

    guard unresolvedComponents.isEmpty else {
      return .blocked(
        blockedReceipt(
          for: workflow,
          initiatedBy: trigger,
          unresolvedComponents: unresolvedComponents
        )
      )
    }
    return .resolved(
      WorkflowResolvedExecutionPlan(
        workflow: resolvedWorkflow,
        initiatedBy: trigger
      )
    )
  }

  private static func blockedReceipt(
    for workflow: WorkflowDefinition,
    initiatedBy trigger: TriggerBinding,
    unresolvedComponents: [WorkflowExplanationComponentKind]
  ) -> WorkflowExplanationReceipt {
    var issues = [
      WorkflowExplanationIssue(
        kind: .privacyEvaluationUnavailable,
        component: .privacyPolicy
      )
    ]
    issues.append(
      contentsOf: unresolvedComponents.map {
        WorkflowExplanationIssue(
          kind: .executionPlanUnresolved,
          component: $0
        )
      })
    if WorkflowExecutionPolicy.issue(for: workflow) != nil {
      issues.append(
        WorkflowExplanationIssue(
          kind: .legacyWorkflowUnsupported,
          component: .workflow
        )
      )
    }

    let hasUnresolvedRecognizer = unresolvedComponents.contains(.recognizer)
    let hasUnresolvedOutput = unresolvedComponents.contains(.outputAction)
    return WorkflowExplanationReceipt(
      workflowID: workflow.id,
      trigger: triggerCategory(for: trigger),
      inputs: hasUnresolvedRecognizer
        ? [
          WorkflowExplanationInput(
            category: .unclassified,
            availability: .unclassified,
            usage: .unclassified,
            processingDestination: .unclassified
          )
        ]
        : [],
      transforms: [],
      outputs: hasUnresolvedOutput
        ? [
          WorkflowExplanationOutput(
            sourceActionIndex: 0,
            effect: .unclassified,
            availability: .unclassified,
            configurationState: .unclassified,
            processingDestination: .unclassified
          )
        ]
        : [],
      processingDestinations: unresolvedComponents.isEmpty ? [] : [.unclassified],
      status: .blocked,
      issues: issues
    )
  }

  private static func triggerCategory(
    for trigger: TriggerBinding
  ) -> WorkflowExplanationTriggerCategory {
    switch trigger {
    case .manual: .manual
    case .hotkey: .hotkey
    case .menuBar: .menuBar
    case .wakeWord: .wakeWord
    }
  }
}

public struct WorkflowComponentProfileRegistry: Sendable {
  fileprivate struct InputProfile: Sendable {
    var category: WorkflowExplanationInputCategory
    var usage: WorkflowExplanationUsage
    var destination: WorkflowExplanationProcessingDestination
  }

  fileprivate struct RecognizerProfile: Sendable {
    var inputs: [InputProfile]
  }

  fileprivate struct TransformerProfile: Sendable {
    var componentID: String
    var kind: WorkflowExplanationTransformKind
    var destination: WorkflowExplanationProcessingDestination
  }

  fileprivate typealias ConfigurationRequirement = WorkflowOutputConfigurationRequirement

  fileprivate struct OutputEffectProfile: Sendable {
    var effect: WorkflowExplanationOutputEffect
    var destination: WorkflowExplanationProcessingDestination
  }

  fileprivate struct OutputProfile: Sendable {
    var effects: [OutputEffectProfile]
    var configurationRequirement: ConfigurationRequirement
  }

  private let recognizers: [String: RecognizerProfile]
  private let transformers: [PostProcessStepKind: TransformerProfile]
  private let outputs: [String: OutputProfile]

  /// The profiles of components shipped by Rill. Components absent from
  /// this closed catalog remain unclassified even when a runtime object is
  /// registered for their identifier.
  public init() {
    recognizers = [
      "local-speech": RecognizerProfile(
        inputs: [
          InputProfile(
            category: .microphoneAudio,
            usage: .required,
            destination: .onDevice
          )
        ]
      ),
      "sherpa-onnx.local": RecognizerProfile(
        inputs: [
          InputProfile(
            category: .microphoneAudio,
            usage: .required,
            destination: .onDevice
          )
        ]
      ),
      "sherpa-onnx.streaming": RecognizerProfile(
        inputs: [
          InputProfile(
            category: .microphoneAudio,
            usage: .required,
            destination: .onDevice
          )
        ]
      ),
      "context.selection": RecognizerProfile(
        inputs: [
          InputProfile(
            category: .focusedSelection,
            usage: .conditional,
            destination: .onDevice
          ),
          InputProfile(
            category: .clipboardText,
            usage: .conditional,
            destination: .onDevice
          ),
        ]
      ),
    ]
    transformers = [
      .normalizeWhitespace: TransformerProfile(
        componentID: "transformer.normalize",
        kind: .whitespaceNormalization,
        destination: .onDevice
      ),
      .llmRewrite: TransformerProfile(
        componentID: "transformer.openai.responses.rewrite",
        kind: .languageModelRewrite,
        destination: .cloudService
      ),
      .llmAnswer: TransformerProfile(
        componentID: "transformer.openai.responses.rewrite",
        kind: .languageModelAnswer,
        destination: .cloudService
      ),
    ]
    outputs = [
      "system-clipboard.copy": OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .clipboardWrite,
            destination: .clipboard
          )
        ],
        configurationRequirement: .none
      ),
      "focused-application.insert": OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .focusedApplicationWrite,
            destination: .focusedApplication
          )
        ],
        configurationRequirement: .none
      ),
      "record.store": OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .recordStoreWrite,
            destination: .localStorage
          )
        ],
        configurationRequirement: .none
      ),
      ExternalOutputActionID.webhookPost: OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .webhookRequest,
            destination: .remoteEndpoint
          )
        ],
        configurationRequirement: .webhook
      ),
      ExternalOutputActionID.shortcutsRun: OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .shortcutInvocation,
            destination: .localAutomation
          )
        ],
        configurationRequirement: .shortcut
      ),
      ExternalOutputActionID.markdownAppend: OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .fileAppend,
            destination: .localFile
          )
        ],
        configurationRequirement: .markdownFile
      ),
      SpeechOutputActionID.speak: OutputProfile(
        effects: [
          OutputEffectProfile(
            effect: .speechPlayback,
            destination: .onDevice
          )
        ],
        configurationRequirement: .none
      ),
    ]
  }

  fileprivate func recognizer(for id: String) -> RecognizerProfile? {
    recognizers[id]
  }

  fileprivate func transformer(for kind: PostProcessStepKind) -> TransformerProfile? {
    transformers[kind]
  }

  fileprivate func output(for id: String) -> OutputProfile? {
    outputs[id]
  }

}

/// Explains only a plan whose setting-dependent choices were resolved by
/// `WorkflowExecutionPlanResolver`. The compatibility entry point without a
/// privacy evaluation remains fail-closed.
public struct WorkflowExplainService: Sendable {
  private let recognizerRegistry: SpeechRecognizerRegistry
  private let transformerRegistry: TextTransformerRegistry
  private let actionRegistry: OutputActionRegistry
  private let profileRegistry: WorkflowComponentProfileRegistry

  public init(
    recognizerRegistry: SpeechRecognizerRegistry,
    transformerRegistry: TextTransformerRegistry,
    actionRegistry: OutputActionRegistry,
    profileRegistry: WorkflowComponentProfileRegistry = .init()
  ) {
    self.recognizerRegistry = recognizerRegistry
    self.transformerRegistry = transformerRegistry
    self.actionRegistry = actionRegistry
    self.profileRegistry = profileRegistry
  }

  public func explainResolved(
    _ plan: WorkflowResolvedExecutionPlan
  ) -> WorkflowExplanationReceipt {
    buildReceipt(for: plan, privacyEvaluation: nil)
  }

  public func explainResolved(
    _ plan: WorkflowResolvedExecutionPlan,
    privacyEvaluation: PrivacyRunEvaluation
  ) -> WorkflowExplanationReceipt {
    buildReceipt(for: plan, privacyEvaluation: privacyEvaluation)
  }

  public func privacyProcessingDestinations(
    for plan: WorkflowResolvedExecutionPlan
  ) -> WorkflowPrivacyDestinationClassification {
    WorkflowPrivacyDestinationClassifier.classify(plan.workflow)
  }

  private func buildReceipt(
    for plan: WorkflowResolvedExecutionPlan,
    privacyEvaluation: PrivacyRunEvaluation?
  ) -> WorkflowExplanationReceipt {
    let workflow = plan.workflow
    var issues: [WorkflowExplanationIssue] = []
    if let privacyEvaluation {
      appendPrivacyIssues(for: privacyEvaluation, to: &issues)
    } else {
      issues.append(
        WorkflowExplanationIssue(
          kind: .privacyEvaluationUnavailable,
          component: .privacyPolicy
        ))
    }

    if WorkflowExecutionPolicy.issue(for: workflow) != nil {
      issues.append(
        WorkflowExplanationIssue(
          kind: .legacyWorkflowUnsupported,
          component: .workflow
        )
      )
    }

    var inputs = explainInputs(workflow, issues: &issues)
    if let privacyEvaluation {
      applyPrivacyRedactions(privacyEvaluation, to: &inputs)
    }
    let transforms = explainTransforms(workflow, issues: &issues)
    let outputs = explainOutputs(workflow, issues: &issues)
    let destinations = orderedUniqueDestinations(
      inputs.map(\.processingDestination)
        + transforms.map(\.processingDestination)
        + outputs.map(\.processingDestination)
    )

    return WorkflowExplanationReceipt(
      workflowID: workflow.id,
      trigger: triggerCategory(for: plan.initiatedBy),
      inputs: inputs,
      transforms: transforms,
      outputs: outputs,
      processingDestinations: destinations,
      status: explanationStatus(
        privacyEvaluation: privacyEvaluation,
        issues: issues
      ),
      issues: issues,
      privacyReasons: privacyEvaluation?.reasons ?? [],
      redactedInputCategories: privacyEvaluation?.redactedInputCategories ?? []
    )
  }

  private func appendPrivacyIssues(
    for evaluation: PrivacyRunEvaluation,
    to issues: inout [WorkflowExplanationIssue]
  ) {
    if evaluation.reasons.contains(.privacySettingsUnavailable)
      || evaluation.reasons.contains(.processingDestinationUnavailable)
    {
      issues.append(
        WorkflowExplanationIssue(
          kind: .privacyEvaluationUnavailable,
          component: .privacyPolicy
        ))
    } else if evaluation.status == .blocked {
      issues.append(
        WorkflowExplanationIssue(
          kind: .privacyProcessingBlocked,
          component: .privacyPolicy
        ))
    } else if evaluation.status == .requiresConfirmation {
      issues.append(
        WorkflowExplanationIssue(
          kind: .privacyConfirmationRequired,
          component: .privacyPolicy
        ))
    }

    if !evaluation.redactedInputCategories.isEmpty {
      issues.append(
        WorkflowExplanationIssue(
          kind: .privacyInputRedacted,
          component: .privacyPolicy
        ))
    }
  }

  private func applyPrivacyRedactions(
    _ evaluation: PrivacyRunEvaluation,
    to inputs: inout [WorkflowExplanationInput]
  ) {
    for index in inputs.indices {
      let redacted: Bool =
        switch inputs[index].category {
        case .focusedSelection:
          evaluation.redactedInputCategories.contains(.focusedSelection)
        case .clipboardText:
          evaluation.redactedInputCategories.contains(.clipboardText)
        case .microphoneAudio, .recognitionHints, .unclassified:
          false
        }
      if redacted {
        inputs[index].availability = .unavailable
      }
    }
  }

  private func explanationStatus(
    privacyEvaluation: PrivacyRunEvaluation?,
    issues: [WorkflowExplanationIssue]
  ) -> WorkflowExplanationStatus {
    let nonBlockingIssueKinds: [WorkflowExplanationIssueKind] = [
      .privacyConfirmationRequired,
      .privacyInputRedacted,
    ]
    if privacyEvaluation == nil
      || issues.contains(where: { !nonBlockingIssueKinds.contains($0.kind) })
    {
      return .blocked
    }

    return switch privacyEvaluation?.status {
    case .ready: .ready
    case .requiresConfirmation: .requiresConfirmation
    case .blocked, .none: .blocked
    }
  }

  private func explainInputs(
    _ workflow: WorkflowDefinition,
    issues: inout [WorkflowExplanationIssue]
  ) -> [WorkflowExplanationInput] {
    let recognizerID = workflow.plan.setup.speechRoute?.recognizerID ?? ""
    let component = recognizerRegistry.recognizer(for: recognizerID)
    guard let profile = profileRegistry.recognizer(for: recognizerID) else {
      issues.append(
        WorkflowExplanationIssue(
          kind: .componentUnclassified,
          component: .recognizer
        )
      )
      return [
        WorkflowExplanationInput(
          category: .unclassified,
          availability: .unclassified,
          usage: .unclassified,
          processingDestination: .unclassified
        )
      ]
    }

    let availability: WorkflowExplanationAvailability
    if component == nil {
      availability = .unavailable
      issues.append(
        WorkflowExplanationIssue(
          kind: .componentUnavailable,
          component: .recognizer
        )
      )
    } else {
      availability = .available
    }

    return profile.inputs.map {
      WorkflowExplanationInput(
        category: $0.category,
        availability: availability,
        usage: $0.usage,
        processingDestination: $0.destination
      )
    }
  }

  private func explainTransforms(
    _ workflow: WorkflowDefinition,
    issues: inout [WorkflowExplanationIssue]
  ) -> [WorkflowExplanationTransform] {
    var transforms: [WorkflowExplanationTransform] = []
    if workflow.plan.process.allSteps.contains(where: {
      $0.kind == .applyVocabulary
    }),
      workflow.plan.setup.vocabularyBindings.contains(where: {
        $0.uses.contains(.textReplacement)
      })
    {
      transforms.append(
        WorkflowExplanationTransform(
          kind: .vocabularyMapping,
          availability: .available,
          usage: .conditional,
          processingDestination: .onDevice
        )
      )
    }
    let postProcessSteps = workflow.plan.process.allSteps.compactMap(\.postProcessStep)
    transforms.append(
      contentsOf: postProcessSteps.enumerated().map { index, step in
        let component = transformerRegistry.transformer(for: step.kind)
        guard let profile = profileRegistry.transformer(for: step.kind) else {
          issues.append(
            WorkflowExplanationIssue(
              kind: .componentUnclassified,
              component: .transformer,
              componentIndex: index
            )
          )
          return WorkflowExplanationTransform(
            kind: transformKind(for: step.kind),
            availability: .unclassified,
            usage: .required,
            processingDestination: .unclassified
          )
        }

        let availability: WorkflowExplanationAvailability
        if let component {
          if component.id == profile.componentID {
            availability = .available
          } else {
            availability = .unclassified
            issues.append(
              WorkflowExplanationIssue(
                kind: .componentUnclassified,
                component: .transformer,
                componentIndex: index
              )
            )
          }
        } else {
          availability = .unavailable
          issues.append(
            WorkflowExplanationIssue(
              kind: .componentUnavailable,
              component: .transformer,
              componentIndex: index
            )
          )
        }

        return WorkflowExplanationTransform(
          kind: profile.kind,
          availability: availability,
          usage: .required,
          processingDestination: profile.destination
        )
      })
    return transforms
  }

  private func explainOutputs(
    _ workflow: WorkflowDefinition,
    issues: inout [WorkflowExplanationIssue]
  ) -> [WorkflowExplanationOutput] {
    workflow.plan.output.actions.enumerated().flatMap { index, reference in
      let component = actionRegistry.action(for: reference.id)
      guard let profile = profileRegistry.output(for: reference.id) else {
        issues.append(
          WorkflowExplanationIssue(
            kind: .componentUnclassified,
            component: .outputAction,
            componentIndex: index
          )
        )
        return [
          WorkflowExplanationOutput(
            sourceActionIndex: index,
            effect: .unclassified,
            availability: .unclassified,
            configurationState: .unclassified,
            processingDestination: .unclassified
          )
        ]
      }

      let availability: WorkflowExplanationAvailability
      if component == nil {
        availability = .unavailable
        issues.append(
          WorkflowExplanationIssue(
            kind: .componentUnavailable,
            component: .outputAction,
            componentIndex: index
          )
        )
      } else {
        availability = .available
      }

      let configurationState = profile.configurationRequirement.state(
        of: reference.configuration, stage: .resolved
      )
      switch configurationState {
      case .missing:
        issues.append(
          WorkflowExplanationIssue(
            kind: .configurationMissing,
            component: .outputAction,
            componentIndex: index
          )
        )
      case .invalid:
        issues.append(
          WorkflowExplanationIssue(
            kind: .configurationInvalid,
            component: .outputAction,
            componentIndex: index
          )
        )
      case .notRequired, .configured, .unclassified:
        break
      }

      return profile.effects.map {
        WorkflowExplanationOutput(
          sourceActionIndex: index,
          effect: $0.effect,
          availability: availability,
          configurationState: configurationState,
          processingDestination: $0.destination
        )
      }
    }
  }

  private func triggerCategory(
    for trigger: TriggerBinding
  ) -> WorkflowExplanationTriggerCategory {
    switch trigger {
    case .manual: .manual
    case .hotkey: .hotkey
    case .menuBar: .menuBar
    case .wakeWord: .wakeWord
    }
  }

  private func transformKind(
    for kind: PostProcessStepKind
  ) -> WorkflowExplanationTransformKind {
    switch kind {
    case .snippetReplacement: .snippetReplacement
    case .llmRewrite: .languageModelRewrite
    case .llmAnswer: .languageModelAnswer
    case .normalizeWhitespace: .whitespaceNormalization
    }
  }

  private func orderedUniqueDestinations(
    _ values: [WorkflowExplanationProcessingDestination]
  ) -> [WorkflowExplanationProcessingDestination] {
    var result: [WorkflowExplanationProcessingDestination] = []
    for value in values where !result.contains(value) {
      result.append(value)
    }
    return result
  }

}
