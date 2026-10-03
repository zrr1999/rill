import Foundation
import RillCore

extension L10n {
  static func workflowText(_ key: WorkflowTextKey, language: AppLanguage) -> String {
    catalogString("workflow.\(key.rawValue)", language: language)
  }

  static func workflowOpenAIModelHint(_ model: String, language: AppLanguage) -> String {
    String(format: workflowText(.workflowOpenAIModelHintFormat, language: language), model)
  }

  static func workflowUnsupportedStepError(_ stepKind: String, language: AppLanguage) -> String {
    String(format: workflowText(.workflowUnsupportedStepFormat, language: language), stepKind)
  }

  static func workflowVocabularySummary(
    hotwordCount: Int,
    replacementCount: Int,
    language: AppLanguage
  ) -> String {
    String(
      format: workflowText(.workflowVocabularySummaryFormat, language: language),
      hotwordCount,
      replacementCount
    )
  }

  static func workflowVocabularyEntryCount(_ count: Int, language: AppLanguage) -> String {
    String(format: workflowText(.workflowVocabularyEntryCountFormat, language: language), count)
  }

  static func workflowPhaseTitle(_ phase: WorkflowPhaseKind, language: AppLanguage) -> String {
    switch phase {
    case .setup:
      workflowText(.workflowPhaseSetup, language: language)
    case .process:
      workflowText(.workflowPhaseProcess, language: language)
    case .output:
      workflowText(.workflowPhaseOutput, language: language)
    }
  }

  static func workflowWakePhraseValidationError(
    englishDescription: String,
    language: AppLanguage
  ) -> String {
    switch language {
    case .english:
      englishDescription
    case .simplifiedChinese:
      workflowText(.workflowWakePhraseInvalid, language: language)
    }
  }

}

enum WorkflowTextKey: String, CaseIterable, Sendable {
  case workflowActionPromptPlaceholder
  case workflowAddEntry
  case workflowAddStep
  case workflowAnyCollection
  case workflowApplyVocabularyHint
  case workflowApplyVocabularyLabel
  case workflowBindingConditionLabel
  case workflowBuiltinOverrideHint
  case workflowBundleIDAnyPlaceholder
  case workflowCancel
  case workflowCollectionEmptyEntries
  case workflowCollectionEntriesToggle
  case workflowConditionNodeTitle
  case workflowCreateItem
  case workflowDefaultRouting
  case workflowDefaultTTSModel
  case workflowDeleteCollection
  case workflowDeleteCollectionDetail
  case workflowDeleteCollectionTitle
  case workflowEditItem
  case workflowEditTOML
  case workflowEditorSubtitleBuiltin
  case workflowEditorSubtitleEditing
  case workflowEditorSubtitleNew
  case workflowEntryKindLabel
  case workflowEventNodeTitle
  case workflowExcludePolishItems
  case workflowHotwordSkippedHint
  case workflowHotwordSupportedHint
  case workflowLLMInstructionRequired
  case workflowLLMPromptPlaceholder
  case workflowLanguageAnyPlaceholder
  case workflowLivePreviewToggle
  case workflowModeOutputNodeTitle
  case workflowNameTakenError
  case workflowNewCollectionPlaceholder
  case workflowNoAdditionalConditions
  case workflowNoVocabularyCollections
  case workflowNotEditableError
  case workflowOnDeviceBadge
  case workflowOpenAIModelHintFormat
  case workflowOpenFolder
  case workflowOrderedActionsHint
  case workflowOutputPhaseSubtitle
  case workflowPhaseOutput
  case workflowPhaseProcess
  case workflowPhaseSetup
  case workflowPhrasePlaceholder
  case workflowPrivacyShortAutomatic
  case workflowPrivacyShortLocal
  case workflowPreviewCursor
  case workflowPreviewLocationLabel
  case workflowPreviewOverlay
  case workflowProcessPhaseSubtitle
  case workflowPromptLabel
  case workflowReadAloudToggle
  case workflowRecognizeSpeechHint
  case workflowRecognizeSpeechLabel
  case workflowRecordCollectionPickerLabel
  case workflowRecordEventUnavailable
  case workflowReload
  case workflowRemoveItem
  case workflowReplacementKindOption
  case workflowReplacementPlaceholder
  case workflowRestoreDefaults
  case workflowRetry
  case workflowSetupPhaseSubtitle
  case workflowSpeakPrimaryHint
  case workflowSpeakResultLabel
  case workflowSpeechRecognitionHint
  case workflowSpeechRecognitionLabel
  case workflowStepLLMAnswer
  case workflowStepLLMRewrite
  case workflowStepNormalizeWhitespace
  case workflowStepSnippetReplacement
  case workflowStreamingStyleLabel
  case workflowStreamingStyleAgent
  case workflowStreamingStyleRealtime
  case workflowStreamingStyleSubtitle
  case workflowTOMLSourceOfTruthHint
  case workflowTriggerHotkey
  case workflowTriggerManual
  case workflowTriggerMenuBar
  case workflowTriggerTypeLabel
  case workflowTriggerWakeWord
  case workflowTTSModelLabel
  case workflowTTSSavedHint
  case workflowUnsupportedStepFormat
  case workflowVocabularyCollectionsLabel
  case workflowVocabularyEntryCountFormat
  case workflowVocabularyLibraryHint
  case workflowVocabularySummaryFormat
  case workflowVoiceLabel
  case workflowWakePhraseInvalid
  case workflowWakePhrasesHint
  case workflowWakePhrasesLabel
  case workflowWakePhrasesPlaceholder
}
