import XCTest

@testable import RillUI

final class L10nTests: XCTestCase {
  func testMenuStringsUseUnifiedLookup() throws {
    XCTAssertEqual(
      L10n.string(.menuOpenMainWindow, language: .english),
      "Open Rill Main Window"
    )
    XCTAssertEqual(
      L10n.string(.menuOpenMainWindow, language: .simplifiedChinese),
      "打开 Rill 主窗口"
    )
    XCTAssertEqual(
      L10n.string(.menuCopyLastResult, language: .simplifiedChinese),
      "复制上次转写结果"
    )
    let longRecordingKey = try XCTUnwrap(L10n.Key(rawValue: "menuLongRecording"))
    let longRecordingToggleKey = try XCTUnwrap(L10n.Key(rawValue: "menuLongRecordingToggle"))
    let textStylesKey = try XCTUnwrap(L10n.Key(rawValue: "menuTextStyles"))
    XCTAssertEqual(L10n.string(longRecordingKey, language: .english), "Toggle Recording")
    XCTAssertEqual(
      L10n.string(longRecordingToggleKey, language: .english), "Press Once to Start/Stop")
    XCTAssertTrue(
      L10n.string(.settingsLongRecordingModeDescription, language: .english)
        .contains("20 seconds")
    )
    XCTAssertTrue(
      L10n.string(.settingsLongRecordingModeDescription, language: .simplifiedChinese)
        .contains("20 秒")
    )
    XCTAssertEqual(L10n.string(textStylesKey, language: .simplifiedChinese), "文字风格")
  }

  func testClipboardSectionStringsUseUnifiedLookup() {
    XCTAssertEqual(
      L10n.string(.clipboardCurrentTitle, language: .english),
      "Current Clipboard"
    )
    XCTAssertEqual(
      L10n.string(.clipboardCurrentTitle, language: .simplifiedChinese),
      "当前剪贴板"
    )
    XCTAssertEqual(
      L10n.string(.clipboardHistoryDescription, language: .english),
      "All captured and generated items, including already used stack or queue entries."
    )
    XCTAssertEqual(
      L10n.string(.clipboardRoutingTitle, language: .simplifiedChinese),
      "分组"
    )
  }

  func testSimpleCountFormatting() {
    XCTAssertEqual(L10n.itemCount(1, language: .english), "1 item")
    XCTAssertEqual(L10n.itemCount(2, language: .english), "2 items")
    XCTAssertEqual(L10n.itemCount(2, language: .simplifiedChinese), "2 个条目")
  }

  func testHistoryRetentionLabelsAreLocalized() {
    XCTAssertEqual(
      L10n.historyRetentionPeriod(.thirtyDays, language: .english),
      "30 days"
    )
    XCTAssertEqual(
      L10n.historyRetentionPeriod(.forever, language: .simplifiedChinese),
      "永久保留"
    )
    XCTAssertEqual(
      L10n.historySettingsText(.title, language: .english),
      "Local Data & Retention"
    )
    XCTAssertEqual(
      L10n.historySettingsText(.runRetention, language: .english),
      "Run & diagnostic history"
    )
    for key in HistorySettingsTextKey.allCases {
      XCTAssertNotEqual(
        L10n.historySettingsText(key, language: .english),
        key.rawValue
      )
      XCTAssertNotEqual(
        L10n.historySettingsText(key, language: .simplifiedChinese),
        key.rawValue
      )
    }
    XCTAssertEqual(
      L10n.historyMaintenanceResult(
        removedCount: 2,
        preservedActiveClipboardCount: 1,
        language: .simplifiedChinese
      ),
      "已移除 2 条本地历史记录；保留 1 条仍在使用的剪贴板内容。"
    )
  }

  func testMergedRunHistoryScopeHasConciseBilingualCopy() {
    XCTAssertEqual(
      UIStrings.text(.historyScopeLabel, language: .english),
      "Run history view"
    )
    XCTAssertEqual(
      UIStrings.text(.historyScopeLabel, language: .simplifiedChinese),
      "运行历史视图"
    )
    XCTAssertEqual(
      UIStrings.text(.historyScopeAll, language: .english),
      "Recent Runs"
    )
    XCTAssertEqual(
      UIStrings.text(.historyScopeAll, language: .simplifiedChinese),
      "最近运行"
    )
    XCTAssertEqual(
      UIStrings.text(.resultsTitle, language: .english),
      "Recent Results"
    )
    XCTAssertEqual(
      UIStrings.text(.resultsTitle, language: .simplifiedChinese),
      "最近结果"
    )
    XCTAssertEqual(UIStrings.loadedRunCount(1, language: .english), "1 run loaded")
    XCTAssertEqual(UIStrings.loadedRunCount(3, language: .english), "3 runs loaded")
    XCTAssertEqual(UIStrings.loadedRunCount(3, language: .simplifiedChinese), "已加载 3 条运行")
    XCTAssertEqual(
      UIStrings.recentResultsAccessibilityLabel(count: 2, language: .english),
      "Recent Results, 2 results"
    )
  }

  func testAccessibilityControlLabelsAreBilingualAndTargeted() {
    let simpleKeys: [UIStrings.Key] = [
      .clipboardClearSearch,
      .clipboardSection,
      .clipboardAddTag,
      .clipboardRemoveTag,
      .clipboardPasteMode,
      .workflowSourceGroup,
      .workflowTargetGroup,
      .workflowGroupAction,
      .workflowMoveStepUp,
      .workflowMoveStepDown,
      .workflowRemoveStep,
      .workflowEdit,
      .workflowEnabled,
      .workflowDelete,
      .vocabularyRule,
      .vocabularyDeleteRule,
      .historyNewRunsAvailable,
      .historyRefreshNewest,
      .historyNewerPage,
      .historyOlderPage,
      .historyPaginationFailed,
      .historyEntryExpiredTitle,
      .historyEntryExpiredDescription,
    ]

    for key in simpleKeys {
      XCTAssertFalse(UIStrings.text(key, language: .english).isEmpty)
      XCTAssertFalse(UIStrings.text(key, language: .simplifiedChinese).isEmpty)
      XCTAssertNotEqual(
        UIStrings.text(key, language: .english),
        UIStrings.text(key, language: .simplifiedChinese)
      )
    }

    XCTAssertEqual(
      UIStrings.targetedAccessibilityLabel(
        .workflowMoveStepUp,
        target: "Normalize whitespace",
        language: .english
      ),
      "Move step up: Normalize whitespace"
    )
    XCTAssertEqual(
      UIStrings.targetedAccessibilityLabel(
        .workflowEdit,
        target: "Daily Notes",
        language: .english
      ),
      "Edit: Daily Notes"
    )
    XCTAssertEqual(
      UIStrings.targetedAccessibilityLabel(
        .vocabularyDeleteRule,
        target: "Rill → Vox Type",
        language: .simplifiedChinese
      ),
      "删除词汇规则：Rill → Vox Type"
    )
    XCTAssertEqual(
      UIStrings.targetedAccessibilityLabel(
        .clipboardRemoveTag,
        target: "  ",
        language: .english
      ),
      "Remove tag"
    )
  }

  func testEnglishOnlyWhisperKitPresetIsNotPresentedAsBilingual() {
    XCTAssertEqual(
      UIStrings.localSpeechModelOption(.distilLargeV3Compact, language: .english),
      "English Only — Distilled Large v3"
    )
    XCTAssertEqual(
      UIStrings.localSpeechModelOption(.distilLargeV3Compact, language: .simplifiedChinese),
      "仅英语 — Distilled Large v3"
    )
  }

  func testLocalSpeechPreparationFailuresHaveFixedBilingualCopy() {
    XCTAssertEqual(
      UIStrings.text(.localSpeechCancelPreparation, language: .english),
      "Cancel"
    )
    XCTAssertEqual(
      UIStrings.text(.localSpeechCancelPreparation, language: .simplifiedChinese),
      "取消"
    )

    for stage in LocalSpeechPreparationFailure.Stage.allCases {
      let presentation = L10n.localSpeechPreparationFailure(stage)
      XCTAssertFalse(presentation.english.isEmpty)
      XCTAssertFalse(presentation.simplifiedChinese.isEmpty)
      XCTAssertNotEqual(presentation.english, stage.rawValue)
      XCTAssertNotEqual(presentation.simplifiedChinese, stage.rawValue)
    }

    XCTAssertEqual(
      L10n.localSpeechPreparationFailure(.generic),
      LocalizedText(
        english: "Local speech preparation failed. Try again from Speech settings.",
        simplifiedChinese: "本地语音准备失败。请在语音设置中重试。"
      )
    )
    XCTAssertEqual(
      LocalSpeechPreparationFailure(stage: .integrity).localizedDescription,
      L10n.localSpeechPreparationFailure(.integrity).english
    )
  }

  func testFailedAudioRecoveryLabelsAreLocalized() {
    XCTAssertEqual(
      L10n.string(.historyFailedAudioRetry, language: .english),
      "Retry transcription"
    )
    XCTAssertEqual(
      L10n.string(.historyFailedAudioDelete, language: .simplifiedChinese),
      "删除录音"
    )
    XCTAssertEqual(
      L10n.string(
        .historyFailedAudioDeleteConfirmationDetail,
        language: .english
      ),
      "This permanently removes the encrypted recovery recording. The run history entry is kept."
    )
    XCTAssertEqual(
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmation,
        language: .simplifiedChinese
      ),
      "删除全部保留的失败录音吗？"
    )
    XCTAssertFalse(
      L10n.string(
        .historyFailedAudioOutcomeUnknown,
        language: .simplifiedChinese
      ).isEmpty
    )
    XCTAssertFalse(
      L10n.string(
        .settingsFailedAudioRecoveryDescription,
        language: .simplifiedChinese
      ).isEmpty
    )
  }

  func testVocabularyStringsUseUnifiedLookup() throws {
    let titleKey = try XCTUnwrap(L10n.Key(rawValue: "vocabularyTitle"))
    let descriptionKey = try XCTUnwrap(L10n.Key(rawValue: "vocabularyDescription"))

    XCTAssertEqual(L10n.string(titleKey, language: .english), "Vocabulary & Mappings")
    XCTAssertEqual(L10n.string(titleKey, language: .simplifiedChinese), "词汇与映射词")
    XCTAssertEqual(
      L10n.string(descriptionKey, language: .english),
      "Teach Rill names, project terms, and replacements for voice output."
    )
  }

  func testVoiceFailureSummaryMapsDeepgramMissingKey() {
    let message =
      "Deepgram API key is missing. Set DEEPGRAM_API_KEY before using the cloud recognizer."

    XCTAssertTrue(L10n.hasDeepgramAPIKeyRecovery(for: message))
    XCTAssertEqual(
      L10n.voiceFailureSummary(message: message, language: .english),
      "Deepgram API key is missing. Add it in Recognition Settings before using cloud recognition."
    )
    XCTAssertEqual(
      L10n.voiceFailureSummary(message: message, language: .simplifiedChinese),
      "缺少 Deepgram API Key。使用云端识别前，请在识别设置中填写。"
    )
    XCTAssertFalse(L10n.hasDeepgramAPIKeyRecovery(for: "Network timeout"))
    XCTAssertTrue(
      L10n.hasDeepgramAPIKeyRecovery(
        for: "The Deepgram API key is unavailable. Open Settings, save a key, and retry."
      )
    )
  }

  func testClipboardDeletionMakesMergedScopeAndIrreversibilityExplicit() {
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 1,
        language: .english
      ),
      "Delete this clipboard item?"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 1,
        language: .simplifiedChinese
      ),
      "删除这个剪贴板条目？"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationDescription(
        itemCount: 1,
        language: .english
      ),
      "This permanently removes the saved item. This action can't be undone."
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationDescription(
        itemCount: 1,
        language: .simplifiedChinese
      ),
      "这会永久移除已保存的条目，且无法撤销。"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 3,
        language: .english
      ),
      "Delete these 3 merged clipboard items?"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 3,
        language: .simplifiedChinese
      ),
      "删除这 3 个已合并的剪贴板条目？"
    )
    XCTAssertTrue(
      UIStrings.clipboardDeleteConfirmationDescription(
        itemCount: 3,
        language: .english
      ).contains("can't be undone")
    )
    XCTAssertTrue(
      UIStrings.clipboardDeleteConfirmationDescription(
        itemCount: 3,
        language: .simplifiedChinese
      ).contains("无法撤销")
    )

    let copy = [AppLanguage.english, .simplifiedChinese].flatMap { language in
      [
        UIStrings.clipboardDeleteConfirmationTitle(itemCount: 3, language: language),
        UIStrings.clipboardDeleteConfirmationDescription(itemCount: 3, language: language),
      ]
    }.joined(separator: "\n")
    XCTAssertFalse(copy.contains("private clipboard payload"))
  }
}
