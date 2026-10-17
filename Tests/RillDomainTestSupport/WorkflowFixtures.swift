import RillCore

public func makeTestAudioPlan(
  recognizerID: String,
  postProcessSteps: [PostProcessStep] = [],
  actions: [OutputActionReference] = []
) -> WorkflowPlan {
  WorkflowPlan(
    setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: recognizerID)),
    process: WorkflowProcessPhase(
      steps: [
        WorkflowProcessStep(kind: .recognizeSpeech),
        WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
        WorkflowProcessStep(kind: .applyVocabulary),
      ] + postProcessSteps.map(WorkflowProcessStep.init)),
    output: WorkflowOutputPhase(actions: actions, deliveryPolicy: .init(strategy: .immediate)))
}
