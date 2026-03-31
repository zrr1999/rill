import Foundation
import XCTest
@testable import VoxTypeCore
@testable import VoxTypePlatform
@testable import VoxTypeRuntime

private struct RecordingTestContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private actor RecordingRequestProbe {
    private var request: RecognitionRequest?

    func record(_ request: RecognitionRequest) {
        self.request = request
    }

    func snapshot() -> RecognitionRequest? {
        request
    }
}

private struct RecordingRecognizer: SpeechRecognizer {
    let id = "recording.recognizer"
    let probe: RecordingRequestProbe

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.record(request)
        return RecognitionResult(rawText: "recorded", bestText: "recorded")
    }
}

private actor RecordingActionProbe {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private struct RecordingAction: OutputAction {
    let id = "recording.action"
    let probe: RecordingActionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.record(text)
        return .copiedToClipboard
    }
}

private actor MockAudioCaptureService: AudioCaptureService {
    private(set) var startRequest: AudioCaptureRequest?
    private let audio: CapturedAudio

    init(audio: CapturedAudio) {
        self.audio = audio
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        startRequest = request
    }

    func finishCapture() async throws -> CapturedAudio {
        audio
    }

    func cancelCapture() async {
        startRequest = nil
    }

    func snapshot() -> AudioCaptureRequest? {
        startRequest
    }
}

final class RecordingSessionManagerTests: XCTestCase {
    func testPushToTalkRunsHotkeyWorkflowWithCapturedAudio() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let requestProbe = RecordingRequestProbe()
        let actionProbe = RecordingActionProbe()
        let workflow = WorkflowDefinition(
            name: "Push to Talk Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.5,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/voxtype-recording.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(
            contextProvider: RecordingTestContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: requestProbe)]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: actionProbe)]),
            candidateResolver: resolver,
            deliveryStack: deliveryStack,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            workflowProvider: { [workflow] }
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> [VoxTypeEvent] in
            var events: [VoxTypeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await manager.beginPushToTalk()
        let captureRequest = await audioCaptureService.snapshot()

        await manager.endPushToTalk()
        let events = await collector.value
        let recognitionRequest = await requestProbe.snapshot()
        let actionValues = await actionProbe.snapshot()
        let currentState = await manager.currentState()

        XCTAssertEqual(captureRequest?.workflow.id, workflow.id)
        XCTAssertEqual(recognitionRequest?.capturedAudio, audio)
        XCTAssertEqual(recognitionRequest?.triggerEvent?.binding, .hotkey)
        XCTAssertEqual(actionValues, ["recorded"])
        XCTAssertEqual(currentState, .idle)
        XCTAssertTrue(events.contains { event in
            if case .runCompleted(let summary) = event {
                return summary.workflow.fallbackName == workflow.name
            }
            return false
        })
    }

    func testPushToTalkIgnoresNonHotkeyWorkflow() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Manual Workflow",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/voxtype-manual.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(
            contextProvider: RecordingTestContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            workflowProvider: { [workflow] }
        )

        await manager.beginPushToTalk()
        let currentState = await manager.currentState()
        let captureRequest = await audioCaptureService.snapshot()

        XCTAssertEqual(currentState, .idle)
        XCTAssertNil(captureRequest)
    }

    func testPushToTalkPublishesFailureWhenHotkeyWorkflowsConflict() async throws {
        let eventBus = EventBus()
        let workflowA = WorkflowDefinition(
            name: "Hotkey A",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let workflowB = WorkflowDefinition(
            name: "Hotkey B",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/voxtype-hotkey-conflict.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(
            contextProvider: RecordingTestContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            workflowProvider: { [workflowA, workflowB] }
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> VoxTypeEvent? in
            for await event in stream {
                if case .runFailed = event {
                    return event
                }
            }
            return nil
        }
        await Task.yield()

        await manager.beginPushToTalk()
        let currentState = await manager.currentState()
        let captureRequest = await audioCaptureService.snapshot()
        let failureEvent = await collector.value

        XCTAssertEqual(currentState, .idle)
        XCTAssertNil(captureRequest)
        XCTAssertNotNil(failureEvent)
        if case .runFailed(_, _, let message)? = failureEvent {
            XCTAssertTrue(message.contains("Hotkey A"))
            XCTAssertTrue(message.contains("Hotkey B"))
        } else {
            XCTFail("Expected runFailed event")
        }
    }
}
