import XCTest
@testable import RillPlatform

final class WakeWordAudioConditionerTests: XCTestCase {
  func testWakeWordAudioConditionerAppliesGainWithinAvailableHeadroom() {
    let quiet = WakeWordAudioConditioner.prepare([
      -0.1, 0, 0.1, .infinity,
    ])
    XCTAssertEqual(quiet[0], -0.316_227_76, accuracy: 0.000_001)
    XCTAssertEqual(quiet[1], 0)
    XCTAssertEqual(quiet[2], 0.316_227_76, accuracy: 0.000_001)
    XCTAssertEqual(quiet[3], 0)

    let moderate = WakeWordAudioConditioner.prepare([-0.5, 0.5])
    XCTAssertEqual(moderate[0], -0.95, accuracy: 0.000_001)
    XCTAssertEqual(moderate[1], 0.95, accuracy: 0.000_001)

    XCTAssertEqual(WakeWordAudioConditioner.prepare([-0.98, 0.98]), [-0.98, 0.98])
  }
}
