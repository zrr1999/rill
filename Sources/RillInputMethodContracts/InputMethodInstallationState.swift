public enum InputMethodInstallationState: Sendable, Equatable {
  case notInstalled
  case needsRepair
  case registrationPending
  case registered
  case enabled
  case selected
}
