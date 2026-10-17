import Foundation
import RillCore
import RillInputMethodContracts

enum InputMethodText: CaseIterable {
  case description, install, repair, installing, importProfile, importNotice, importPanel
  case activationHelp, openSettings, sectionTitle, learnFromTyping, learnNotice, chooseApps
  case remove, confirm, ignore, confirmed, revokeVocabulary, deleteSuggestion, clearPending
}

extension L10n {
  static func inputMethodInstallationError(_ error: Error) -> LocalizedStringResource {
    if let error = error as? RimeProfileImportError {
      let key: String
      switch error {
      case .sourceRunning: key = "sourceRunning"
      case .inputMethodRunning: key = "inputMethodRunning"
      case .alreadyImported: key = "alreadyImported"
      case .incompleteSource: key = "incompleteSource"
      case .sourceChanged: key = "sourceChanged"
      case .unsafeLink: key = "unsafeLink"
      case .deploymentFailed: key = "deploymentFailed"
      case .helperMissing: key = "helperMissing"
      case .installationBusy: key = "installationBusy"
      }
      return resource("inputMethod.installError.\(key)")
    }
    if let error = error as? InputMethodRegistrationError {
      switch error {
      case .registrationFailed(let status):
        return resource(
          "inputMethod.installError.registrationFailed",
          defaultValue: "The component was saved, but system registration failed (\(String(status))). Try Repair again.")
      case .unavailable: return resource("inputMethod.installError.unavailable")
      }
    }
    return resource(
      "inputMethod.installError.system", defaultValue: "The input method could not be installed. Try again. Details: \(error.localizedDescription)")
  }

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
    pluralString("inputMethod.suggestionDetail", language: language, count, applications)
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
