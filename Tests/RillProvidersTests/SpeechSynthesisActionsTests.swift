import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class SpeechSynthesisActionsTests: XCTestCase {
  func testAutomaticFallsBackOnlyWhenPreferredSynthesisFails() async throws {
    let fallbackAsset = try makeAsset()
    defer { try? FileManager.default.removeItem(at: fallbackAsset.fileURL) }
    let preferred = StubSynthesizer(
      id: "preferred",
      outcome: .failure(TestError.failed)
    )
    let fallback = StubSynthesizer(
      id: "system",
      outcome: .success(fallbackAsset)
    )
    let synthesizer = AutomaticSpeechSynthesizer(
      preferred: preferred,
      fallback: fallback
    )

    let asset = try await synthesizer.synthesize(
      SpeechSynthesisRequest(runID: UUID(), text: "hello")
    )

    XCTAssertEqual(asset, fallbackAsset)
    let preferredRequestCount = await preferred.requestCount()
    let fallbackRequestCount = await fallback.requestCount()
    XCTAssertEqual(preferredRequestCount, 1)
    XCTAssertEqual(fallbackRequestCount, 1)
  }

  func testSpeakActionOwnsPlaybackStateAndRemovesManagedAsset() async throws {
    let asset = try makeAsset()
    let synthesizer = StubSynthesizer(
      id: "qwen",
      outcome: .success(asset)
    )
    let playback = StubPlayback()
    let states = StateRecorder()
    let action = SpeakTextAction(
      synthesizer: synthesizer,
      playback: playback,
      playbackStateChanged: { isPlaying in
        await states.append(isPlaying)
      }
    )

    let result = try await action.execute(
      text: "你好 Rill",
      context: makeContext(voice: .ryan)
    )

    XCTAssertEqual(result, .externalOutput("Speech"))
    let recordedStates = await states.values()
    let playbackCount = await playback.playCount()
    let lastRequest = await synthesizer.lastRequest()
    XCTAssertEqual(recordedStates, [true, false])
    XCTAssertEqual(playbackCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: asset.fileURL.path))
    XCTAssertEqual(
      lastRequest?.voice,
      Qwen3TTSVoice.ryan.rawValue
    )
  }

  func testPlaybackFailureDoesNotResynthesizeAndStillCleansAsset() async throws {
    let asset = try makeAsset()
    let synthesizer = StubSynthesizer(
      id: "automatic",
      outcome: .success(asset)
    )
    let playback = StubPlayback(failure: TestError.failed)
    let action = SpeakTextAction(synthesizer: synthesizer, playback: playback)

    let result = try await action.execute(
      text: "hello",
      context: makeContext(voice: .vivian)
    )

    XCTAssertEqual(
      result,
      .failed(SpeechSynthesisActionError.playbackFailed.localizedDescription)
    )
    let synthesisRequestCount = await synthesizer.requestCount()
    XCTAssertEqual(synthesisRequestCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: asset.fileURL.path))
  }

  private func makeAsset() throws -> SpeechAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-speech-\(UUID().uuidString.lowercased()).wav"
    )
    try Data([0, 1, 2, 3]).write(to: url)
    return try SpeechAsset(
      fileURL: url,
      durationSeconds: 0.25,
      format: AudioFormat(
        sampleRateHz: 24_000,
        channelCount: 1,
        encoding: .float32
      ),
      ownership: .managedTemporary
    )
  }

  private func makeContext(voice: Qwen3TTSVoice) -> ActionContext {
    let workflow = WorkflowDefinition(
      name: "Speak",
      pipeline: PipelineDeclaration(
        recognizerID: "test",
        outputActions: [
          OutputActionReference(
            id: SpeechOutputActionID.speak,
            configuration: [
              SpeechOutputActionConfigurationKey.provider:
                SpeechSynthesisProvider.automatic.rawValue,
              SpeechOutputActionConfigurationKey.voice: voice.rawValue,
            ]
          )
        ]
      ),
      ui: WorkflowUIConfig(symbolName: "speaker.wave.2", accentColorName: "blue")
    )
    return ActionContext(
      runID: UUID(),
      workflow: workflow,
      contextSnapshot: .empty,
      recognitionResult: RecognitionResult(rawText: "hello", bestText: "hello"),
      finalText: "hello",
      startedAt: Date(timeIntervalSince1970: 1),
      finishedAt: Date(timeIntervalSince1970: 2)
    )
  }
}

private enum TestError: Error {
  case failed
}

private actor StubSynthesizer: SpeechSynthesizer {
  enum Outcome: Sendable {
    case success(SpeechAsset)
    case failure(any Error & Sendable)
  }

  nonisolated let id: String
  private let outcome: Outcome
  private var requests: [SpeechSynthesisRequest] = []

  init(id: String, outcome: Outcome) {
    self.id = id
    self.outcome = outcome
  }

  func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAsset {
    requests.append(request)
    switch outcome {
    case .success(let asset):
      return asset
    case .failure(let error):
      throw error
    }
  }

  func requestCount() -> Int {
    requests.count
  }

  func lastRequest() -> SpeechSynthesisRequest? {
    requests.last
  }
}

private actor StubPlayback: SpeechPlaybackService {
  private let failure: (any Error & Sendable)?
  private var count = 0

  init(failure: (any Error & Sendable)? = nil) {
    self.failure = failure
  }

  func play(_: SpeechAsset, runID _: UUID) async throws {
    count += 1
    if let failure {
      throw failure
    }
  }

  func stop(runID _: UUID) async {}
  func shutdown() async {}

  func playCount() -> Int {
    count
  }
}

private actor StateRecorder {
  private var recorded: [Bool] = []

  func append(_ value: Bool) {
    recorded.append(value)
  }

  func values() -> [Bool] {
    recorded
  }
}
