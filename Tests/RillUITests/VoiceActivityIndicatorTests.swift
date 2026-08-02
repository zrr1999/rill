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

  func testMeterOpacityFadesMeasuredEnergyWithoutHidingNeutralTicks() {
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: -.infinity), 0.62)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: 0), 0.62)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: 0.5), 0.81, accuracy: 0.001)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: 1), 1)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: .infinity), 0.62)
  }
}
