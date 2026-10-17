@testable import RillCore
@testable import RillWorkflows
import XCTest

final class WorkflowPrivacyDestinationClassifierTests: XCTestCase {
  func testVoiceAssistantClassifiesLocalRecognitionCloudLLMAndLocalSpeechOutput() {
    var workflow = WorkflowDefinition(
      name: "Voice Assistant",
      trigger: .wakeWord,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "sherpa-onnx.local")),
        process: WorkflowProcessPhase(
          steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ]
            + ([
              PostProcessStep(kind: .llmRewrite, prompt: "Answer briefly", reasoning: .some(.none))
            ]).map(WorkflowProcessStep.init)),
        output: WorkflowOutputPhase(actions: [OutputActionReference(id: SpeechOutputActionID.speak)], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple")
    )
    workflow.plan.setup.wakeWord = WakeWordConfiguration(phrases: ["Hey Rill"])

    XCTAssertEqual(
      WorkflowPrivacyDestinationClassifier.classify(workflow),
      .classified([.localSpeech, .cloudText])
    )
    XCTAssertEqual(
      WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: workflow),
      .online
    )
  }

  func testLiveSubtitleNetworkUsageDistinguishesOfflineAndUnknownWorkflows() {
    let offline = WorkflowDefinition(
      name: "Local Dictation",
      trigger: .hotkey,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "sherpa-onnx.local")),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
          WorkflowProcessStep(kind: .applyVocabulary),
        ]), output: WorkflowOutputPhase(actions: [OutputActionReference(id: "focused-application.insert")], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "green")
    )
    let unknown = WorkflowDefinition(
      name: "Unknown Provider",
      trigger: .hotkey,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "unclassified.speech")),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
          WorkflowProcessStep(kind: .applyVocabulary),
        ]), output: WorkflowOutputPhase(actions: [], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "questionmark", accentColorName: "orange")
    )

    XCTAssertEqual(
      WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: offline),
      .offline
    )
    XCTAssertEqual(
      WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: unknown),
      .unknown
    )
  }

  func testSpeechOutputRemainsLocalWhenRecognizerIsSkippedForTextReplay() {
    let workflow = WorkflowDefinition(
      name: "Read Item",
      trigger: .manual,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "remote.speech")),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
          WorkflowProcessStep(kind: .applyVocabulary),
        ]), output: WorkflowOutputPhase(actions: [OutputActionReference(id: SpeechOutputActionID.speak)], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "speaker.wave.2", accentColorName: "blue")
    )
    let invocation = WorkflowRunInvocation.record(
      subject: RecordDeliverySubject(
        recordID: RecordID(),
        membershipID: RecordMembershipID(),
        membershipRevision: 0,
        collectionID: RecordCollection.inboxID,
        payloadKind: .text
      ),
      operation: .replay
    )

    XCTAssertEqual(
      WorkflowPrivacyDestinationClassifier.classify(
        workflow,
        invocation: invocation
      ),
      .classified([.localSpeech])
    )
  }
}
