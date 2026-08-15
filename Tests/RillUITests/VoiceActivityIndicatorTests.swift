import Combine
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
    XCTAssertEqual(VoiceActivityIndicator.meterTargetInterval, 0.04, accuracy: 0.001)
    XCTAssertEqual(VoiceActivityIndicator.meterAnimationDuration, 0.08, accuracy: 0.001)
    XCTAssertGreaterThan(
      VoiceActivityIndicator.meterAnimationDuration,
      VoiceActivityIndicator.meterTargetInterval
    )
  }

  func testMeterWidthMatchesBarGeometry() {
    XCTAssertEqual(
      VoiceActivityIndicator.meterWidth(barCount: 12, barWidth: 2, barSpacing: 2),
      46
    )
    XCTAssertEqual(
      VoiceActivityIndicator.meterWidth(barCount: 0, barWidth: 2, barSpacing: 2),
      0
    )
  }

  func testMeterModelPublishesOnlyChangedTargets() {
    let model = VoiceActivityMeterModel(levels: [0.2])
    var publicationCount = 0
    let observation = model.objectWillChange.sink {
      publicationCount += 1
    }

    model.update(levels: [0.2])
    XCTAssertEqual(publicationCount, 0)

    model.update(levels: [0.8])
    XCTAssertEqual(publicationCount, 1)
    XCTAssertEqual(model.levels, [0.8])
    withExtendedLifetime(observation) {}
  }

  func testMeterOpacityFadesMeasuredEnergyWithoutHidingNeutralTicks() {
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: -.infinity), 0.62)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: 0), 0.62)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: 0.5), 0.81, accuracy: 0.001)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: 1), 1)
    XCTAssertEqual(VoiceActivityIndicator.barOpacity(for: .infinity), 0.62)
  }
}
