import XCTest
@testable import RillCore
@testable import RillRuntime

final class WorkflowPrivacyDestinationClassifierTests: XCTestCase {
    func testVoiceAssistantClassifiesLocalRecognitionCloudLLMAndLocalSpeechOutput() {
        var workflow = WorkflowDefinition(
            name: "Voice Assistant",
            trigger: .wakeWord,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [
                    PostProcessStep(kind: .llmRewrite, prompt: "Answer briefly")
                ],
                outputActions: [OutputActionReference(id: SpeechOutputActionID.speak)]
            ),
            ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "purple")
        )
        workflow.plan.setup.wakeWord = WakeWordConfiguration(phrases: ["Hey Rill"])

        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.classify(workflow),
            .classified([.localSpeech, .cloudText])
        )
    }

    func testSpeechOutputRemainsLocalWhenRecognizerIsSkippedForTextReplay() {
        let workflow = WorkflowDefinition(
            name: "Read Item",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "remote.speech",
                outputActions: [OutputActionReference(id: SpeechOutputActionID.speak)]
            ),
            ui: WorkflowUIConfig(symbolName: "speaker.wave.2", accentColorName: "blue")
        )
        let invocation = WorkflowRunInvocation.clipboardItem(
            subject: ClipboardItemDryRunSubject(
                itemID: UUID(),
                itemVersion: ClipboardItemVersion(),
                groupID: ClipboardGroup.defaultGroupID,
                contentKind: .text,
                hasTransferableContent: true
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
