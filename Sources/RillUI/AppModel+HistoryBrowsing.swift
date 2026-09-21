import Foundation
import RillCore

extension AppModel {
  static let runHistoryPageSize = RunHistoryModel.runHistoryPageSize
  public var usesPagedRunHistory: Bool { history.usesPagedRunHistory }
  var displayedRunHistoryEntries: [HistoryTimelineEntry] { history.displayedRunHistoryEntries }
  public var canLoadNewerRunHistoryPage: Bool { history.canLoadNewerRunHistoryPage }
  public var canLoadOlderRunHistoryPage: Bool { history.canLoadOlderRunHistoryPage }
  var effectiveRunHistoryLoadState: HistoryLoadState { history.effectiveRunHistoryLoadState }
  func resetRunHistoryBrowsing() { history.resetRunHistoryBrowsing() }
  public func retryRunHistoryInitialLoad() {
    if usesPagedRunHistory { history.retryRunHistoryInitialLoad() } else { retryHistoryLoad() }
  }
  public func refreshNewestRunHistoryPage() {
    if usesPagedRunHistory { history.refreshNewestRunHistoryPage() } else { retryHistoryLoad() }
  }
  public func loadOlderRunHistoryPage() { history.loadOlderRunHistoryPage() }
  public func loadNewerRunHistoryPage() { history.loadNewerRunHistoryPage() }
  func noteNewRunAvailableForHistoryBrowsing() { history.noteNewRunAvailableForHistoryBrowsing() }
  func resetRunHistoryBrowsingForPrivacyChange() {
    history.resetRunHistoryBrowsingForPrivacyChange()
  }
  public func resolveRunHistoryDeepLinkIfNeeded() async {
    await history.resolveRunHistoryDeepLinkIfNeeded()
  }
  public func retryRunHistoryDeepLink() { history.retryRunHistoryDeepLink() }
  func visibleRunHistoryEntryID(matching id: UUID) -> UUID? {
    history.visibleRunHistoryEntryID(matching: id)
  }
  func searchRunHistory(
    query: String, language: AppLanguage, previewMode: PrivacyHistoryPreviewMode,
    limit: Int = GlobalSearchIndex.maximumHistoryResultCount
  ) async throws -> [GlobalSearchResult] {
    try await history.searchRunHistory(query: query, language: language, previewMode: previewMode, limit: limit)
  }
}
