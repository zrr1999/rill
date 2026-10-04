import RillCore
import RillInputMethodContracts

enum InputMethodText: CaseIterable {
  case description, install, repair, installing, importProfile, importNotice, importPanel
  case activationHelp, openSettings, sectionTitle, learnFromTyping, learnNotice, chooseApps
  case remove, confirm, ignore, confirmed, revokeVocabulary, deleteSuggestion, clearPending
}

extension L10n {
  static func inputMethod(_ key: InputMethodText, language: AppLanguage) -> String {
    switch key {
    case .description: return catalogString("inputMethod.description", language: language)
    case .install: return catalogString("inputMethod.install", language: language)
    case .repair: return catalogString("inputMethod.repair", language: language)
    case .installing: return catalogString("inputMethod.installing", language: language)
    case .importProfile: return catalogString("inputMethod.importProfile", language: language)
    case .importNotice: return catalogString("inputMethod.importNotice", language: language)
    case .importPanel: return catalogString("inputMethod.importPanel", language: language)
    case .activationHelp: return catalogString("inputMethod.activationHelp", language: language)
    case .openSettings: return catalogString("inputMethod.openSettings", language: language)
    case .sectionTitle: return catalogString("inputMethod.sectionTitle", language: language)
    case .learnFromTyping: return catalogString("inputMethod.learnFromTyping", language: language)
    case .learnNotice: return catalogString("inputMethod.learnNotice", language: language)
    case .chooseApps: return catalogString("inputMethod.chooseApps", language: language)
    case .remove: return catalogString("inputMethod.remove", language: language)
    case .confirm: return catalogString("inputMethod.confirm", language: language)
    case .ignore: return catalogString("inputMethod.ignore", language: language)
    case .confirmed: return catalogString("inputMethod.confirmed", language: language)
    case .revokeVocabulary: return catalogString("inputMethod.revokeVocabulary", language: language)
    case .deleteSuggestion: return catalogString("inputMethod.deleteSuggestion", language: language)
    case .clearPending: return catalogString("inputMethod.clearPending", language: language)
    }
  }

  public static func inputMethodSuggestionDetail(
    count: Int, applications: String, language: AppLanguage
  ) -> String {
    L10n.resource("Localization.InputMethod.times", defaultValue: "\(String(describing: count)) times · \(String(describing: applications))").string(
      for: language)
  }

  static func inputMethodState(_ state: InputMethodInstallationState, language: AppLanguage)
    -> String
  {
    switch state {
    case .notInstalled: return catalogString("inputMethodState.notInstalled", language: language)
    case .needsRepair: return catalogString("inputMethodState.needsRepair", language: language)
    case .registrationPending: return catalogString("inputMethodState.registrationPending", language: language)
    case .registered: return catalogString("inputMethodState.registered", language: language)
    case .enabled: return catalogString("inputMethodState.enabled", language: language)
    case .selected: return catalogString("inputMethodState.selected", language: language)
    }
  }
}
