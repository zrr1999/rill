import XCTest
@testable import RillUI

final class LocalSpeechPreparationPresentationTests: XCTestCase {
  func testPreparationStagesUseSeparateValidationAndLoadingRanges() {
    XCTAssertEqual(
      LocalSpeechPreparationPresentation.stage(displayedProgress: 0.45),
      .downloading(fractionCompleted: 0.5)
    )
    XCTAssertEqual(
      LocalSpeechPreparationPresentation.stage(displayedProgress: 0.9),
      .validating
    )
    XCTAssertEqual(
      LocalSpeechPreparationPresentation.stage(displayedProgress: 0.95),
      .loading
    )
  }

  func testDisplayedDownloadProgressClampsMalformedValues() {
    XCTAssertEqual(
      LocalSpeechPreparationPresentation.stage(displayedProgress: -1),
      .downloading(fractionCompleted: 0)
    )
    XCTAssertEqual(
      LocalSpeechPreparationPresentation.stage(displayedProgress: 2),
      .loading
    )
  }

  func testOnlyDownloadStageExposesDeterminateProgress() {
    XCTAssertEqual(
      LocalSpeechPreparationPresentation.Stage.downloading(
        fractionCompleted: 0.5
      ).downloadFraction,
      0.5
    )
    XCTAssertNil(LocalSpeechPreparationPresentation.Stage.validating.downloadFraction)
    XCTAssertNil(LocalSpeechPreparationPresentation.Stage.loading.downloadFraction)
  }
}
