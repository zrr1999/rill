import XCTest

@testable import RillCore

final class SpeechRecognitionOptionsTests: XCTestCase {
  func testEffectiveMaximumAudioDurationUsesNarrowestValidLimit() {
    XCTAssertEqual(
      SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
        modeMaximumAudioDurationSeconds: 120,
        recognizerMaximumAudioDurationSeconds: nil
      ),
      120
    )
    XCTAssertEqual(
      SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
        modeMaximumAudioDurationSeconds: 1_800,
        recognizerMaximumAudioDurationSeconds: nil
      ),
      1_800
    )
    XCTAssertEqual(
      SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
        modeMaximumAudioDurationSeconds: 1_800,
        recognizerMaximumAudioDurationSeconds: 20
      ),
      20
    )
    XCTAssertEqual(
      SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
        modeMaximumAudioDurationSeconds: 10,
        recognizerMaximumAudioDurationSeconds: 20
      ),
      10
    )
  }

  func testEffectiveMaximumAudioDurationFailsClosedForInvalidLimits() {
    for invalidLimit in [0, -1, .infinity, .nan] {
      XCTAssertEqual(
        SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
          modeMaximumAudioDurationSeconds: 120,
          recognizerMaximumAudioDurationSeconds: invalidLimit
        ),
        0
      )
    }
    XCTAssertEqual(
      SpeechRecognizerCapabilities.effectiveMaximumAudioDurationSeconds(
        modeMaximumAudioDurationSeconds: .nan,
        recognizerMaximumAudioDurationSeconds: nil
      ),
      0
    )
  }
}
