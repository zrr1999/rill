import XCTest

@testable import RillMLXRuntime

final class SpeechWorkerMLXCachePolicyTests: XCTestCase {
  func testCacheLimitPolicyUsesBoundedWorkerConfiguration() {
    let key = SpeechWorkerMLXCachePolicy.environmentKey
    XCTAssertEqual(
      SpeechWorkerMLXCachePolicy.resolvedLimit(environment: [:]),
      256 * 1_024 * 1_024
    )
    XCTAssertEqual(
      SpeechWorkerMLXCachePolicy.resolvedLimit(environment: [key: "-1"]),
      256 * 1_024 * 1_024
    )
    XCTAssertEqual(
      SpeechWorkerMLXCachePolicy.resolvedLimit(environment: [key: "9223372036854775808"]),
      256 * 1_024 * 1_024
    )
    XCTAssertEqual(
      SpeechWorkerMLXCachePolicy.resolvedLimit(environment: [key: "67108864"]),
      64 * 1_024 * 1_024
    )
    XCTAssertEqual(
      SpeechWorkerMLXCachePolicy.resolvedLimit(environment: [key: "2147483648"]),
      1_024 * 1_024 * 1_024
    )
  }
}
