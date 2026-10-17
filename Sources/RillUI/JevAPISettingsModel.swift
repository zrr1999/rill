import Observation
import RillCore
import RillRecords
import RillWorkflows

@MainActor @Observable
public final class JevAPISettingsModel {
  public private(set) var configuration: DecisionModelConfiguration
  public private(set) var isConfigured: Bool
  private var polishingEnabled: Bool
  private var hotwordsEnabled = false
  private let hotwordSelection: HotwordSelection?
  public var supportsHotwordSelection: Bool { hotwordSelection != nil }
  public var isHotwordSelectionEnabled: Bool {
    get { hotwordsEnabled }
    set {
      hotwordsEnabled = !closed && newValue && isConfigured && supportsHotwordSelection
      hotwordSelection?.configure(isEnabled: hotwordsEnabled)
    }
  }
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

  public init(service: RecordCloudRanking, hotwordSelection: HotwordSelection? = nil) {
    self.service = service
    configuration = service.settings.configuration
    self.hotwordSelection = hotwordSelection
    isConfigured = service.settings.isConfigured
    polishingEnabled = service.settings.isPolishingEnabled
  }

  public func selectModel(_ model: DecisionModel) {
    select(.init(model: model, accountID: configuration.accountID))
  }

  public func setAccountID(_ value: String) {
    select(.init(model: configuration.model, accountID: value.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func select(_ selection: DecisionModelConfiguration) {
    guard !closed, selection != configuration else { return }
    service.settings.select(selection)
    configuration = selection
    isConfigured = false
    polishingEnabled = false
    isHotwordSelectionEnabled = false
  }

  public func setKey(_ value: String) {
    guard !closed else { return }
    do {
      try service.settings.setKey(value)
      isConfigured = service.settings.isConfigured
      isPolishingEnabled = service.settings.isPolishingEnabled
      isHotwordSelectionEnabled = hotwordsEnabled
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
    isHotwordSelectionEnabled = false
    await service.shutdown()
  }
}
