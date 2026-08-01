import RillCore
@testable import RillPlatform
import XCTest

final class RecordingInteractionCuePlayerTests: XCTestCase {
  func testInteractionCuesAreShortDistinctNonSilentTones() {
    let started = RecordingInteractionCueToneRenderer.samples(for: .started)
    let stopped = RecordingInteractionCueToneRenderer.samples(for: .stopped)
    let wakeDetected = RecordingInteractionCueToneRenderer.samples(for: .wakeDetected)

    XCTAssertFalse(started.isEmpty)
    XCTAssertFalse(stopped.isEmpty)
    XCTAssertFalse(wakeDetected.isEmpty)
    XCTAssertNotEqual(started, stopped)
    XCTAssertNotEqual(started, wakeDetected)
    XCTAssertNotEqual(stopped, wakeDetected)
    XCTAssertLessThan(Double(started.count) / RecordingInteractionCueToneRenderer.sampleRate, 0.1)
    XCTAssertLessThan(Double(stopped.count) / RecordingInteractionCueToneRenderer.sampleRate, 0.1)
    XCTAssertLessThan(
      Double(wakeDetected.count) / RecordingInteractionCueToneRenderer.sampleRate,
      0.2
    )
    XCTAssertTrue(started.contains { abs($0) > 0.001 })
    XCTAssertTrue(stopped.contains { abs($0) > 0.001 })
    XCTAssertTrue(wakeDetected.contains { abs($0) > 0.001 })
    XCTAssertEqual(started.first ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(stopped.first ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(wakeDetected.first ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(started.last ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(stopped.last ?? 1, 0, accuracy: 0.000_001)
    XCTAssertEqual(wakeDetected.last ?? 1, 0, accuracy: 0.000_001)
  }
}
