import XCTest

@testable import RillUI

final class LocalizationOverlaysTests: XCTestCase {
  func testOverlayTextKeysAreExhaustivelyLocalized() {
    for key in OverlayTextKey.allCases {
      let english = L10n.overlayText(key, language: .english)
      let simplifiedChinese = L10n.overlayText(key, language: .simplifiedChinese)
      XCTAssertNotEqual(english, key.rawValue)
      XCTAssertNotEqual(simplifiedChinese, key.rawValue)
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(simplifiedChinese.isEmpty)
      XCTAssertNotEqual(english, simplifiedChinese)
    }
  }

  func testOverlayTextSpotChecks() {
    XCTAssertEqual(L10n.overlayText(.searchCommand, language: .english), "Search Rill")
    XCTAssertEqual(L10n.overlayText(.searchCommand, language: .simplifiedChinese), "搜索 Rill")
    XCTAssertEqual(
      L10n.overlayText(.searchNoResultsTitle, language: .simplifiedChinese),
      "没有结果"
    )
    XCTAssertEqual(
      L10n.overlayText(.liveSubtitleEscapeHint, language: .english),
      "Press Escape to cancel and discard"
    )
    XCTAssertEqual(
      L10n.overlayText(.correctionSaveToCollection, language: .simplifiedChinese),
      "保存到词库"
    )
    XCTAssertEqual(
      L10n.overlayText(.settingsVoiceAssistantTitle, language: .english),
      "Voice Assistant"
    )
    XCTAssertEqual(
      L10n.liveSubtitleRemaining("0:30", language: .english),
      "0:30 remaining."
    )
    XCTAssertEqual(
      L10n.liveSubtitleRemaining("0:30", language: .simplifiedChinese),
      "剩余 0:30。"
    )
    XCTAssertEqual(
      L10n.liveSubtitleRecorded("1:05", language: .english),
      "Recorded 1:05."
    )
    XCTAssertEqual(
      L10n.liveSubtitleRecorded("1:05", language: .simplifiedChinese),
      "已录制 1:05。"
    )
  }

  func testGlobalSearchTextReuseMatchesExistingCopy() {
    XCTAssertEqual(
      GlobalSearchText.cancel(language: .english),
      L10n.recordText(.cancel, language: .english)
    )
    XCTAssertEqual(
      GlobalSearchText.historyRetry(language: .simplifiedChinese),
      UIStrings.text(.retryGlobalInput, language: .simplifiedChinese)
    )
    XCTAssertEqual(
      GlobalSearchText.genericRun(language: .english),
      L10n.historyTimelineText(.workflowRunFallback, language: .english)
    )
    for status in [
      HistoryTimelineStatus.completed, .partiallyCompleted, .failed, .cancelled, .skipped,
    ] {
      XCTAssertEqual(
        GlobalSearchText.status(status, language: .english),
        L10n.historyRunStatus(status, language: .english)
      )
      XCTAssertEqual(
        GlobalSearchText.status(status, language: .simplifiedChinese),
        L10n.historyRunStatus(status, language: .simplifiedChinese)
      )
    }
    XCTAssertEqual(
      GlobalSearchResultCategory.workflows.title(language: .english),
      UIStrings.text(.sidebarWorkflows, language: .english)
    )
    XCTAssertEqual(
      GlobalSearchResultCategory.settings.title(language: .simplifiedChinese),
      UIStrings.text(.settingsTitle, language: .simplifiedChinese)
    )
  }
}
