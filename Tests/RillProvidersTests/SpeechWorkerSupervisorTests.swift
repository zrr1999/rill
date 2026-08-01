import Darwin
import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

private let speechWorkerTestRequestID = UUID(
  uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
)!

final class SpeechWorkerSupervisorTests: XCTestCase {
  func testModelPreparationUsesPersistentWorkerProtocol() async throws {
    let response = makePreparationResponse(
      requestID: speechWorkerTestRequestID,
      generation: 1
    )
    let supervisor = makeSupervisor(script: persistentResponseScript, response: response)

    let prepared = try await supervisor.prepareModel(
      SpeechWorkerModelPreparationPayload(
        modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
        downloadIfNeeded: true
      ),
      timeout: .seconds(2)
    )

    XCTAssertEqual(prepared, MLXAudioModelID.qwen3ASR17BInt8.rawValue)
    let activeProcessIdentifier = await supervisor.activeProcessIdentifier()
    XCTAssertNotNil(activeProcessIdentifier)
    try await supervisor.shutdown()
  }

  func testModelPreparationForwardsProgressFramesBeforeFinalResponse() async throws {
    let progressResponse = makePreparationProgressResponse(
      requestID: speechWorkerTestRequestID,
      generation: 1
    )
    let finalResponse = makePreparationResponse(
      requestID: speechWorkerTestRequestID,
      generation: 1
    )
    let recorder = WorkerProgressRecorder()
    let supervisor = makeSupervisor(
      script: persistentResponseScript,
      response: progressResponse + finalResponse
    )

    let prepared = try await supervisor.prepareModel(
      SpeechWorkerModelPreparationPayload(
        modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
        downloadIfNeeded: true
      ),
      timeout: .seconds(2),
      progress: recorder.record
    )

    XCTAssertEqual(prepared, MLXAudioModelID.qwen3ASR17BInt8.rawValue)
    XCTAssertEqual(
      recorder.snapshot(),
      [
        SpeechWorkerProgress(
          phase: .downloading,
          completedUnitCount: 25,
          totalUnitCount: 100
        )
      ]
    )
    try await supervisor.shutdown()
  }

  func testConcurrentRecognitionRequestsUseTheSingleWorkerLaneInOrder() async throws {
    let response = makeSuccessResponse(
      requestID: speechWorkerTestRequestID,
      generation: 1
    )
    let supervisor = makeSupervisor(
      script: "while IFS= read -r request; do sleep 0.05; printf '%s' \"$1\"; done",
      response: response
    )
    let payload = makePayload()

    async let first = supervisor.recognize(payload, timeout: .seconds(2))
    async let second = supervisor.recognize(payload, timeout: .seconds(2))
    let results = try await [first, second]

    XCTAssertEqual(results.map(\.bestText), ["worker result", "worker result"])
    try await supervisor.shutdown()
  }

  func testCancellingAQueuedRecognitionDoesNotCancelTheActiveRequest() async throws {
    let response = makeSuccessResponse(
      requestID: speechWorkerTestRequestID,
      generation: 1
    )
    let supervisor = makeSupervisor(
      script: "while IFS= read -r request; do sleep 0.1; printf '%s' \"$1\"; done",
      response: response
    )
    let payload = makePayload()
    let first = Task {
      try await supervisor.recognize(payload, timeout: .seconds(2))
    }
    _ = try await waitForPID(supervisor)
    let second = Task {
      try await supervisor.recognize(payload, timeout: .seconds(2))
    }
    await waitUntil {
      await supervisor.queuedRequestCountForTesting() == 1
    }
    let queuedRequestCount = await supervisor.queuedRequestCountForTesting()
    XCTAssertEqual(queuedRequestCount, 1)

    second.cancel()
    do {
      _ = try await second.value
      XCTFail("Expected the queued request to be cancelled")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }

    let firstResult = try await first.value
    XCTAssertEqual(firstResult.bestText, "worker result")
    let thirdResult = try await supervisor.recognize(
      payload,
      timeout: .seconds(2)
    )
    XCTAssertEqual(thirdResult.bestText, "worker result")
    try await supervisor.shutdown()
  }

  func testRecognizerAdapterUsesWorkerResultWithoutInProcessFallback() async throws {
    let response = makeSuccessResponse(requestID: speechWorkerTestRequestID, generation: 1)
    let supervisor = makeSupervisor(script: persistentResponseScript, response: response)
    let recognizer = SherpaOnnxWorkerRecognizer(
      supervisor: supervisor,
      configuration: .init(downloadIfNeeded: false),
      workerTimeout: .seconds(2)
    )
    let audioURL = try makeManagedAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let audio = try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32),
      fileURL: audioURL,
      fileOwnership: .managedTemporary
    )

    let result = try await recognizer.recognize(
      RecognitionRequest(
        runID: UUID(),
        workflow: makeWorkflow(),
        contextSnapshot: .empty,
        capturedAudio: audio,
        options: SpeechRecognitionRequestOptions(
          language: "zh-CN",
          hints: RecognitionHints(keyterms: ["Rill"])
        )
      )
    )

    XCTAssertEqual(result.bestText, "worker result")
    XCTAssertEqual(result.metadata["provider.kind"], "sherpa-onnx")
    try await recognizer.stopRuntime()
    let activePID = await supervisor.activeProcessIdentifier()
    XCTAssertNil(activePID)
  }

  func testTimeoutWaitsForTermThenKillAndReapsPID() async throws {
    let supervisor = makeSupervisor(
      script: "trap '' TERM; IFS= read -r request || exit 0; while :; do :; done",
      response: ""
    )
    let startedAt = ContinuousClock.now
    let payload = makePayload()
    let task = Task {
      try await supervisor.recognize(payload, timeout: .milliseconds(20))
    }
    let pid = try await waitForPID(supervisor)

    do {
      _ = try await task.value
      XCTFail("Expected the worker request to time out")
    } catch {
      XCTAssertEqual(error as? SpeechWorkerClientError, .requestTimedOut)
    }

    let elapsed = startedAt.duration(to: .now)
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))
    XCTAssertLessThan(elapsed, .seconds(2))
    let pidIsGone = await waitUntilPIDIsGone(pid)
    let activePID = await supervisor.activeProcessIdentifier()
    XCTAssertTrue(pidIsGone)
    XCTAssertNil(activePID)
  }

  func testCancellationDoesNotReturnUntilTermIgnoringWorkerIsReaped() async throws {
    let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-worker-ready-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let script = """
      trap '' TERM
      : > "$1"
      IFS= read -r request || exit 0
      while :; do :; done
      """
    let supervisor = SpeechWorkerSupervisor(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "rill-fake", markerURL.path]
      ),
      requestIDGenerator: { speechWorkerTestRequestID }
    )
    let payload = makePayload()
    let task = Task {
      try await supervisor.recognize(payload, timeout: .seconds(30))
    }
    let pid = try await waitForPID(supervisor)
    await waitUntil {
      FileManager.default.fileExists(atPath: markerURL.path)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    let cancellationStartedAt = ContinuousClock.now
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }

    let elapsed = cancellationStartedAt.duration(to: .now)
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))
    XCTAssertLessThan(elapsed, .seconds(2))
    let pidIsGone = await waitUntilPIDIsGone(pid)
    XCTAssertTrue(pidIsGone)
  }

  func testProtocolFailureRetiresDesynchronizedWorkerAndNextRequestUsesNewPID() async throws {
    let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-worker-marker-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let response = makeSuccessResponse(
      requestID: speechWorkerTestRequestID,
      generation: 2
    )
    let script = """
      IFS= read -r request || exit 0
      if [ -e "$1" ]; then
        printf '%s' "$2"
        while IFS= read -r request; do printf '%s' "$2"; done
      else
        : > "$1"
        printf 'not-json\\n'
        while :; do :; done
      fi
      """
    let supervisor = SpeechWorkerSupervisor(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "rill-fake", markerURL.path, response]
      ),
      requestIDGenerator: { speechWorkerTestRequestID }
    )
    let payload = makePayload()
    let firstTask = Task {
      try await supervisor.recognize(payload, timeout: .seconds(2))
    }
    let firstPID = try await waitForPID(supervisor)

    do {
      _ = try await firstTask.value
      XCTFail("Expected a protocol violation")
    } catch {
      XCTAssertEqual(error as? SpeechWorkerClientError, .protocolViolation)
    }
    let firstPIDIsGone = await waitUntilPIDIsGone(firstPID)
    XCTAssertTrue(firstPIDIsGone)

    let secondResult = try await supervisor.recognize(payload, timeout: .seconds(2))
    let activePID = await supervisor.activeProcessIdentifier()
    let secondPID = try XCTUnwrap(activePID)
    XCTAssertNotEqual(secondPID, firstPID)
    XCTAssertEqual(secondResult.bestText, "worker result")
    try await supervisor.shutdown()
  }

  func testStderrIsDrainedWithoutUnboundedRetention() async throws {
    let response = makeSuccessResponse(requestID: speechWorkerTestRequestID, generation: 1)
    let script = """
      i=0
      while [ "$i" -lt 12000 ]; do
        printf 'worker-diagnostic-padding\\n' >&2
        i=$((i + 1))
      done
      while IFS= read -r request; do printf '%s' "$1"; done
      """
    let supervisor = makeSupervisor(script: script, response: response)

    let result = try await supervisor.recognize(makePayload(), timeout: .seconds(3))

    XCTAssertEqual(result.bestText, "worker result")
    await waitUntil {
      await supervisor.retainedStderrByteCount() == 64 * 1_024
    }
    let retainedStderrByteCount = await supervisor.retainedStderrByteCount()
    XCTAssertEqual(retainedStderrByteCount, 64 * 1_024)
    try await supervisor.shutdown()
  }

  func testReleaseLoadedModelHasBoundedTerminationAndReapsPID() async throws {
    let response = makeSuccessResponse(requestID: speechWorkerTestRequestID, generation: 1)
    let script = """
      trap '' TERM
      IFS= read -r request || exit 0
      printf '%s' "$1"
      while :; do :; done
      """
    let supervisor = makeSupervisor(script: script, response: response)
    _ = try await supervisor.recognize(makePayload(), timeout: .seconds(2))
    let activePIDBeforeRelease = await supervisor.activeProcessIdentifier()
    let pid = try XCTUnwrap(activePIDBeforeRelease)
    let startedAt = ContinuousClock.now

    try await supervisor.releaseLoadedModel()

    let elapsed = startedAt.duration(to: .now)
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))
    XCTAssertLessThan(elapsed, .seconds(2))
    let pidIsGone = await waitUntilPIDIsGone(pid)
    let activePIDAfterRelease = await supervisor.activeProcessIdentifier()
    XCTAssertTrue(pidIsGone)
    XCTAssertNil(activePIDAfterRelease)
  }

  func testShutdownJoinsInFlightReleaseAndBlocksReplacementWorker() async throws {
    let response = makeSuccessResponse(requestID: speechWorkerTestRequestID, generation: 1)
    let script = """
      trap '' TERM
      IFS= read -r request || exit 0
      printf '%s' "$1"
      while :; do :; done
      """
    let supervisor = makeSupervisor(script: script, response: response)
    let payload = makePayload()
    _ = try await supervisor.recognize(payload, timeout: .seconds(2))
    let activePIDBeforeRelease = await supervisor.activeProcessIdentifier()
    let pid = try XCTUnwrap(activePIDBeforeRelease)
    let release = Task {
      try await supervisor.releaseLoadedModel()
    }
    try await Task.sleep(for: .milliseconds(25))

    do {
      _ = try await supervisor.recognize(payload, timeout: .seconds(2))
      XCTFail("A replacement worker must not launch during retirement")
    } catch {
      XCTAssertEqual(error as? SpeechWorkerClientError, .workerUnavailable)
    }
    let retiringPID = await supervisor.activeProcessIdentifier()
    XCTAssertEqual(retiringPID, pid)

    try await supervisor.shutdown()
    try await release.value

    let pidIsGone = await waitUntilPIDIsGone(pid)
    let activePID = await supervisor.activeProcessIdentifier()
    XCTAssertTrue(pidIsGone)
    XCTAssertNil(activePID)
  }

  func testShutdownPermanentlySealsSupervisorAgainstRelaunch() async throws {
    let response = makeSuccessResponse(requestID: speechWorkerTestRequestID, generation: 1)
    let supervisor = makeSupervisor(script: persistentResponseScript, response: response)
    let payload = makePayload()
    _ = try await supervisor.recognize(payload, timeout: .seconds(2))
    let activePIDBeforeShutdown = await supervisor.activeProcessIdentifier()
    let originalPID = try XCTUnwrap(activePIDBeforeShutdown)

    try await supervisor.shutdown()

    do {
      _ = try await supervisor.recognize(payload, timeout: .seconds(2))
      XCTFail("A terminally shut down supervisor must not relaunch")
    } catch {
      XCTAssertEqual(error as? SpeechWorkerClientError, .workerUnavailable)
    }
    let originalPIDIsGone = await waitUntilPIDIsGone(originalPID)
    let activePID = await supervisor.activeProcessIdentifier()
    XCTAssertTrue(originalPIDIsGone)
    XCTAssertNil(activePID)
  }

  private var persistentResponseScript: String {
    "while IFS= read -r request; do printf '%s' \"$1\"; done"
  }

  private func makeSupervisor(script: String, response: String) -> SpeechWorkerSupervisor {
    SpeechWorkerSupervisor(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "rill-fake", response]
      ),
      requestIDGenerator: { speechWorkerTestRequestID }
    )
  }

  private func makePayload() -> SpeechWorkerRecognitionPayload {
    SpeechWorkerRecognitionPayload(
      runID: UUID(),
      modelID: SherpaOnnxModelCatalog.defaultModelID.rawValue,
      language: "zh-CN",
      keyterms: ["Rill"],
      threadCount: 2,
      audioFilePath: "/tmp/rill-recognition-supervisor-test.wav",
      audioDurationSeconds: 1,
      audioFormat: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .float32)
    )
  }

  private func makeSuccessResponse(requestID: UUID, generation: UInt64) -> String {
    let request = SpeechWorkerRequest(
      requestID: requestID,
      generation: generation,
      payload: makePayload()
    )
    let response = SpeechWorkerResponse.success(
      request: request,
      result: SpeechWorkerRecognitionResult(
        rawText: "worker result",
        bestText: "worker result",
        metadata: ["provider.kind": "sherpa-onnx"],
        processingDurationMillis: 10
      )
    )
    let data = try! SpeechWorkerProtocolCodec.encodeResponseLine(response)
    return String(data: data, encoding: .utf8)!
  }

  private func makePreparationResponse(requestID: UUID, generation: UInt64) -> String {
    let request = SpeechWorkerRequest(
      requestID: requestID,
      generation: generation,
      modelPreparationPayload: SpeechWorkerModelPreparationPayload(
        modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
        downloadIfNeeded: true
      )
    )
    let response = SpeechWorkerResponse.prepared(
      request: request,
      modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue
    )
    let data = try! SpeechWorkerProtocolCodec.encodeResponseLine(response)
    return String(data: data, encoding: .utf8)!
  }

  private func makePreparationProgressResponse(
    requestID: UUID,
    generation: UInt64
  ) -> String {
    let request = SpeechWorkerRequest(
      requestID: requestID,
      generation: generation,
      modelPreparationPayload: SpeechWorkerModelPreparationPayload(
        modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
        downloadIfNeeded: true
      )
    )
    let response = SpeechWorkerResponse.progress(
      request: request,
      update: SpeechWorkerProgress(
        phase: .downloading,
        completedUnitCount: 25,
        totalUnitCount: 100
      )
    )
    let data = try! SpeechWorkerProtocolCodec.encodeResponseLine(response)
    return String(data: data, encoding: .utf8)!
  }

  private func makeManagedAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-recognition-worker-adapter-\(UUID().uuidString).wav"
    )
    guard FileManager.default.createFile(atPath: url.path, contents: Data([0])) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return url
  }

  private func makeWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      name: "Worker Adapter Test",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "accent")
    )
  }

  private func waitForPID(
    _ supervisor: SpeechWorkerSupervisor,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> pid_t {
    for _ in 0..<200 {
      if let pid = await supervisor.activeProcessIdentifier() {
        return pid
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Worker did not launch", file: file, line: line)
    throw SpeechWorkerClientError.workerUnavailable
  }

  private func waitUntilPIDIsGone(_ pid: pid_t) async -> Bool {
    for _ in 0..<200 {
      if Darwin.kill(pid, 0) != 0, errno == ESRCH {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<200 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

private final class WorkerProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SpeechWorkerProgress] = []

  func record(_ progress: SpeechWorkerProgress) {
    lock.withLock {
      values.append(progress)
    }
  }

  func snapshot() -> [SpeechWorkerProgress] {
    lock.withLock { values }
  }
}
