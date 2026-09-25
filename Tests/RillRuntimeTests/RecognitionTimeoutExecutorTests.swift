@testable import RillWorkflows
import Foundation
import XCTest

@testable import RillCore

private struct TimeoutTestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private actor HangingRecognitionProbe {
  private var invocationCount = 0
  private var firstCallStarted = false
  private var firstCallStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstCallContinuation: CheckedContinuation<RecognitionResult, Never>?
  private var firstCallAudioFileURL: URL?

  func recognize(_ request: RecognitionRequest) async -> RecognitionResult {
    invocationCount += 1
    guard invocationCount == 1 else {
      return RecognitionResult(rawText: "fresh result", bestText: "fresh result")
    }

    firstCallStarted = true
    firstCallAudioFileURL = request.capturedAudio?.fileURL
    let waiters = firstCallStartWaiters
    firstCallStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return await withCheckedContinuation { continuation in
      firstCallContinuation = continuation
    }
  }

  func waitUntilFirstCallStarts() async {
    if firstCallStarted { return }
    await withCheckedContinuation { continuation in
      firstCallStartWaiters.append(continuation)
    }
  }

  func releaseFirstCall() {
    let continuation = firstCallContinuation
    firstCallContinuation = nil
    continuation?.resume(
      returning: RecognitionResult(rawText: "late result", bestText: "late result")
    )
  }

  func callCount() -> Int {
    invocationCount
  }

  func capturedAudioFileURL() -> URL? {
    firstCallAudioFileURL
  }
}

private struct HangingTestRecognizer: SpeechRecognizer {
  let id: String
  let probe: HangingRecognitionProbe

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    await probe.recognize(request)
  }
}

private struct ImmediateTestRecognizer: SpeechRecognizer {
  let id: String
  let text: String

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    RecognitionResult(rawText: text, bestText: text)
  }
}

private actor TimeoutActionProbe {
  private var workflowNames: [String] = []

  func record(_ workflowName: String) {
    workflowNames.append(workflowName)
  }

  func snapshot() -> [String] {
    workflowNames
  }
}

private struct TimeoutProbeAction: OutputAction {
  let id = "probe.action"
  let probe: TimeoutActionProbe

  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    await probe.record(context.workflow.name)
    return .copiedToClipboard
  }
}

private enum RecognitionCallOutcome: Sendable, Equatable {
  case completed
  case cancelled
  case deadline(RecognitionDeadlineError)
  case otherFailure
}

private actor TimeoutTestValueBox<Value: Sendable> {
  private var value: Value?

  func store(_ value: Value) {
    self.value = value
  }

  func snapshot() -> Value? {
    value
  }
}

final class RecognitionTimeoutExecutorTests: XCTestCase {
  func testStandardPolicyScalesLongRecordingsAndKeepsAHardCeiling() {
    let policy = RecognitionTimeoutPolicy.standard

    XCTAssertEqual(policy.timeoutSeconds(forAudioDuration: nil), 120)
    XCTAssertEqual(policy.timeoutSeconds(forAudioDuration: 20), 120)
    XCTAssertEqual(policy.timeoutSeconds(forAudioDuration: 120), 240)
    XCTAssertEqual(policy.timeoutSeconds(forAudioDuration: 1_800), 600)
    XCTAssertEqual(policy.timeoutSeconds(forAudioDuration: .infinity), 120)
  }

  func testNonCooperativeRecognizerTimesOutAndRemainsQuarantinedUntilItFinishes() async {
    let executor = RecognitionTimeoutExecutor()
    let probe = HangingRecognitionProbe()
    let recognizer = HangingTestRecognizer(id: "timeout.hanging", probe: probe)
    let request = makeRequest(recognizerID: recognizer.id)
    let firstCall = Task { () -> RecognitionCallOutcome in
      do {
        _ = try await executor.recognize(
          using: recognizer,
          request: request,
          timeout: .milliseconds(20)
        )
        return .completed
      } catch let error as RecognitionDeadlineError {
        return .deadline(error)
      } catch is CancellationError {
        return .cancelled
      } catch {
        return .otherFailure
      }
    }

    await probe.waitUntilFirstCallStarts()
    let firstOutcome = await awaitValue(
      from: firstCall,
      timeoutMessage: "Recognition timeout did not return",
      onTimeout: { await probe.releaseFirstCall() }
    )
    XCTAssertEqual(firstOutcome, .deadline(.timedOut))

    let remainsActive = await executor.hasActiveOperation(for: recognizer.id)
    let firstCallCount = await probe.callCount()
    XCTAssertTrue(remainsActive)
    XCTAssertEqual(firstCallCount, 1)
    do {
      _ = try await executor.recognize(
        using: recognizer,
        request: request,
        timeout: .seconds(1)
      )
      XCTFail("Expected the recognizer lane to remain quarantined")
    } catch {
      XCTAssertEqual(
        error as? RecognitionDeadlineError,
        .previousOperationStillFinishing
      )
    }
    let quarantinedCallCount = await probe.callCount()
    XCTAssertEqual(quarantinedCallCount, 1)

    await probe.releaseFirstCall()
    await waitUntilRecognizerRetires(executor, recognizerID: recognizer.id)
    let recovered = try? await executor.recognize(
      using: recognizer,
      request: request,
      timeout: .seconds(1)
    )

    XCTAssertEqual(recovered?.bestText, "fresh result")
    let recoveredCallCount = await probe.callCount()
    XCTAssertEqual(recoveredCallCount, 2)
  }

  func testParentCancellationRemainsCancellationInsteadOfTimeout() async throws {
    let executor = RecognitionTimeoutExecutor()
    let probe = HangingRecognitionProbe()
    let recognizer = HangingTestRecognizer(id: "timeout.cancelled", probe: probe)
    let audio = try makeManagedCapturedAudio()
    let audioFileURL = try XCTUnwrap(audio.fileURL)
    defer { try? FileManager.default.removeItem(at: audioFileURL) }
    let request = makeRequest(recognizerID: recognizer.id, capturedAudio: audio)
    let task = Task { () -> RecognitionCallOutcome in
      do {
        _ = try await executor.recognize(
          using: recognizer,
          request: request,
          timeout: .seconds(60)
        )
        return .completed
      } catch let error as RecognitionDeadlineError {
        return .deadline(error)
      } catch is CancellationError {
        return .cancelled
      } catch {
        return .otherFailure
      }
    }

    await probe.waitUntilFirstCallStarts()
    let capturedAudioFileURL = await probe.capturedAudioFileURL()
    let isolatedAudioFileURL = try XCTUnwrap(capturedAudioFileURL)
    XCTAssertNotEqual(isolatedAudioFileURL, audioFileURL)
    XCTAssertTrue(
      isolatedAudioFileURL.lastPathComponent.hasPrefix(
        RecognitionTemporaryAudioNamespace.currentProcessFilenamePrefix
      )
    )
    task.cancel()
    let cancellationOutcome = await awaitValue(
      from: task,
      timeoutMessage: "Recognition cancellation did not return",
      onTimeout: { await probe.releaseFirstCall() }
    )
    XCTAssertEqual(cancellationOutcome, .cancelled)

    XCTAssertTrue(FileManager.default.fileExists(atPath: audioFileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedAudioFileURL.path))

    await probe.releaseFirstCall()
    await waitUntilRecognizerRetires(executor, recognizerID: recognizer.id)
    await waitUntilFileIsRemoved(isolatedAudioFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioFileURL.path))
  }

  func testCoordinatorParentCancellationRemainsCancelledDuringRecognition() async throws {
    let eventBus = EventBus()
    let probe = HangingRecognitionProbe()
    let actionProbe = TimeoutActionProbe()
    let recognizer = HangingTestRecognizer(id: "timeout.coordinator.cancel", probe: probe)
    let workflow = makeWorkflow(
      name: "Cancelled Workflow",
      recognizerID: recognizer.id
    )
    let coordinator = makeCoordinator(
      recognizers: [recognizer],
      eventBus: eventBus,
      actionProbe: actionProbe,
      timeoutSeconds: 60
    )
    let runID = UUID()
    let audio = try makeCapturedAudio()
    let run = Task {
      await coordinator.runReportingOutcome(
        workflow: workflow,
        runID: runID,
        capturedAudio: audio,
        contextSnapshot: .empty
      )
    }

    await probe.waitUntilFirstCallStarts()
    run.cancel()
    let outcome = await awaitValue(
      from: run,
      timeoutMessage: "Coordinator cancellation did not return",
      onTimeout: { await probe.releaseFirstCall() }
    )

    XCTAssertEqual(
      outcome,
      .cancelled(
        WorkflowRunCancelledSummary(
          runID: runID,
          stage: .recognizing,
          wasPartiallyCompleted: false
        )
      )
    )
    let coordinatorState = await coordinator.currentState()
    let actionSnapshot = await actionProbe.snapshot()
    XCTAssertEqual(coordinatorState, .idle)
    XCTAssertTrue(actionSnapshot.isEmpty)

    await probe.releaseFirstCall()
  }

  func testCoordinatorRejectsLateRecognitionAfterTimeout() async throws {
    let eventBus = EventBus()
    let probe = HangingRecognitionProbe()
    let actionProbe = TimeoutActionProbe()
    let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
    let recognizer = HangingTestRecognizer(id: "sherpa-onnx.local", probe: probe)
    let workflow = makeWorkflow(
      name: "Timed Out Workflow",
      recognizerID: recognizer.id
    )
    let coordinator = makeCoordinator(
      recognizers: [recognizer],
      eventBus: eventBus,
      actionProbe: actionProbe,
      timeoutSeconds: 0.02,
      diagnostics: diagnostics
    )
    let runID = UUID()
    let barrierID = UUID()
    let deliveryStream = eventBus.lifecycleDeliveryStream
    let deliveredEvents = Task { () -> [RillEvent] in
      var events: [RillEvent] = []
      for await delivery in deliveryStream {
        switch delivery {
        case .event(let event):
          events.append(event)
        case .barrier(let deliveredBarrierID) where deliveredBarrierID == barrierID:
          return events
        case .barrier:
          continue
        }
      }
      return events
    }
    let audio = try makeCapturedAudio()
    let run = Task {
      await coordinator.runReportingOutcome(
        workflow: workflow,
        runID: runID,
        capturedAudio: audio,
        contextSnapshot: .empty
      )
    }

    await probe.waitUntilFirstCallStarts()
    let outcome = await awaitValue(
      from: run,
      timeoutMessage: "Coordinator timeout did not return",
      onTimeout: { await probe.releaseFirstCall() }
    )
    XCTAssertEqual(
      outcome,
      .failed(
        WorkflowRunFailureSummary(
          runID: runID,
          stage: .recognizing,
          code: .processing
        )
      )
    )
    let coordinatorState = await coordinator.currentState()
    let actionsBeforeLateResult = await actionProbe.snapshot()
    XCTAssertEqual(coordinatorState, .idle)
    XCTAssertTrue(actionsBeforeLateResult.isEmpty)

    await probe.releaseFirstCall()
    try await Task.sleep(for: .milliseconds(20))
    await eventBus.publishBarrier(barrierID)
    let events = await deliveredEvents.value

    XCTAssertEqual(events.filter(\.isRunFailure).count, 1)
    XCTAssertFalse(events.contains(where: \.isRecognitionCompletion))
    XCTAssertFalse(events.contains(where: \.isRunCompletion))
    XCTAssertFalse(events.contains(where: \.isActionExecution))
    let timeoutDiagnostic = await diagnostics.snapshot().first {
      $0.event == "session.recognition.timeout"
    }
    XCTAssertEqual(timeoutDiagnostic?.message, DiagnosticEventSanitizer.sanitizedMessage)
    XCTAssertEqual(timeoutDiagnostic?.metadata, ["recognizerID": recognizer.id])
  }

  func testBackgroundQueueSkipsQuarantinedRecognizerAndContinuesAfterTimeout() async throws {
    let eventBus = EventBus()
    let hangingProbe = HangingRecognitionProbe()
    let actionProbe = TimeoutActionProbe()
    let hangingRecognizer = HangingTestRecognizer(
      id: "timeout.queue.hanging",
      probe: hangingProbe
    )
    let immediateRecognizer = ImmediateTestRecognizer(
      id: "timeout.queue.immediate",
      text: "second result"
    )
    let coordinator = makeCoordinator(
      recognizers: [hangingRecognizer, immediateRecognizer],
      eventBus: eventBus,
      actionProbe: actionProbe,
      timeoutSeconds: 0.02
    )
    let queue = CapturedAudioProcessingQueue(
      sessionCoordinator: coordinator,
      eventBus: eventBus
    )
    let firstWorkflow = makeWorkflow(
      name: "First Timed Out Workflow",
      recognizerID: hangingRecognizer.id
    )
    let secondWorkflow = makeWorkflow(
      name: "Second Quarantined Workflow",
      recognizerID: hangingRecognizer.id
    )
    let thirdWorkflow = makeWorkflow(
      name: "Third Successful Workflow",
      recognizerID: immediateRecognizer.id
    )
    let firstAudio = try makeManagedCapturedAudio()
    let firstAudioFileURL = try XCTUnwrap(firstAudio.fileURL)
    defer { try? FileManager.default.removeItem(at: firstAudioFileURL) }
    let secondAudio = try makeCapturedAudio()

    await queue.enqueue(
      authorizationLease: makeAudioProcessingTestLease(
        runID: UUID(),
        workflow: firstWorkflow
      ),
      triggerEvent: nil,
      deferredCapture: .resolved(firstAudio)
    )
    await queue.enqueue(
      authorizationLease: makeAudioProcessingTestLease(
        runID: UUID(),
        workflow: secondWorkflow
      ),
      triggerEvent: nil,
      deferredCapture: .resolved(secondAudio)
    )
    await queue.enqueue(
      authorizationLease: makeAudioProcessingTestLease(
        runID: UUID(),
        workflow: thirdWorkflow
      ),
      triggerEvent: nil,
      deferredCapture: .resolved(secondAudio)
    )

    await hangingProbe.waitUntilFirstCallStarts()
    let capturedAudioFileURL = await hangingProbe.capturedAudioFileURL()
    let isolatedAudioFileURL = try XCTUnwrap(capturedAudioFileURL)
    XCTAssertNotEqual(isolatedAudioFileURL, firstAudioFileURL)
    XCTAssertTrue(
      isolatedAudioFileURL.lastPathComponent.hasPrefix(
        RecognitionTemporaryAudioNamespace.currentProcessFilenamePrefix
      )
    )
    for _ in 0..<200 {
      if await queue.snapshot().pendingCount == 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }

    let finalQueueSnapshot = await queue.snapshot()
    let completedWorkflows = await actionProbe.snapshot()
    XCTAssertEqual(finalQueueSnapshot.pendingCount, 0)
    XCTAssertEqual(completedWorkflows, ["Third Successful Workflow"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstAudioFileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedAudioFileURL.path))
    await hangingProbe.releaseFirstCall()
    await waitUntilFileIsRemoved(isolatedAudioFileURL)
    await queue.shutdown()
  }

  private func makeRequest(
    recognizerID: String,
    capturedAudio: CapturedAudio? = nil
  ) -> RecognitionRequest {
    let workflow = makeWorkflow(
      name: "Timeout Executor Workflow",
      recognizerID: recognizerID,
      outputActions: []
    )
    return RecognitionRequest(
      runID: UUID(),
      workflow: workflow,
      contextSnapshot: .empty,
      capturedAudio: capturedAudio
    )
  }

  private func makeWorkflow(
    name: String,
    recognizerID: String,
    outputActions: [OutputActionReference] = [OutputActionReference(id: "probe.action")]
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      name: name,
      pipeline: PipelineDeclaration(
        recognizerID: recognizerID,
        outputActions: outputActions
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
  }

  private func makeCoordinator(
    recognizers: [any SpeechRecognizer],
    eventBus: EventBus,
    actionProbe: TimeoutActionProbe,
    timeoutSeconds: Double,
    diagnostics: DiagnosticsRecorder? = nil
  ) -> SessionCoordinator {
    SessionCoordinator(
      contextProvider: TimeoutTestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: recognizers),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(
        actions: [TimeoutProbeAction(probe: actionProbe)]
      ),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      eventBus: eventBus,
      diagnostics: diagnostics,
      recognitionTimeoutPolicy: RecognitionTimeoutPolicy(
        minimumTimeoutSeconds: timeoutSeconds,
        audioDurationMultiplier: 0,
        additionalGraceSeconds: 0,
        maximumTimeoutSeconds: timeoutSeconds
      )
    )
  }

  private func makeCapturedAudio() throws -> CapturedAudio {
    try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      inlineData: Data([0])
    )
  }

  private func makeManagedCapturedAudio() throws -> CapturedAudio {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-timeout-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    try Data([0]).write(to: fileURL, options: .atomic)
    return try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      fileURL: fileURL,
      fileOwnership: .managedTemporary
    )
  }

  private func waitUntilFileIsRemoved(_ fileURL: URL) async {
    for _ in 0..<200 {
      if !FileManager.default.fileExists(atPath: fileURL.path) { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Managed temporary audio was not removed after recognition retired")
  }

  private func waitUntilRecognizerRetires(
    _ executor: RecognitionTimeoutExecutor,
    recognizerID: String
  ) async {
    for _ in 0..<200 {
      if !(await executor.hasActiveOperation(for: recognizerID)) { return }
      await Task.yield()
    }
    XCTFail("Recognizer did not retire")
  }

  private func awaitValue<Value: Sendable>(
    from task: Task<Value, Never>,
    timeoutMessage: String,
    onTimeout: @escaping @Sendable () async -> Void
  ) async -> Value {
    let returned = expectation(description: timeoutMessage)
    let box = TimeoutTestValueBox<Value>()
    let observer = Task {
      let value = await task.value
      await box.store(value)
      returned.fulfill()
    }

    await fulfillment(of: [returned], timeout: 1)
    if let value = await box.snapshot() {
      return value
    }

    await onTimeout()
    task.cancel()
    let value = await task.value
    observer.cancel()
    return value
  }
}

extension RillEvent {
  fileprivate var isRecognitionCompletion: Bool {
    if case .recognitionCompleted = self { return true }
    return false
  }

  fileprivate var isActionExecution: Bool {
    if case .actionExecuted = self { return true }
    return false
  }

  fileprivate var isRunCompletion: Bool {
    if case .runCompleted = self { return true }
    return false
  }

  fileprivate var isRunFailure: Bool {
    if case .runFailed = self { return true }
    return false
  }
}
