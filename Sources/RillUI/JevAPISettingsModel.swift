import Observation
import RillCore
import RillRecords

@MainActor @Observable
public final class JevAPISettingsModel {
  public private(set) var isConfigured: Bool
  private var polishingEnabled: Bool
  public var isPolishingEnabled: Bool {
    get { polishingEnabled }
    set {
      service.settings.setPolishingEnabled(newValue)
      polishingEnabled = service.settings.isPolishingEnabled
    }
  }
  public private(set) var error: RecordRankingError?
  let service: RecordCloudRanking
  private var closed = false

  public init(service: RecordCloudRanking) {
    self.service = service
    isConfigured = service.settings.isConfigured
    polishingEnabled = service.settings.isPolishingEnabled
  }

  public func setKey(_ value: String) {
    guard !closed else { return }
    do {
      try service.settings.setKey(value)
      isConfigured = service.settings.isConfigured
      isPolishingEnabled = service.settings.isPolishingEnabled
      error = nil
    } catch {
      self.error = (error as? RecordRankingError) ?? .unavailable
    }
  }

  public func shutdown() async {
    closed = true
    service.settings.clear()
    isConfigured = false
    isPolishingEnabled = false
    await service.shutdown()
  }
}
