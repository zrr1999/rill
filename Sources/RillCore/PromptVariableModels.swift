import Foundation

public enum PromptVariableKey: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
  case text
  case rawText
  case selected
  case clipboard
  case app
  case bundleID
  case group
}
