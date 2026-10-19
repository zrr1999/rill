import Foundation

public enum RimeProfileImportError: LocalizedError, Sendable, Equatable {
  case sourceRunning, inputMethodRunning, alreadyImported, incompleteSource, sourceChanged,
    unsafeLink,
    deploymentFailed, helperMissing, installationBusy
  public var errorDescription: String? {
    switch self {
    case .sourceRunning:
      "Switch to ABC and quit Squirrel before importing your full personal dictionary. Ordinary installation and repair do not require quitting Squirrel."
    case .inputMethodRunning: "Switch to another input source and quit RillInputMethod in Activity Monitor before updating. Squirrel can keep running."
    case .alreadyImported: "Rill already has an input method profile. Use Repair to preserve your current dictionary."
    case .incompleteSource: "The selected folder is missing the Wanxiang scheme or personal dictionary."
    case .sourceChanged: "The source profile changed during import. Nothing was installed. Quit Squirrel and try again."
    case .unsafeLink: "The source profile contains symbolic links. Copy their contents into regular files before importing."
    case .deploymentFailed: "Rime deployment or dictionary validation failed. The original profile was preserved."
    case .installationBusy: "Another input method installation is in progress. Try again shortly."
    case .helperMissing: "This Rill build does not include the input method component. Use the complete app build."
    }
  }
}

public enum InputMethodRegistrationError: LocalizedError, Sendable, Equatable {
  case registrationFailed(Int32)
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .registrationFailed(let status):
      "The component was saved, but system registration failed (\(status)). Try Repair again."
    case .unavailable:
      "The component is installed, but Rill is not recognized in this login session. Log out and back in, then add Rill in Input Sources. Reinstallation is unnecessary."
    }
  }
}
