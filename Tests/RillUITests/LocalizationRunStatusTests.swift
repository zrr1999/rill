import XCTest

@testable import RillUI

final class LocalizationRunStatusTests: XCTestCase {
  func testRunStatusTextKeysAreExhaustivelyLocalized() {
    for key in RunStatusTextKey.allCases {
      let english = L10n.runText(key, language: .english)
      let simplifiedChinese = L10n.runText(key, language: .simplifiedChinese)
      XCTAssertNotEqual(english, key.rawValue)
      XCTAssertNotEqual(simplifiedChinese, key.rawValue)
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(simplifiedChinese.isEmpty)
      XCTAssertNotEqual(english, simplifiedChinese)
      XCTAssertFalse(containsHan(english), english)
    }
  }

  func testRunStatusTextSpotChecks() {
    XCTAssertEqual(
      L10n.runText(.workflowLibraryLoading, language: .english),
      "Workflows are still loading. Wait a moment and try again."
    )
    XCTAssertEqual(
      L10n.runText(.workflowLibraryUnavailable, language: .simplifiedChinese),
      "已保存的工作流库不可用。请修复存储后重试。"
    )
    XCTAssertEqual(
      L10n.runText(.runActionInjected, language: .english),
      "injected"
    )
    XCTAssertEqual(
      L10n.runText(.runActionCopiedToClipboard, language: .simplifiedChinese),
      "已复制到剪贴板"
    )
    XCTAssertEqual(
      L10n.runText(.wakeDictationDraftName, language: .simplifiedChinese),
      "唤醒听写"
    )
    XCTAssertEqual(
      L10n.runText(.corpusClearFailed, language: .english),
      "Encrypted corpus recordings could not be cleared."
    )
  }

  func testRunStatusFormatVariants() {
    XCTAssertEqual(
      String(
        format: L10n.runText(.runActionSkippedFormat, language: .simplifiedChinese),
        "busy"
      ),
      "已跳过（busy）"
    )
    XCTAssertEqual(
      String(
        format: L10n.runText(.localSpeechHardwareRecommendedFormat, language: .simplifiedChinese),
        16,
        "profile"
      ),
      "推荐用于本机（16 GB 内存）· profile"
    )
  }

  func testRunStatusWakeWordSaveFailureKeepsEnglishDetail() {
    XCTAssertEqual(
      L10n.runWakeWordWorkflowSaveFailed(detail: "boom", language: .english),
      "boom"
    )
    XCTAssertEqual(
      L10n.runWakeWordWorkflowSaveFailed(detail: "boom", language: .simplifiedChinese),
      "无法保存唤醒词工作流：boom"
    )
    XCTAssertEqual(
      L10n.runWakeWordSettingsSaveFailed(detail: "boom", language: .simplifiedChinese),
      "无法保存唤醒词设置：boom"
    )
  }
}
