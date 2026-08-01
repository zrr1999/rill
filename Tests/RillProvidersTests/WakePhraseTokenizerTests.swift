import XCTest

@testable import RillCore
@testable import RillProviders

final class WakePhraseTokenizerTests: XCTestCase {
  private let tokenizer = WakePhraseTokenizer(
    tokensText: """
      HH 0
      EY1 1
      R 2
      IH1 3
      L 4
      IY1 5
      n 6
      ǐ 7
      h 8
      ǎo 9
      """,
    englishLexiconText: """
      HEY HH EY1
      RILL R IH1 L
      """
  )

  func testEncodesEnglishAndMixedMandarinUsingModelTokens() throws {
    XCTAssertEqual(
      try tokenizer.encode("Hey Rill").tokens,
      ["HH", "EY1", "R", "IH1", "L"]
    )
    XCTAssertEqual(
      try tokenizer.encode("你好 Rill").tokens,
      ["n", "ǐ", "h", "ǎo", "R", "IH1", "L"]
    )
  }

  func testKeywordDefinitionCarriesReviewedShortPhraseTuning() throws {
    XCTAssertEqual(
      try tokenizer.encode("Hey Rill").keywordDefinition,
      "HH EY1 R IH1 L :1.5 #0.12 @Hey_Rill"
    )
  }

  func testDefaultPhraseIncludesReviewedMandarinAccentedPronunciation() throws {
    XCTAssertEqual(
      try tokenizer.encode(
        WakeWordConfiguration(phrases: ["Hey Rill"])
      ).map(\.tokens),
      [
        ["HH", "EY1", "R", "IH1", "L"],
        ["HH", "IY1", "R", "IY1", "L"],
      ]
    )
  }

  func testRejectsEnglishOOVWithoutApproximation() {
    XCTAssertThrowsError(try tokenizer.encode("Hello Rill")) { error in
      XCTAssertEqual(
        error as? WakePhraseTokenizerError,
        .unknownEnglishWord("Hello")
      )
    }
  }

  func testRejectsMandarinPronunciationMissingFromVocabulary() {
    XCTAssertThrowsError(try tokenizer.encode("你好 龘")) { error in
      guard case .unsupportedPinyin = error as? WakePhraseTokenizerError else {
        return XCTFail("Expected an explicit unsupported-pinyin error")
      }
    }
  }

  func testRejectsDuplicateConfigurationBeforeEncoding() {
    XCTAssertThrowsError(
      try tokenizer.encode(
        WakeWordConfiguration(phrases: ["Hey Rill", "hey rill"])
      )
    ) { error in
      XCTAssertEqual(
        error as? WakeWordConfiguration.ValidationError,
        .duplicatePhrase
      )
    }
  }

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
