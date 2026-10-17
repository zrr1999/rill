import RillCore

public func makeTestAudioPlan(
  recognizerID: String,
  actions: [OutputActionReference] = []
) -> WorkflowPlan {
  WorkflowPlan(
    setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: recognizerID)),
    process: WorkflowProcessPhase(steps: [
      WorkflowProcessStep(kind: .recognizeSpeech),
      WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
      WorkflowProcessStep(kind: .applyVocabulary),
    ]),
    output: WorkflowOutputPhase(actions: actions, deliveryPolicy: .init(strategy: .immediate)))
}
