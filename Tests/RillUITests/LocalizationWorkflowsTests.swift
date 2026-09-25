import XCTest

@testable import RillUI

final class LocalizationWorkflowsTests: XCTestCase {
  func testWorkflowTextKeysAreExhaustivelyLocalized() {
    for key in WorkflowTextKey.allCases {
      let english = L10n.workflowText(key, language: .english)
      let simplifiedChinese = L10n.workflowText(key, language: .simplifiedChinese)
      XCTAssertNotEqual(english, key.rawValue)
      XCTAssertNotEqual(simplifiedChinese, key.rawValue)
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(simplifiedChinese.isEmpty)
      XCTAssertNotEqual(english, simplifiedChinese)
    }
  }

  func testWorkflowEditorCopySpotChecks() {
    XCTAssertEqual(L10n.workflowText(.workflowOpenFolder, language: .english), "Open Folder")
    XCTAssertEqual(L10n.workflowText(.workflowOpenFolder, language: .simplifiedChinese), "打开目录")
    XCTAssertEqual(L10n.workflowText(.workflowTriggerWakeWord, language: .english), "◉ Wake Word")
    XCTAssertEqual(L10n.workflowText(.workflowTriggerWakeWord, language: .simplifiedChinese), "◉ 唤醒词")
    XCTAssertEqual(
      L10n.workflowText(.workflowRestoreDefaults, language: .simplifiedChinese),
      "恢复默认"
    )
    XCTAssertEqual(
      L10n.workflowText(.workflowStepNormalizeWhitespace, language: .english),
      "Normalize Whitespace"
    )
    XCTAssertEqual(
      L10n.workflowText(.workflowNotEditableError, language: .simplifiedChinese),
      "当前编辑器暂不支持编辑这个工作流。"
    )
    XCTAssertEqual(
      L10n.workflowText(.workflowDeleteCollectionTitle, language: .english),
      "Delete collection?"
    )
    XCTAssertEqual(
      L10n.workflowText(.workflowReplacementKindOption, language: .simplifiedChinese),
      "替换词"
    )
    XCTAssertEqual(
      L10n.workflowText(.workflowReplacementPlaceholder, language: .simplifiedChinese),
      "替换为"
    )
  }

  func testWorkflowParameterizedCopy() {
    XCTAssertEqual(
      L10n.workflowOpenAIModelHint("gpt-5", language: .english),
      "LLM Provider model: gpt-5. Change it in Settings → Speech Engine."
    )
    XCTAssertEqual(
      L10n.workflowOpenAIModelHint("gpt-5", language: .simplifiedChinese),
      "LLM Provider 模型：gpt-5。可在“设置 → 语音引擎”中切换。"
    )
    XCTAssertEqual(
      L10n.workflowUnsupportedStepError("snippetReplacement", language: .english),
      "The snippetReplacement step is not available without a configured production transformer."
    )
    XCTAssertEqual(
      L10n.workflowUnsupportedStepError("snippetReplacement", language: .simplifiedChinese),
      "尚未配置生产级 transformer，不能使用 snippetReplacement 步骤。"
    )
    XCTAssertEqual(
      L10n.workflowVocabularySummary(hotwordCount: 2, replacementCount: 3, language: .english),
      "2 hotwords · 3 replacements"
    )
    XCTAssertEqual(
      L10n.workflowVocabularySummary(hotwordCount: 2, replacementCount: 3, language: .simplifiedChinese),
      "2 个热词 · 3 个替换词"
    )
  }

  func testWorkflowWakePhraseValidationKeepsDynamicEnglishDescription() {
    XCTAssertEqual(
      L10n.workflowWakePhraseValidationError(
        englishDescription: "provider detail",
        language: .english
      ),
      "provider detail"
    )
    XCTAssertEqual(
      L10n.workflowWakePhraseValidationError(
        englishDescription: "provider detail",
        language: .simplifiedChinese
      ),
      "唤醒词必须包含 1–4 个不重复的有效短语。"
    )
  }

  func testWorkflowViewsReuseExistingSharedKeys() {
    XCTAssertEqual(
      L10n.text(.workflowSourceCollection, language: .english),
      "Source Collection"
    )
    XCTAssertEqual(
      L10n.text(.workflowSourceCollection, language: .simplifiedChinese),
      "来源记录集"
    )
    XCTAssertEqual(L10n.text(.workflowGroupAction, language: .english), "Group Action")
    XCTAssertEqual(L10n.text(.workflowGroupAction, language: .simplifiedChinese), "组动作")
    XCTAssertEqual(L10n.vocabularyRuleKind(.hotword, language: .english), "Hotword")
    XCTAssertEqual(L10n.vocabularyRuleKind(.hotword, language: .simplifiedChinese), "热词")
    XCTAssertEqual(L10n.recordText(.cancel, language: .simplifiedChinese), "取消")
    XCTAssertEqual(L10n.text(.clipboardDeleteItem, language: .english), "Delete")
    XCTAssertEqual(L10n.text(.clipboardDeleteItem, language: .simplifiedChinese), "删除")
  }
}
