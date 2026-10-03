import Foundation
import RillCore

extension L10n {
  static func overlayText(_ key: OverlayTextKey, language: AppLanguage) -> String {
    catalogString("overlay.\(key.rawValue)", language: language)
  }

  static func candidateSetTitle(_ ordinal: Int, language: AppLanguage) -> String {
    String(format: overlayText(.candidateSetTitleFormat, language: language), ordinal)
  }

  /// Window and accessibility title of the live-subtitle floating panel.
  /// Public because the panel controller lives in RillApp.
  public static func liveSubtitlePanelTitle(language: AppLanguage) -> String {
    overlayText(.liveSubtitlePanelTitle, language: language)
  }

  static func liveSubtitleRemaining(_ remaining: String, language: AppLanguage) -> String {
    String(format: overlayText(.liveSubtitleRemainingFormat, language: language), remaining)
  }

  static func liveSubtitleRecorded(_ elapsed: String, language: AppLanguage) -> String {
    String(format: overlayText(.liveSubtitleRecordedFormat, language: language), elapsed)
  }

}

enum OverlayTextKey: String, CaseIterable, Sendable {
  case candidateSetTitleFormat
  case correctionCreateScopedCollection
  case correctionSaveToCollection
  case correctionSettingsLoading
  case liveSubtitleContinueNoTimeLimit
  case liveSubtitleContinueWithoutLimitHelp
  case liveSubtitleEscapeHint
  case liveSubtitlePanelTitle
  case liveSubtitleRecordedFormat
  case liveSubtitleRecordingJustStarted
  case liveSubtitleRemainingFormat
  case searchCategoryPages
  case searchCategoryRunHistory
  case searchCommand
  case searchHistorySearching
  case searchHistoryUnavailable
  case searchNoResultsDescription
  case searchNoResultsTitle
  case searchOpenInWorkflows
  case searchOpenSettingsSection
  case searchPrompt
  case searchQuickDestinations
  case settingsVoiceAssistantTitle
}
