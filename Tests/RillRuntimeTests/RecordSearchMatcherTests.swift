import XCTest

@testable import RillCore
@testable import RillRuntime

final class RecordSearchMatcherTests: XCTestCase {
  func testApproximationFindsAbbreviationsTyposAndPinyinWithoutDroppingTerms() async throws {
    let content = try await RecordSearchDocument("git worktree add；剪贴板搜索").preparingApproximation()
    let metadata = try await RecordSearchDocument("终端 Terminal").preparingApproximation()
    for query in ["gt wrktr add", "worktere", "jiantieban", "jtb", "jiantieban terminal"] {
      XCTAssertTrue(matcher(query).matches(content, metadata: metadata), query)
    }
    for query in ["worktree absent", "zhong unrelated", "xjiantieban", "jianti"] {
      XCTAssertFalse(matcher(query).matches(content, metadata: metadata), query)
    }
    XCTAssertFalse(
      RecordSearchMatcher(.init(text: "jtb")).matches(content, metadata: metadata))
  }

  func testIdentifiersRetainLiteralSemantics() async throws {
    let content = try await RecordSearchDocument(
      "https://example.com/reference /tmp/report.pdf INV-12345"
    ).preparingApproximation()
    let metadata = RecordSearchDocument("")
    for query in ["https://example.com/reference", "/tmp/report.pdf", "INV-12345"] {
      XCTAssertTrue(matcher(query).matches(content, metadata: metadata), query)
    }
    for query in ["https://example.com/refernce", "/tmp/reprot.pdf", "INV-12354"] {
      XCTAssertFalse(matcher(query).matches(content, metadata: metadata), query)
    }
    for query in ["", "中文", String(repeating: "x", count: 161)] {
      XCTAssertFalse(matcher(query).canApproximate, query)
    }
  }

  func testPinyinMatchesAcrossPreparationChunks() async throws {
    let content = try await RecordSearchDocument(
      String(repeating: "甲", count: 510) + "剪贴板" + String(repeating: "乙", count: 510)
    ).preparingApproximation()
    XCTAssertTrue(matcher("jiantieban").matches(content, metadata: RecordSearchDocument("")))
  }

  func testNumberInsideApproximateQueryMustMatchAWholeToken() async throws {
    let exact = try await RecordSearchDocument("worktree invoice 123").preparingApproximation()
    let other = try await RecordSearchDocument("worktree invoice 1234").preparingApproximation()
    let query = matcher("worktere invoice 123")
    XCTAssertTrue(query.matches(exact, metadata: RecordSearchDocument("")))
    XCTAssertFalse(query.matches(other, metadata: RecordSearchDocument("")))
  }

  func testCancelledPreparationDoesNotProduceADocument() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await RecordSearchDocument("剪贴板").preparingApproximation()
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled preparation must terminate")
    } catch is CancellationError {}
  }

  private func matcher(_ text: String) -> RecordSearchMatcher {
    .init(.init(text: text, matching: .approximate))
  }
}
