import Foundation
import RillCore
import RillSpeechContracts
import XCTest
@testable import RillProviders

final class QwenStreamingTextTests: XCTestCase {
  func testWorkerEventsProduceOnlyUserTextAndFlushTheFinalPartialFrame() async throws {
    let events = AsyncThrowingStream<SpeechWorkerStreamEvent, Error>.makeStream()
    let observed = AsyncStream<UInt64>.makeStream()
    var observations = observed.stream.makeAsyncIterator()
    let frames = PreviewFrameRecorder()
    let worker = SpeechWorkerStreamingSession(
      id: UUID(), requestID: UUID(), generation: 1, events: events.stream,
      writeFrame: { frame in
        frames.record(frame)
        if case .command(.finish) = frame.body {
          events.continuation.yield(.completed(previewText: "language English<asr_text>Keep the original text.<|im_end|>"))
          events.continuation.finish()
        }
      }
    )
    let preview = SpeechWorkerStreamingPreviewSession(
      workerSession: worker, modelID: "test", keytermStatus: .unsupported,
      measuredPeakObserver: { _, sequence in observed.continuation.yield(sequence) }
    )
    // Stats acknowledges all preceding events without sleeping or polling the reader task.
    func update(confirmed: String, provisional: String, sequence: UInt64) {
      events.continuation.yield(.transcriptUpdate(.init(confirmed: confirmed, provisional: provisional)))
      events.continuation.yield(.stats(.init(encodedWindowCount: 1, totalAudioSeconds: 0,
        tokensPerSecond: 0, realTimeFactor: 0, peakMemoryBytes: sequence)))
    }
    update(confirmed: "language English<asr_text>", provisional: "", sequence: 1)
    let first = await observations.next()
    XCTAssertEqual(first, 1)
    XCTAssertFalse(preview.hasConfirmedText)
    XCTAssertEqual(try preview.accept(samples: [0, 0, 0]), "")

    update(confirmed: "language English<asr_text>", provisional: "Keep", sequence: 2)
    let second = await observations.next()
    XCTAssertEqual(second, 2)
    XCTAssertFalse(preview.hasConfirmedText)
    XCTAssertEqual(try preview.accept(samples: []), "Keep")

    update(confirmed: "language English<asr_text>Keep the", provisional: "original text.", sequence: 3)
    let third = await observations.next()
    XCTAssertEqual(third, 3)
    XCTAssertTrue(preview.hasConfirmedText)
    XCTAssertEqual(try preview.accept(samples: []), "Keep the original text.")
    let finalText = try await preview.finish()
    XCTAssertEqual(finalText, "Keep the original text.")
    XCTAssertEqual(preview.keytermStatus, .unsupported)
    let sent = frames.snapshot()
    XCTAssertEqual(sent.count, 2)
    guard case .command(.appendAudio(let chunk)) = sent.first?.body else {
      return XCTFail("The final partial frame must precede finish.")
    }
    XCTAssertEqual(try chunk.decodedSamples(), [0, 0, 0])
    guard case .command(.finish) = sent.last?.body else {
      return XCTFail("Expected one terminal finish command.")
    }
  }

  func testProtocolOnlyConfirmationIsNotStableTranscriptText() {
    for text in ["language", "language Ch", "language Chinese<", "language Chinese<asr_text", "language None", "language None<asr_text>", "<|im_end|>"] {
      XCTAssertEqual(QwenStreamingText.sanitize(text), "", text)
    }
  }

  func testWindowRestartMarkersDoNotEnterTheCaptureContract() {
    for text in [
      "language None<asr_text>我是一只猪。",
      "language None<asr_text>我是一只猪。 language None<asr_text>",
      "language None<asr_text>我是一只猪。<|im_end|> language Chinese",
    ] {
      XCTAssertEqual(QwenStreamingText.sanitize(text), "我是一只猪。")
    }
    XCTAssertEqual(QwenStreamingText.sanitize("Keep the original text."), "Keep the original text.")
  }
}

private final class PreviewFrameRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var frames: [SpeechWorkerFrame] = []
  func record(_ frame: SpeechWorkerFrame) { lock.withLock { frames.append(frame) } }
  func snapshot() -> [SpeechWorkerFrame] { lock.withLock { frames } }
}

@testable import RillSpeech
