import XCTest

@testable import RillUI

@MainActor
final class VoiceActivityIndicatorTests: XCTestCase {
  func testUnmeasuredMeterStaysNeutralInsteadOfSynthesizingActivity() {
    XCTAssertEqual(
      VoiceActivityIndicator.displayedLevels([], barCount: 4),
      [0, 0, 0, 0]
    )
  }

  func testMeterPadsRecentMeasuredLevelsAndClampsThem() {
    XCTAssertEqual(
      VoiceActivityIndicator.displayedLevels(
        [-0.5, 0.25, 1.5, .nan, .infinity],
        barCount: 6
      ),
      [0, 0, 0.25, 1, 0, 0]
    )
  }

  func testMeterKeepsOnlyTheRequestedRecentWindow() {
    XCTAssertEqual(
      VoiceActivityIndicator.displayedLevels(
        [0.1, 0.2, 0.3],
        barCount: 2
      ),
      [0.2, 0.3]
    )
    XCTAssertEqual(
      VoiceActivityIndicator.displayedLevels([0.5], barCount: 0),
      []
    )
  }

  func testInactiveMeterNeutralizesPreviouslyMeasuredLevels() {
    XCTAssertEqual(
      VoiceActivityIndicator.displayedLevels(
        [0.25, 0.75],
        barCount: 4,
        isActive: false
      ),
      [0, 0, 0, 0]
    )
  }

  func testReduceMotionDisablesMeterAnimation() {
    XCTAssertNil(VoiceActivityIndicator.meterAnimation(reduceMotion: true))
    XCTAssertNotNil(VoiceActivityIndicator.meterAnimation(reduceMotion: false))
  }
}
