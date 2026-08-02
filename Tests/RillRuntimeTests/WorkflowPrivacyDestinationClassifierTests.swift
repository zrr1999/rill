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
        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.liveSubtitleNetworkUsage(for: workflow),
            .online
        )
    }

    func testLiveSubtitleNetworkUsageDistinguishesOfflineAndUnknownWorkflows() {
        let offline = WorkflowDefinition(
            name: "Local Dictation",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "inject.text")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "green")
        )
        let unknown = WorkflowDefinition(
            name: "Unknown Provider",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "unclassified.speech",
                outputActions: []
            ),
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
