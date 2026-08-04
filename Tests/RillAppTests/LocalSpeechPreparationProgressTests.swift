import XCTest
@testable import RillApp
@testable import RillProviders

final class LocalSpeechPreparationProgressTests: XCTestCase {
  func testDownloadProgressUsesNinetyPercentOfDisplayedRange() {
    let progress = AppBootstrap.localSpeechPreparationProgress(
      .init(phase: .downloading, completedUnitCount: 1, totalUnitCount: 2)
    )

    XCTAssertEqual(progress.fractionCompleted, 0.45, accuracy: 0.000_001)
  }

  func testCompletedDownloadEntersValidationRange() {
    let progress = AppBootstrap.localSpeechPreparationProgress(
      .init(phase: .downloading, completedUnitCount: 1, totalUnitCount: 1)
    )

    XCTAssertEqual(progress.fractionCompleted, 0.9, accuracy: 0.000_001)
  }

  func testLoadingProgressDoesNotResetToZero() {
    let starting = AppBootstrap.localSpeechPreparationProgress(
      .init(phase: .loading, completedUnitCount: 0, totalUnitCount: 1)
    )
    let completed = AppBootstrap.localSpeechPreparationProgress(
      .init(phase: .loading, completedUnitCount: 1, totalUnitCount: 1)
    )

    XCTAssertEqual(starting.fractionCompleted, 0.95, accuracy: 0.000_001)
    XCTAssertEqual(completed.fractionCompleted, 1, accuracy: 0.000_001)
  }
}
