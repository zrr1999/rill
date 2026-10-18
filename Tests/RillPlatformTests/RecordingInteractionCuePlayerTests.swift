import RillCore
import Testing
@testable import RillPlatform
import XCTest

final class RecordingInteractionCuePlayerTests: XCTestCase {
  func testInteractionCuesAreShortDistinctNonSilentTones() {
    let started = RecordingInteractionCueToneRenderer.samples(for: .started)
    let stopped = RecordingInteractionCueToneRenderer.samples(for: .stopped)

    XCTAssertFalse(started.isEmpty)
    XCTAssertFalse(stopped.isEmpty)
    XCTAssertNotEqual(started, stopped)
    XCTAssertLessThan(Double(started.count) / RecordingInteractionCueToneRenderer.sampleRate, 0.1)
    XCTAssertLessThan(Double(stopped.count) / RecordingInteractionCueToneRenderer.sampleRate, 0.1)
    XCTAssertTrue(started.contains { abs($0) > 0.001 })
    XCTAssertTrue(stopped.contains { abs($0) > 0.001 })
    XCTAssertEqual(started.first ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(stopped.first ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(started.last ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(stopped.last ?? 1, 0, accuracy: 0.000_001)
  }
}

struct RecordingCuePlaybackTests {
  @Test func cancellingPlaybackWaitDoesNotRequireAnAudioCallback() async {
    let playback = RecordingCuePlayback()
    let task = Task { await playback.wait() }
    task.cancel()
    await task.value
    playback.finish()
  }

  @Test func playbackCompletionReleasesAllWaitersAndAllowsLateWaiters() async {
    let playback = RecordingCuePlayback()
    async let first: Void = playback.wait()
    async let second: Void = playback.wait()
    playback.finish()
    await first
    await second
    await playback.wait()
    playback.finish()
  }
}
