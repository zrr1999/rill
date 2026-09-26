public enum InputMethodInstallationState: Sendable, Equatable {
  case notInstalled
  case needsRepair
  case registered
  case enabled
  case selected
}
