import XCTest
@testable import RillMLXRuntime

final class RecognitionPromptBudgetTests: XCTestCase {
  func testBudgetCountsCompletePromptAndNeverTruncatesATerm() {
    let result = RecognitionPromptBudget.resolve(
      keyterms: ["enormous", "Rill", "MLX"], maximumTokens: 20,
      countTokens: { $0.contains("enormous") ? 50 : $0.count })
    XCTAssertEqual(result.context, "Keywords: Rill, MLX.")
    XCTAssertEqual(result.tokenCount, 20)
    XCTAssertEqual(result.includedCount, 2)
    XCTAssertEqual(result.omittedCount, 1)
  }

  func testNoTermFitsProducesNoPromptAndReportsOmissions() {
    let result = RecognitionPromptBudget.resolve(
      keyterms: ["Rill", "Rill", "invalid,term"], maximumTokens: 0,
      countTokens: { $0.count })
    XCTAssertEqual(result.context, "")
    XCTAssertEqual(result.tokenCount, 0)
    XCTAssertEqual(result.omittedCount, 3)
  }
}
