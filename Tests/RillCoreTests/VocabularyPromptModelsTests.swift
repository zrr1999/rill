import XCTest
@testable import RillCore

final class VocabularyPromptModelsTests: XCTestCase {
  func testExactPhraseMappingReplacesCaseInsensitiveMatches() {
    let rule = VocabularyRule(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      pattern: "Web coding",
      replacement: "Vibe Coding"
    )

    let result = VocabularyRuleApplicator.apply(
      text: "web coding should become Web coding.",
      rules: [rule]
    )

    XCTAssertEqual(result.text, "Vibe Coding should become Vibe Coding.")
    XCTAssertEqual(result.applications.map(\.ruleID), [rule.id])
    XCTAssertEqual(result.applications.first?.matchCount, 2)
    XCTAssertTrue(result.changed)
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testCaseSensitiveMappingPreservesMismatchedCase() {
    let rule = VocabularyRule(
      pattern: "api",
      replacement: "API",
      caseSensitive: true
    )

    let result = VocabularyRuleApplicator.apply(text: "api Api API", rules: [rule])

    XCTAssertEqual(result.text, "API Api API")
    XCTAssertEqual(result.applications.first?.matchCount, 1)
  }

  func testWordBoundaryMappingDoesNotReplaceInsideWords() {
    let rule = VocabularyRule(
      pattern: "cat",
      replacement: "dog",
      matchMode: .wordBoundary
    )

    let result = VocabularyRuleApplicator.apply(text: "cat scatter cat", rules: [rule])

    XCTAssertEqual(result.text, "dog scatter dog")
    XCTAssertEqual(result.applications.first?.matchCount, 2)
  }

  func testScopeFiltersRulesByBundleAndGroup() {
    let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let matchingRule = VocabularyRule(
      pattern: "voice group",
      replacement: "语音识别组",
      scope: VocabularyRuleScope(
        bundleIdentifier: "com.apple.Notes",
        recordCollectionID: groupID,
        locale: "zh-CN"
      )
    )
    let nonMatchingRule = VocabularyRule(
      pattern: "Notes",
      replacement: "Mail",
      scope: VocabularyRuleScope(bundleIdentifier: "com.apple.mail")
    )

    let result = VocabularyRuleApplicator.apply(
      text: "voice group in Notes",
      rules: [matchingRule, nonMatchingRule],
      context: VocabularyRuleContext(
        bundleIdentifier: "com.apple.Notes",
        recordCollectionID: groupID,
        locale: "zh-CN"
      )
    )

    XCTAssertEqual(result.text, "语音识别组 in Notes")
    XCTAssertEqual(result.applications.map(\.ruleID), [matchingRule.id])
  }

  func testPriorityRunsHigherRulesFirst() {
    let lowPriority = VocabularyRule(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
      pattern: "alpha",
      replacement: "beta",
      priority: 0
    )
    let highPriority = VocabularyRule(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
      pattern: "alpha",
      replacement: "gamma",
      priority: 10
    )

    let result = VocabularyRuleApplicator.apply(
      text: "alpha",
      rules: [lowPriority, highPriority]
    )

    XCTAssertEqual(result.text, "gamma")
    XCTAssertEqual(result.applications.map(\.ruleID), [highPriority.id])
  }

  func testInvalidRegexProducesIssueAndLeavesTextUnchanged() {
    let rule = VocabularyRule(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      pattern: "[",
      replacement: "broken",
      matchMode: .regex
    )

    let result = VocabularyRuleApplicator.apply(text: "keep this", rules: [rule])

    XCTAssertEqual(result.text, "keep this")
    XCTAssertEqual(result.issues.map(\.kind), [.invalidRegex])
    XCTAssertFalse(result.changed)
  }
}
