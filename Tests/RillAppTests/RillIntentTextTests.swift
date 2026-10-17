@testable import RillApp
import XCTest

final class RillIntentTextTests: XCTestCase {
  func testLastTranscriptionRejectsBlankText() {
    XCTAssertNil(RillIntentText.lastTranscription(in: nil))
    XCTAssertNil(RillIntentText.lastTranscription(in: " \n"))
    XCTAssertEqual(RillIntentText.lastTranscription(in: " hello "), "hello")
  }
}
