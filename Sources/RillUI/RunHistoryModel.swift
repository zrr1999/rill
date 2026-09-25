import Foundation
import Observation
import RillCore
import RillRuntime

enum RunHistoryPageLocator: Equatable, Sendable {
  case request(RunHistoryPageRequest)
  case snapshotAnchor(entryID: UUID, session: RunHistoryReadSession)
  case deepLinkAnchor(entryID: UUID, session: RunHistoryReadSession)
}

private enum RunHistoryPresentationError: Error {
  case invalidPageSize(Int)
  case inconsistentSession
  case pageNoLongerAvailable
}

enum RunHistorySearchError: Error, Equatable {
  case unavailable
}

@MainActor @Observable
public final class RunHistoryModel {
  public var eventFeed: [EventFeedEntry] = []
  public internal(set) var diagnosticEvents: [DiagnosticEvent] = []
  public internal(set) var diagnosticsLoadState: DiagnosticsLoadState = .loading
  public internal(set) var isUpdatingHistoryRetentionSettings = false
  public internal(set) var isLocalHistoryMaintenanceRunning = false
  public internal(set) var historyRetentionSettingsError: String?
  public internal(set) var areHistoryRetentionSettingsAvailable = true
  public internal(set) var localHistoryMaintenancePendingReason: String?
  public internal(set) var localHistoryMaintenanceBlockedReason: String?
  public internal(set) var lastLocalHistoryRemovedCount = 0
  public internal(set) var lastPreservedActiveRecordCount = 0
  var historyLoadGeneration = 0
  var runReceiptLoadGeneration = 0
  var historyProjectionLoadTasks: [UUID: Task<Void, Never>] = [:]
  var historyRetentionRerunRequested = false
  var historyRetentionSettingsLoadError: String?
  var historyRetentionSettingsWriteError: String?
  var clipboardHistoryRetentionSettingIsInvalid = false
  var runHistoryRetentionSettingIsInvalid = false
  var shouldStartPeriodicHistoryRetentionMaintenance = false
  var localHistoryMaintenanceTasks: [UUID: Task<Void, Never>] = [:]
  var periodicHistoryRetentionMaintenanceTask: Task<Void, Never>?
  var diagnosticsLoadGeneration = 0

  static let runHistoryPageSize = 50
  private let runHistoryBrowser: (any RunHistoryBrowsing)?
  private let library: WorkflowLibraryModel
  var previewMode: PrivacyHistoryPreviewMode = .restricted
  var runHistoryRetentionPeriod: HistoryRetentionPeriod = .defaultPeriod
  var hasBegunApplicationShutdown = false
  var runHistoryScope: RunHistoryScope = .recentRuns {
    didSet { if oldValue != runHistoryScope { resetRunHistoryBrowsing() } }
  }
  var historyLoadState: HistoryLoadState = .loaded
  var historyRecords: [WorkflowResultRecord] = []
  var runHistoryBrowseLoadState: HistoryLoadState = .loaded
  var runHistoryPage: RunHistoryPage?
  var isRunHistoryPageTransitioning: Bool = false
  var runHistoryPaginationFailed: Bool = false
  var runHistoryHasNewerEntries: Bool = false
  var runHistoryDeepLinkState: RunHistoryDeepLinkState = .idle
  var workflowRunReceiptsByRunID: [UUID: WorkflowRunReceipt] = [:]
  var runHistoryBrowseTask: Task<Void, Never>?
  var runHistoryBrowseGeneration: Int = 0
  var runHistoryCurrentPageLocator: RunHistoryPageLocator?
  var runHistoryNewerPageLocators: [RunHistoryPageLocator] = []
  var historyNavigationRequest: HistoryNavigationRequest?
  init(browser: (any RunHistoryBrowsing)?, workflows: WorkflowLibraryModel) {
    runHistoryBrowser = browser
    library = workflows
  }
  var recentVoiceHistoryRecords: [WorkflowResultRecord] {
    historyRecords.filter(isVoiceHistoryRecord)
  }
  var recentVoiceResultRecords: [WorkflowResultRecord] {
    recentVoiceHistoryRecords.filter {
      $0.outcome == .completed
        && !($0.finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
  }
  func isVoiceHistoryRecord(_ record: WorkflowResultRecord) -> Bool {
    let receiptTrigger = record.runID.flatMap {
      workflowRunReceiptsByRunID[$0]?.trigger
    }
    if let recordTrigger = record.trigger, let receiptTrigger {
      // Two durable authorities must agree. A corrupt or mismatched join
      // cannot gain permission to surface a body.
      guard recordTrigger == receiptTrigger else { return false }
      return recordTrigger.isVoiceCapture
    }
    return (record.trigger ?? receiptTrigger)?.isVoiceCapture == true
  }

  public var usesPagedRunHistory: Bool {
    runHistoryBrowser != nil
  }

  var displayedRunHistoryEntries: [HistoryTimelineEntry] {
    guard usesPagedRunHistory else {
      return legacyDisplayedRunHistoryEntries
    }
    return (runHistoryPage?.entries ?? []).map(HistoryTimelineEntry.init)
  }

  public var canLoadNewerRunHistoryPage: Bool {
    guard runHistoryPage != nil else { return false }
    if !runHistoryNewerPageLocators.isEmpty { return true }
    if runHistoryCurrentPageLocator?.returnsToNewest == true { return true }
    return false
  }

  public var canLoadOlderRunHistoryPage: Bool {
    runHistoryPage?.nextCursor != nil
  }

  var effectiveRunHistoryLoadState: HistoryLoadState {
    usesPagedRunHistory ? runHistoryBrowseLoadState : historyLoadState
  }

  func resetRunHistoryBrowsing() {
    runHistoryBrowseGeneration += 1
    runHistoryBrowseTask?.cancel()
    runHistoryBrowseTask = nil
    runHistoryCurrentPageLocator = nil
    runHistoryNewerPageLocators.removeAll()
    runHistoryPage = nil
    isRunHistoryPageTransitioning = false
    runHistoryPaginationFailed = false
    runHistoryHasNewerEntries = false
    runHistoryDeepLinkState = .idle

    guard runHistoryBrowser != nil, !hasBegunApplicationShutdown else {
      runHistoryBrowseLoadState = .loaded
      return
    }
    loadRunHistoryFirstPage(preservingCurrentPage: false)
  }

  public func retryRunHistoryInitialLoad() {
    guard usesPagedRunHistory else {
      return
    }
    loadRunHistoryFirstPage(preservingCurrentPage: false)
  }

  public func refreshNewestRunHistoryPage() {
    guard usesPagedRunHistory else {
      return
    }
    loadRunHistoryFirstPage(preservingCurrentPage: runHistoryPage != nil)
  }

  public func loadOlderRunHistoryPage() {
    guard !isRunHistoryPageTransitioning,
      let currentPage = runHistoryPage,
      let currentLocator = runHistoryCurrentPageLocator,
      let cursor = currentPage.nextCursor
    else {
      return
    }
    let target = RunHistoryPageLocator.request(
      .next(cursor: cursor, limit: Self.runHistoryPageSize)
    )
    loadRunHistoryPage(
      at: target,
      newerLocators: runHistoryNewerPageLocators + [currentLocator],
      preservingCurrentPage: true,
      clearsNewerNotice: false
    )
  }

  public func loadNewerRunHistoryPage() {
    guard !isRunHistoryPageTransitioning, runHistoryPage != nil else { return }
    if let target = runHistoryNewerPageLocators.last {
      if runHistoryHasNewerEntries, runHistoryNewerPageLocators.count == 1 {
        loadRunHistoryFirstPage(preservingCurrentPage: true)
        return
      }
      loadRunHistoryPage(
        at: target,
        newerLocators: Array(runHistoryNewerPageLocators.dropLast()),
        preservingCurrentPage: true,
        clearsNewerNotice: false
      )
      return
    }
    if runHistoryCurrentPageLocator?.returnsToNewest == true {
      loadRunHistoryFirstPage(preservingCurrentPage: true)
    }
  }

  func noteNewRunAvailableForHistoryBrowsing() {
    guard usesPagedRunHistory else { return }
    runHistoryHasNewerEntries = true
    guard runHistoryPage == nil || isPresentingNewestRunHistoryPage else { return }
    loadRunHistoryFirstPage(preservingCurrentPage: runHistoryPage != nil)
  }

  func resetRunHistoryBrowsingForPrivacyChange() {
    guard usesPagedRunHistory else { return }
    resetRunHistoryBrowsing()
  }

  public func resolveRunHistoryDeepLinkIfNeeded() async {
    guard let request = historyNavigationRequest,
      request.scope == runHistoryScope,
      usesPagedRunHistory
    else {
      return
    }
    if visibleRunHistoryEntryID(matching: request.entryID) != nil {
      runHistoryDeepLinkState = .resolved(entryID: request.entryID)
      return
    }
    switch runHistoryDeepLinkState {
    case .idle:
      break
    case .resolving(let entryID),
      .resolved(let entryID),
      .expired(let entryID),
      .failed(let entryID):
      guard entryID != request.entryID else { return }
    }

    runHistoryBrowseGeneration += 1
    let generation = runHistoryBrowseGeneration
    runHistoryBrowseTask?.cancel()
    runHistoryPaginationFailed = false
    runHistoryDeepLinkState = .resolving(entryID: request.entryID)
    let hadPage = runHistoryPage != nil
    isRunHistoryPageTransitioning = hadPage
    if !hadPage {
      runHistoryBrowseLoadState = .loading
    }
    guard let runHistoryBrowser else { return }
    let scope = runHistoryBrowseScope
    let retentionCutoff = runHistoryRetentionPeriod.cutoffDate(relativeTo: Date())
    let contentAccess = runHistoryContentAccess
    let entryID = request.entryID

    let task = Task { @MainActor [weak self, runHistoryBrowser] in
      do {
        let page = try await runHistoryBrowser.page(
          containing: entryID,
          scope: scope,
          retentionCutoff: retentionCutoff,
          contentAccess: contentAccess,
          limit: Self.runHistoryPageSize
        )
        try Task.checkCancellation()
        guard let self,
          !self.hasBegunApplicationShutdown,
          self.runHistoryBrowseGeneration == generation,
          self.historyNavigationRequest?.entryID == entryID
        else {
          return
        }
        self.runHistoryBrowseTask = nil
        self.isRunHistoryPageTransitioning = false
        guard let page else {
          self.runHistoryBrowseLoadState = .loaded
          self.runHistoryDeepLinkState = .expired(entryID: entryID)
          if !hadPage {
            self.loadRunHistoryFirstPage(
              preservingCurrentPage: false,
              clearsNewerNotice: false
            )
          }
          return
        }
        try self.validateRunHistoryPage(
          page,
          expectedScope: scope,
          expectedContentAccess: contentAccess
        )
        self.runHistoryPage = page
        self.runHistoryCurrentPageLocator = .deepLinkAnchor(
          entryID: entryID,
          session: page.session
        )
        self.runHistoryNewerPageLocators.removeAll()
        self.runHistoryBrowseLoadState = .loaded
        self.runHistoryDeepLinkState = .resolved(entryID: entryID)
      } catch is CancellationError {
        return
      } catch {
        guard let self,
          self.runHistoryBrowseGeneration == generation
        else {
          return
        }
        self.runHistoryBrowseTask = nil
        self.isRunHistoryPageTransitioning = false
        if hadPage {
          self.runHistoryPaginationFailed = true
        } else {
          self.runHistoryBrowseLoadState = .failed(.repositoryUnavailable)
        }
        self.runHistoryDeepLinkState = .failed(entryID: entryID)
      }
    }
    runHistoryBrowseTask = task
    await task.value
  }

  public func retryRunHistoryDeepLink() {
    guard case .failed = runHistoryDeepLinkState else { return }
    runHistoryDeepLinkState = .idle
  }

  /// Maps every durable deep-link alias onto the single row identity used by
  /// SwiftUI. Receipt run IDs, orphan-record run IDs, and WorkflowResultRecord IDs
  /// can all address the same visible timeline row.
  func visibleRunHistoryEntryID(matching requestedID: UUID) -> UUID? {
    displayedRunHistoryEntries.first { entry in
      entry.id == requestedID
        || entry.record?.id == requestedID
        || entry.record?.runID == requestedID
        || entry.recordMetadata?.recordID == requestedID
        || entry.recordMetadata?.runID == requestedID
        || entry.receipt?.runID == requestedID
    }?.id
  }

  func searchRunHistory(
    query: String,
    language: AppLanguage,
    previewMode: PrivacyHistoryPreviewMode,
    limit: Int = GlobalSearchIndex.maximumHistoryResultCount
  ) async throws -> [GlobalSearchResult] {
    guard let runHistoryBrowser else {
      throw RunHistorySearchError.unavailable
    }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }

    let contentAccess = Self.runHistoryContentAccess(for: previewMode)
    var request = RunHistoryPageRequest.first(
      scope: .allRuns,
      retentionCutoff: runHistoryRetentionPeriod.cutoffDate(relativeTo: Date()),
      contentAccess: contentAccess,
      limit: Self.runHistoryPageSize
    )
    let workflowSnapshot = library.workflows
    var matches: [GlobalSearchResult] = []
    var matchedIDs: Set<String> = []

    while matches.count < limit {
      try Task.checkCancellation()
      let page = try await runHistoryBrowser.page(request)
      try Task.checkCancellation()
      try validateRunHistoryPage(
        page,
        expectedScope: .allRuns,
        expectedContentAccess: contentAccess
      )
      let pageResults = GlobalSearchIndex.filter(
        GlobalSearchIndex.makeHistoryResults(
          language: language,
          workflows: workflowSnapshot,
          entries: page.entries.map(HistoryTimelineEntry.init),
          previewMode: previewMode
        ),
        query: trimmedQuery
      )
      for result in pageResults where matchedIDs.insert(result.id).inserted {
        matches.append(result)
        if matches.count == limit {
          break
        }
      }
      guard matches.count < limit,
        let cursor = page.nextCursor
      else {
        break
      }
      request = .next(cursor: cursor, limit: Self.runHistoryPageSize)
    }
    return matches
  }

  private var legacyDisplayedRunHistoryEntries: [HistoryTimelineEntry] {
    switch runHistoryScope {
    case .recentRuns:
      return HistoryTimelineBuilder.allRuns(
        records: recentVoiceHistoryRecords,
        receipts: Array(workflowRunReceiptsByRunID.values)
      )
    case .recentResults:
      return HistoryTimelineBuilder.results(
        records: recentVoiceResultRecords,
        receiptsByRunID: workflowRunReceiptsByRunID
      )
    }
  }

  private var runHistoryBrowseScope: RunHistoryBrowseScope {
    switch runHistoryScope {
    case .recentRuns: .allRuns
    case .recentResults: .voiceResults
    }
  }

  private var runHistoryContentAccess: RunHistoryContentAccess {
    Self.runHistoryContentAccess(for: previewMode)
  }

  private var isPresentingNewestRunHistoryPage: Bool {
    guard runHistoryNewerPageLocators.isEmpty else { return false }
    switch runHistoryCurrentPageLocator {
    case .request(.first), .snapshotAnchor:
      return true
    case .request(.next), .deepLinkAnchor, nil:
      return false
    }
  }

  private static func runHistoryContentAccess(
    for previewMode: PrivacyHistoryPreviewMode
  ) -> RunHistoryContentAccess {
    switch previewMode {
    case .full: .full
    case .restricted: .restrictedPreview
    case .disabled: .metadataOnly
    }
  }

  private func loadRunHistoryFirstPage(
    preservingCurrentPage: Bool,
    clearsNewerNotice: Bool = true
  ) {
    let request = RunHistoryPageRequest.first(
      scope: runHistoryBrowseScope,
      retentionCutoff: runHistoryRetentionPeriod.cutoffDate(relativeTo: Date()),
      contentAccess: runHistoryContentAccess,
      limit: Self.runHistoryPageSize
    )
    loadRunHistoryPage(
      at: .request(request),
      newerLocators: [],
      preservingCurrentPage: preservingCurrentPage,
      clearsNewerNotice: clearsNewerNotice
    )
  }

  private func loadRunHistoryPage(
    at locator: RunHistoryPageLocator,
    newerLocators: [RunHistoryPageLocator],
    preservingCurrentPage: Bool,
    clearsNewerNotice: Bool
  ) {
    guard let runHistoryBrowser, !hasBegunApplicationShutdown else { return }
    runHistoryBrowseGeneration += 1
    let generation = runHistoryBrowseGeneration
    runHistoryBrowseTask?.cancel()
    runHistoryPaginationFailed = false
    let hadPage = preservingCurrentPage && runHistoryPage != nil
    isRunHistoryPageTransitioning = hadPage
    if !hadPage {
      runHistoryPage = nil
      runHistoryBrowseLoadState = .loading
    }

    let task = Task { @MainActor [weak self, runHistoryBrowser] in
      do {
        let page: RunHistoryPage
        switch locator {
        case .request(let request):
          page = try await runHistoryBrowser.page(request)
        case .snapshotAnchor(let entryID, let session),
          .deepLinkAnchor(let entryID, let session):
          guard
            let locatedPage = try await runHistoryBrowser.page(
              containing: entryID,
              in: session,
              limit: Self.runHistoryPageSize
            )
          else {
            throw RunHistoryPresentationError.pageNoLongerAvailable
          }
          page = locatedPage
        }
        try Task.checkCancellation()
        guard let self,
          !self.hasBegunApplicationShutdown,
          self.runHistoryBrowseGeneration == generation
        else {
          return
        }
        try self.validateRunHistoryPage(
          page,
          expectedScope: locator.scope,
          expectedContentAccess: locator.contentAccess
        )
        self.runHistoryBrowseTask = nil
        self.runHistoryPage = page
        self.runHistoryCurrentPageLocator = locator.stabilized(with: page)
        self.runHistoryNewerPageLocators = newerLocators
        self.runHistoryBrowseLoadState = .loaded
        self.isRunHistoryPageTransitioning = false
        self.runHistoryPaginationFailed = false
        if clearsNewerNotice {
          self.runHistoryHasNewerEntries = false
          self.runHistoryDeepLinkState = .idle
        }
      } catch is CancellationError {
        return
      } catch {
        guard let self,
          self.runHistoryBrowseGeneration == generation
        else {
          return
        }
        self.runHistoryBrowseTask = nil
        self.isRunHistoryPageTransitioning = false
        if hadPage {
          self.runHistoryPaginationFailed = true
        } else {
          self.runHistoryBrowseLoadState = .failed(.repositoryUnavailable)
        }
      }
    }
    runHistoryBrowseTask = task
  }

  private func validateRunHistoryPage(
    _ page: RunHistoryPage,
    expectedScope: RunHistoryBrowseScope,
    expectedContentAccess: RunHistoryContentAccess
  ) throws {
    guard page.entries.count <= Self.runHistoryPageSize else {
      throw RunHistoryPresentationError.invalidPageSize(page.entries.count)
    }
    guard page.session.scope == expectedScope,
      page.session.contentAccess == expectedContentAccess
    else {
      throw RunHistoryPresentationError.inconsistentSession
    }
  }
}

extension RunHistoryPageLocator {
  fileprivate var scope: RunHistoryBrowseScope {
    switch self {
    case .request(.first(let scope, _, _, _)):
      scope
    case .request(.next(let cursor, _)):
      cursor.session.scope
    case .snapshotAnchor(_, let session), .deepLinkAnchor(_, let session):
      session.scope
    }
  }

  fileprivate var contentAccess: RunHistoryContentAccess {
    switch self {
    case .request(.first(_, _, let contentAccess, _)):
      contentAccess
    case .request(.next(let cursor, _)):
      cursor.session.contentAccess
    case .snapshotAnchor(_, let session), .deepLinkAnchor(_, let session):
      session.contentAccess
    }
  }

  fileprivate var returnsToNewest: Bool {
    if case .deepLinkAnchor = self { return true }
    return false
  }

  fileprivate func stabilized(with page: RunHistoryPage) -> Self {
    guard case .request(.first(_, _, _, _)) = self,
      let firstEntryID = page.entries.first?.id
    else {
      return self
    }
    return .snapshotAnchor(
      entryID: firstEntryID,
      session: page.session
    )
  }
}


public enum RecordHistoryVisibility: String, CaseIterable, Identifiable, Sendable, Equatable {
  case remainingOnly = "remaining-only"
  case all = "all"

  public var id: String { rawValue }
}


actor DiagnosticEventRelay {
  let flushInterval: Duration
  let deliver: @Sendable ([DiagnosticEvent]) async -> Void

  var bufferedEvents: [DiagnosticEvent] = []
  var flushTask: Task<Void, Never>?

  init(
    flushInterval: Duration = .milliseconds(40),
    deliver: @escaping @Sendable ([DiagnosticEvent]) async -> Void
  ) {
    self.flushInterval = flushInterval
    self.deliver = deliver
  }

  func enqueue(_ event: DiagnosticEvent) {
    bufferedEvents.append(event)
    guard flushTask == nil else { return }
    let flushInterval = self.flushInterval
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: flushInterval)
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  func cancel() {
    flushTask?.cancel()
    flushTask = nil
    bufferedEvents = []
  }

  func drain() async {
    flushTask?.cancel()
    flushTask = nil
    let batch = bufferedEvents
    bufferedEvents = []
    guard !batch.isEmpty else { return }
    await deliver(batch)
  }

  private func flush() async {
    flushTask = nil
    let batch = bufferedEvents
    bufferedEvents = []
    guard !batch.isEmpty else { return }
    await deliver(batch)
  }
}
