import XCTest

@testable import RillCore

final class WakePhraseMatcherTests: XCTestCase {
  func testMatchesEnglishPhraseAndReturnsCommand() {
    XCTAssertEqual(
      WakePhraseMatcher.match(
        transcript: "Hey, Rill，打开客厅的灯",
        phrases: ["Hey Rill"]
      ),
      WakePhraseMatch(
        phrase: "Hey Rill",
        command: "打开客厅的灯"
      )
    )
  }

  func testMatchesMixedChineseEnglishPhrase() {
    XCTAssertEqual(
      WakePhraseMatcher.match(
        transcript: "你好 RILL：what time is it?",
        phrases: ["你好 Rill"]
      ),
      WakePhraseMatch(
        phrase: "你好 Rill",
        command: "what time is it?"
      )
    )
  }

  func testPhraseOnlyReturnsNoCommand() {
    XCTAssertEqual(
      WakePhraseMatcher.match(
        transcript: "  Hey Rill！ ",
        phrases: ["Hey Rill"]
      ),
      WakePhraseMatch(phrase: "Hey Rill", command: nil)
    )
  }

  func testRejectsLongerLatinWord() {
    XCTAssertNil(
      WakePhraseMatcher.match(
        transcript: "Hey Riller, turn on the light",
        phrases: ["Hey Rill"]
      )
    )
  }

  func testRejectsPhraseAwayFromTranscriptStart() {
    XCTAssertNil(
      WakePhraseMatcher.match(
        transcript: "I said Hey Rill, turn on the light",
        phrases: ["Hey Rill"]
      )
    )
  }

  func testConfiguredPhraseOrderIsStable() {
    XCTAssertEqual(
      WakePhraseMatcher.match(
        transcript: "你好 Rill",
        phrases: ["Hey Rill", "你好 Rill"]
      )?.phrase,
      "你好 Rill"
    )
  }
}
