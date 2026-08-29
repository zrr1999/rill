import XCTest

@testable import RillCore
@testable import RillUI

final class LocalizationSettingsTests: XCTestCase {
  func testSettingsTextKeysAreExhaustivelyLocalized() {
    for key in SettingsTextKey.allCases {
      let english = L10n.settingsText(key, language: .english)
      let simplifiedChinese = L10n.settingsText(key, language: .simplifiedChinese)
      XCTAssertNotEqual(english, key.rawValue)
      XCTAssertNotEqual(simplifiedChinese, key.rawValue)
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(simplifiedChinese.isEmpty)
      XCTAssertNotEqual(english, simplifiedChinese)
    }
  }

  func testSettingsSectionSummariesMatchMigratedCopy() {
    XCTAssertEqual(
      L10n.settingsSectionSummary(.permissions, language: .english),
      "Microphone, global shortcuts, and system access"
    )
    XCTAssertEqual(
      L10n.settingsSectionSummary(.voiceAssistant, language: .simplifiedChinese),
      "就绪检查、唤醒监听、LLM 回答与语音输出"
    )
    XCTAssertEqual(
      L10n.settingsSectionSummary(.storage, language: .english),
      "Retention, recovery, and local cleanup"
    )
    for section in SettingsSection.allCases {
      XCTAssertNotEqual(
        L10n.settingsSectionSummary(section, language: .english),
        L10n.settingsSectionSummary(section, language: .simplifiedChinese)
      )
    }
  }

  func testSettingsGroupHeadersMatchMigratedCopy() {
    XCTAssertEqual(
      L10n.settingsText(.settingsGroupVoiceAndModels, language: .english),
      "Voice & Models"
    )
    XCTAssertEqual(
      L10n.settingsText(.settingsGroupVoiceAndModels, language: .simplifiedChinese),
      "语音与模型"
    )
    XCTAssertEqual(
      L10n.settingsText(.settingsRetryLoading, language: .simplifiedChinese),
      "重试加载"
    )
  }

  func testWakeWordAndReadinessHelpersMatchMigratedCopy() {
    XCTAssertEqual(
      L10n.settingsResourceDownloadTitle("local ASR", language: .english),
      "Download local ASR"
    )
    XCTAssertEqual(
      L10n.settingsResourceRetryTitle("本地语音模型", language: .simplifiedChinese),
      "重试本地语音模型"
    )
    XCTAssertEqual(
      L10n.settingsWorkflowName("助手", language: .simplifiedChinese),
      "工作流：助手"
    )
    XCTAssertEqual(
      L10n.wakeWordRuntimeStatus(.suspended("busy"), language: .english),
      "Paused: assistant workflow is running"
    )
    XCTAssertEqual(
      L10n.wakeWordRuntimeStatus(.suspended("speechPlayback"), language: .simplifiedChinese),
      "已暂停：正在播放语音"
    )
    XCTAssertEqual(
      L10n.wakeWordSuspensionReason("unknown-reason", language: .english),
      "unknown-reason"
    )
    XCTAssertEqual(
      L10n.microphoneReadinessDetail(.granted, language: .english),
      "Ready"
    )
    XCTAssertEqual(
      L10n.llmReadinessDetail(.verificationFailed(nil), language: .simplifiedChinese),
      "验证失败"
    )
    XCTAssertEqual(
      L10n.speechOutputReadinessDetail(.notRequired, language: .english),
      "Not used by this workflow"
    )
    XCTAssertEqual(
      L10n.privacyReadinessDetail(
        .ready(cloudConfirmationRequired: true),
        language: .simplifiedChinese
      ),
      "每次运行需要确认"
    )
  }

  func testSpeechPoolAndOpenAIHelpersMatchMigratedCopy() {
    XCTAssertEqual(
      L10n.settingsOpenAIModelID("gpt-5.6-luna", language: .english),
      "Model ID: gpt-5.6-luna"
    )
    XCTAssertEqual(
      L10n.settingsOpenAIModelID("gpt-5.6-luna", language: .simplifiedChinese),
      "模型 ID：gpt-5.6-luna"
    )
    XCTAssertEqual(
      L10n.openAIModelLabel(.luna, language: .simplifiedChinese),
      "Luna — 高吞吐 (gpt-5.6-luna)"
    )
    XCTAssertEqual(
      L10n.openAIModelLabel(.custom, language: .english),
      L10n.string(.settingsOpenAICustomModel, language: .english)
    )
    XCTAssertEqual(
      L10n.settingsResidentMemoryBudget(
        estimatedGigabytes: 2.5,
        estimatedFractionPercent: 25.5,
        modelList: "a, b",
        language: .english
      ),
      "Estimated 2.50 GB (25.5%): a, b"
    )
    XCTAssertEqual(
      L10n.settingsResidentMemoryBudget(
        estimatedGigabytes: 2.5,
        estimatedFractionPercent: 25.5,
        modelList: "a, b",
        language: .simplifiedChinese
      ),
      "预计 2.50 GB（25.5%）：a, b"
    )
    XCTAssertEqual(
      L10n.openAIVerificationFailureMessage(.timedOut, language: .simplifiedChinese),
      "验证请求超时。"
    )
    XCTAssertEqual(
      L10n.openAIVerificationFailureMessage(nil, language: .english),
      L10n.string(.settingsOpenAIVerificationFailed, language: .english)
    )
  }

  func testStorageAndPrivacySpotChecksMatchMigratedCopy() {
    XCTAssertEqual(
      L10n.settingsFailedAudioEncryptedCount(3, language: .english),
      "3 encrypted"
    )
    XCTAssertEqual(
      L10n.settingsFailedAudioEncryptedCount(3, language: .simplifiedChinese),
      "已加密 3 条"
    )
    XCTAssertEqual(
      L10n.settingsText(.settingsPrivacyRuleUpdateFailed, language: .simplifiedChinese),
      "无法更新隐私规则。请检查规则后重试。"
    )
    XCTAssertEqual(
      L10n.settingsText(.settingsManageVocabularyCollections, language: .english),
      "Manage Collections and Workflow Bindings"
    )
  }
}
