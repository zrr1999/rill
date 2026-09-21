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
    XCTAssertEqual(
      UIStrings.recordingDurationLimit(.twoMinutes, language: .english),
      "2 minutes"
    )
    XCTAssertEqual(
      UIStrings.recordingDurationLimit(.unlimited, language: .simplifiedChinese),
      "无限制"
    )
    XCTAssertEqual(L10n.string(textStylesKey, language: .simplifiedChinese), "文字风格")
  }

  func testRecordSectionStringsUseUnifiedLookup() {
    XCTAssertEqual(
      L10n.string(.clipboardCurrentTitle, language: .english),
      "Collection Records"
    )
    XCTAssertEqual(
      L10n.string(.clipboardCurrentTitle, language: .simplifiedChinese),
      "记录集内容"
    )
    XCTAssertEqual(
      L10n.string(.clipboardHistoryDescription, language: .english),
      "All captured and generated records, including records with no collection membership."
    )
    XCTAssertEqual(
      L10n.string(.clipboardRoutingTitle, language: .simplifiedChinese),
      "记录集"
    )
  }

  func testSimpleCountFormatting() {
    XCTAssertEqual(L10n.itemCount(1, language: .english), "1 item")
    XCTAssertEqual(L10n.itemCount(2, language: .english), "2 items")
    XCTAssertEqual(L10n.itemCount(2, language: .simplifiedChinese), "2 个条目")
  }

  func testVocabularyHotwordCopyCoversLocalQwen() {
    XCTAssertEqual(
      L10n.string(.vocabularyCorrectionHotwordOption, language: .simplifiedChinese),
      "作为识别热词优先识别"
    )
    let english = L10n.string(.vocabularyHotwordBehavior, language: .english)
    let simplifiedChinese = L10n.string(
      .vocabularyHotwordBehavior,
      language: .simplifiedChinese
    )
    XCTAssertTrue(english.contains("local Qwen"))
    XCTAssertTrue(simplifiedChinese.contains("本地 Qwen"))
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
        preservedActiveRecordCount: 1,
        language: .simplifiedChinese
      ),
      "已移除 2 条本地记录；保留 1 条活跃记录。"
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
  }

  func testAccessibilityControlLabelsAreBilingualAndTargeted() {
    let simpleKeys: [UIStrings.Key] = [
      .sidebarStream,
      .clipboardClearSearch,
      .clipboardSection,
      .clipboardAddTag,
      .clipboardRemoveTag,
      .clipboardPasteMode,
      .workflowSourceCollection,
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

  func testClipboardDeletionMakesMergedScopeAndIrreversibilityExplicit() {
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 1,
        language: .english
      ),
      "Delete this record?"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 1,
        language: .simplifiedChinese
      ),
      "删除这条记录？"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationDescription(
        itemCount: 1,
        language: .english
      ),
      "This permanently removes the saved record. This action can't be undone."
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationDescription(
        itemCount: 1,
        language: .simplifiedChinese
      ),
      "这会永久移除已保存的记录，且无法撤销。"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 3,
        language: .english
      ),
      "Delete these 3 merged records?"
    )
    XCTAssertEqual(
      UIStrings.clipboardDeleteConfirmationTitle(
        itemCount: 3,
        language: .simplifiedChinese
      ),
      "删除这 3 条已合并的记录？"
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

  func testRecordTextKeysAreExhaustivelyLocalized() {
    for key in RecordTextKey.allCases {
      let english = L10n.recordText(key, language: .english)
      let simplifiedChinese = L10n.recordText(key, language: .simplifiedChinese)
      XCTAssertNotEqual(english, key.rawValue)
      XCTAssertNotEqual(simplifiedChinese, key.rawValue)
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(simplifiedChinese.isEmpty)
      XCTAssertNotEqual(english, simplifiedChinese)
    }

    XCTAssertEqual(
      L10n.recordText(.collectionPresetStack, language: .english),
      "Stack"
    )
    XCTAssertEqual(
      L10n.recordText(.collectionPresetStack, language: .simplifiedChinese),
      "栈"
    )
    XCTAssertEqual(
      L10n.recordText(.collectionPresetQueue, language: .simplifiedChinese),
      "队列"
    )
    XCTAssertEqual(
      L10n.recordText(.collectionPresetList, language: .simplifiedChinese),
      "列表"
    )
    XCTAssertEqual(L10n.recordCount(3, language: .english), "3 records")
    XCTAssertEqual(L10n.recordCount(3, language: .simplifiedChinese), "3 条记录")
    XCTAssertEqual(
      L10n.removeFromCollection("Inbox", language: .english),
      "Remove from Inbox"
    )
    XCTAssertEqual(
      L10n.collectionReferencesUsage(
        captureRouteCount: 2,
        deliveryRouteCount: 1,
        language: .english
      ),
      "This collection is used by 2 capture routes and 1 delivery routes."
    )
    XCTAssertEqual(L10n.routePriority(5, language: .simplifiedChinese), "优先级 5")
    XCTAssertEqual(L10n.routePriorityLabel(-2, language: .english), "Priority: -2")
  }

  func testHistoryTimelineTextKeysAreExhaustivelyLocalized() {
    for key in HistoryTimelineTextKey.allCases {
      let english = L10n.historyTimelineText(key, language: .english)
      let simplifiedChinese = L10n.historyTimelineText(key, language: .simplifiedChinese)
      XCTAssertNotEqual(english, key.rawValue)
      XCTAssertNotEqual(simplifiedChinese, key.rawValue)
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(simplifiedChinese.isEmpty)
      XCTAssertNotEqual(english, simplifiedChinese)
    }

    XCTAssertEqual(L10n.historyTimelineAction(2, language: .english), "Action 2")
    XCTAssertEqual(L10n.historyTimelineAction(2, language: .simplifiedChinese), "动作 2")
    XCTAssertEqual(
      L10n.historyTimelineLLMRequestStep(3, language: .simplifiedChinese),
      "LLM 请求 · 第 3 步"
    )
    XCTAssertEqual(
      L10n.historyTimelineSentMessage(role: "user", number: 1, language: .english),
      "Sent message · user 1"
    )
    XCTAssertEqual(
      L10n.historyTimelineMessageRole(.user, language: .simplifiedChinese),
      "用户"
    )
    XCTAssertEqual(
      L10n.historyTimelineMessageRole(.assistant, language: .english),
      "Assistant"
    )
    XCTAssertEqual(
      L10n.historyTimelineSentToLLMStep(2, language: .simplifiedChinese),
      "发送给 LLM · 第 2 步"
    )
    XCTAssertEqual(
      L10n.historyRunTrigger(.wakeWord, language: .simplifiedChinese),
      "唤醒词"
    )
    XCTAssertEqual(
      L10n.historyRunDurationBucket(.s1To4, language: .english),
      "1–4 s"
    )
    XCTAssertEqual(
      L10n.historyRunStatus(.skipped, language: .english),
      "Skipped"
    )
    XCTAssertEqual(
      L10n.historyRunStatus(.completed, language: .simplifiedChinese),
      L10n.workflowRunTermination(.completed, language: .simplifiedChinese)
    )
  }
}
