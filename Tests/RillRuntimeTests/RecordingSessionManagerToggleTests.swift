import Foundation
import XCTest

@testable import RillCore
@testable import RillPlatform
@testable import RillRuntime

private struct ToggleTestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private actor ToggleRecognitionProbe {
  private var request: RecognitionRequest?

  func record(_ request: RecognitionRequest) {
    self.request = request
  }

  func snapshot() -> RecognitionRequest? {
    request
  }
}

private struct ToggleRecognizer: SpeechRecognizer {
  let id = "toggle.recognizer"
  let probe: ToggleRecognitionProbe

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    await probe.record(request)
    return RecognitionResult(rawText: "recorded", bestText: "recorded")
  }
}

private actor ToggleActionProbe {
  private var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }

  func snapshot() -> [String] {
    values
  }
}

private actor RecordingCueOrderProbe {
  enum Event: Equatable, Sendable {
    case captureStarted
    case captureFinished
    case cue(RecordingInteractionCue)
  }

  private var events: [Event] = []

  func record(_ event: Event) {
    events.append(event)
  }

  func snapshot() -> [Event] {
    events
  }
}

private struct ToggleAction: OutputAction {
  let id = "toggle.action"
  let probe: ToggleActionProbe

  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    await probe.record(text)
    return .copiedToClipboard
  }
}

private actor ToggleAudioCaptureService: AudioCaptureService {
  private(set) var startRequest: AudioCaptureRequest?
  private(set) var finishCallCount = 0
  private(set) var cancelCallCount = 0
  private let audio: CapturedAudio
  private let cueOrderProbe: RecordingCueOrderProbe?

  init(audio: CapturedAudio, cueOrderProbe: RecordingCueOrderProbe? = nil) {
    self.audio = audio
    self.cueOrderProbe = cueOrderProbe
  }

  func startCapture(_ request: AudioCaptureRequest) async throws {
    startRequest = request
    await cueOrderProbe?.record(.captureStarted)
  }

  func finishCapture() async throws -> CapturedAudio {
    finishCallCount += 1
    await cueOrderProbe?.record(.captureFinished)
    return audio
  }

  func cancelCapture() async {
    cancelCallCount += 1
    startRequest = nil
  }

  func snapshot() -> AudioCaptureRequest? {
    startRequest
  }
}

private func makeToggleCapturedAudioProcessingQueue(
  sessionCoordinator: SessionCoordinator,
  eventBus: EventBus,
  diagnostics: DiagnosticsRecorder? = nil
) -> CapturedAudioProcessingQueue {
  CapturedAudioProcessingQueue(
    sessionCoordinator: sessionCoordinator,
    eventBus: eventBus,
    diagnostics: diagnostics
  )
}

final class RecordingSessionManagerToggleTests: XCTestCase {
  func testToggleModeStartsOnPressIgnoresReleaseAndStopsOnNextPress() async throws {
    let eventBus = EventBus()
    let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
    let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
    let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
    let requestProbe = ToggleRecognitionProbe()
    let actionProbe = ToggleActionProbe()
    let workflow = WorkflowDefinition(
      name: "Toggle Long Recording Workflow",
      trigger: .hotkey,
      pipeline: PipelineDeclaration(
        recognizerID: "toggle.recognizer",
        outputActions: [OutputActionReference(id: "toggle.action")]
      ),
      ui: WorkflowUIConfig(symbolName: "record.circle", accentColorName: "red")
    )
    let audio = try CapturedAudio(
      durationSeconds: 4.0,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: URL(fileURLWithPath: "/tmp/rill-toggle-recording.caf")
    )
    let cueOrderProbe = RecordingCueOrderProbe()
    let audioCaptureService = ToggleAudioCaptureService(
      audio: audio,
      cueOrderProbe: cueOrderProbe
    )
    let coordinator = SessionCoordinator(
      contextProvider: ToggleTestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: [
        ToggleRecognizer(probe: requestProbe)
      ]),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [ToggleAction(probe: actionProbe)]),
      candidateResolver: resolver,
      deliveryStack: deliveryStack,
      eventBus: eventBus,
      diagnostics: diagnostics
    )
    let manager = RecordingSessionManager(
      audioCaptureService: audioCaptureService,
      hotkeyTap: HotkeyEventTap(),
      capturedAudioProcessingQueue: makeToggleCapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus,
        diagnostics: diagnostics
      ),
      eventBus: eventBus,
      diagnostics: diagnostics,
      privacyRunGate: PrivacyRunGate(
        settingsProvider: {
          PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: false
          )
        },
        cloudConfirmationProvider: { _, _, _ in true },
        destinationClassifier: { _ in .classified([.localSpeech]) }
      ),
      workflowProvider: { [workflow] },
      longRecordingModeProvider: { true },
      recognizerDurationProvider: { recognizerID in
        recognizerID == "toggle.recognizer" ? 20 : nil
      },
      recordingCueAction: { cue in
        await cueOrderProbe.record(.cue(cue))
      }
    )

    let stream = await eventBus.stream()
    let collector = Task { () -> [RillEvent] in
      var events: [RillEvent] = []
      for await event in stream {
        events.append(event)
        if case .runCompleted = event {
          break
        }
      }
      return events
    }
    await Task.yield()

    await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
    let startRequest = await audioCaptureService.snapshot()
    guard case .recording = await manager.currentState() else {
      return XCTFail("Expected long recording to stay active after first press")
    }
    XCTAssertEqual(startRequest?.triggerEvent?.sourceID, "long-recording")
    XCTAssertEqual(startRequest?.metadata["controlMode"], "toggle")
    XCTAssertEqual(startRequest?.maxDurationSeconds, 20)
    XCTAssertNil(
      startRequest?.endpointControl,
      "Long recording must not be cut off by short-dictation silence endpointing."
    )

    await manager.processHotkeyEvent(.pushToTalkReleased(.fnHold))
    guard case .recording = await manager.currentState() else {
      return XCTFail("Expected release to be ignored in long recording mode")
    }
    let releaseFinishCallCount = await audioCaptureService.finishCallCount
    let releaseCancelCallCount = await audioCaptureService.cancelCallCount
    XCTAssertEqual(releaseFinishCallCount, 0)
    XCTAssertEqual(releaseCancelCallCount, 0)

    await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
    let events = await collector.value
    let recognitionRequest = await requestProbe.snapshot()
    let actionValues = await actionProbe.snapshot()
    let finalState = await manager.currentState()
    let finalFinishCallCount = await audioCaptureService.finishCallCount
    let cueOrder = await cueOrderProbe.snapshot()

    XCTAssertEqual(finalState, .idle)
    XCTAssertEqual(finalFinishCallCount, 1)
    XCTAssertEqual(recognitionRequest?.capturedAudio, audio)
    XCTAssertEqual(recognitionRequest?.triggerEvent?.sourceID, "long-recording")
    XCTAssertEqual(recognitionRequest?.triggerEvent?.metadata["controlMode"], "toggle")
    XCTAssertEqual(actionValues, ["recorded"])
    XCTAssertEqual(
      cueOrder,
      [.captureStarted, .cue(.started), .captureFinished, .cue(.stopped)],
      "Start feedback must follow confirmed capture readiness, and stop feedback must follow input shutdown."
    )
    XCTAssertTrue(
      events.contains { event in
        if case .runCompleted(let summary) = event {
          return summary.workflow.fallbackName == workflow.name
        }
        return false
      })
  }
}
