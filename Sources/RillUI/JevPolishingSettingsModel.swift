import Foundation
import Observation
import RillCore

@MainActor @Observable
public final class JevPolishingSettingsModel {
  public var isEnabled = false { didSet { update() } }
  public var apiKey = "" { didSet { update() } }
  private let source: JevPolishingSettingsSource

  public init(source: JevPolishingSettingsSource = JevPolishingSettingsSource()) {
    self.source = source
  }

  public var hasValidKey: Bool { JevPolishingSettingsSource.isValidKey(trimmedKey) }
  private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func update() {
    source.update(isEnabled: isEnabled, apiKey: trimmedKey)
  }
}
