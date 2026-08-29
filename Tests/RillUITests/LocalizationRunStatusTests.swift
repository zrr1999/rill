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
      L10n.runText(.benchmarkClearFailed, language: .english),
      "Encrypted benchmark recordings could not be cleared."
    )
  }

  func testRunStatusFormatVariants() {
    XCTAssertEqual(
      String(
        format: L10n.runText(.workflowSavedFormat, language: .english),
        "Demo"
      ),
      "Workflow saved: Demo"
    )
    XCTAssertEqual(
      String(
        format: L10n.runText(.workflowSavedFormat, language: .simplifiedChinese),
        "Demo"
      ),
      "工作流已保存：Demo"
    )
    XCTAssertEqual(
      String(
        format: L10n.runText(.runActionSkippedFormat, language: .simplifiedChinese),
        "busy"
      ),
      "已跳过（busy）"
    )
    XCTAssertEqual(
      String(
        format: L10n.runText(.localHistoryUpdatedFormat, language: .english),
        3,
        1
      ),
      "Local history updated: removed 3, preserved 1 active clipboard item(s)."
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

  func testRunStatusRetentionHelpers() {
    XCTAssertEqual(
      L10n.runHistoryRetentionReadFailed(isRecordSetting: true, language: .english),
      "A stored clipboard history retention setting could not be read; cleanup for that domain is paused."
    )
    XCTAssertEqual(
      L10n.runHistoryRetentionReadFailed(isRecordSetting: false, language: .simplifiedChinese),
      "无法读取已保存的运行与诊断历史留存设置；该域清理已暂停。"
    )
    XCTAssertEqual(
      L10n.runHistoryRetentionInvalid(isRecordSetting: true, language: .simplifiedChinese),
      "剪贴板历史留存设置无效；该域清理已暂停。"
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
