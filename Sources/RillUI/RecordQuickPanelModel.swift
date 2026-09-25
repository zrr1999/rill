import RillRecords
import Foundation
import Observation
import RillCore

@MainActor @Observable
public final class RecordCleanupModel {
  public private(set) var plan: RecordCleanupPlan?
  public private(set) var isWorking = false
  public private(set) var message: QuickRecordText?
  private let store: RecordStore
  private var pendingCommit: Task<RecordCleanupResult, Error>?
  private var isClosed = false

  public init(store: RecordStore) { self.store = store }

  public func request(olderThan cutoff: Date = .distantFuture) async {
    await request(scope: .history(olderThan: cutoff))
  }

  public func request(scope: RecordCleanupScope) async {
    guard !isWorking, !isClosed else { return }
    plan = nil
    isWorking = true
    defer { isWorking = false }
    do {
      plan = try await store.prepareCleanup(scope: scope)
      message = nil
    } catch RecordStoreError.membershipAlreadyInUse {
      message = .recordInUse
    } catch { message = .failed }
  }

  public func confirm() async {
    guard !isWorking, !isClosed, let plan else { return }
    isWorking = true
    let task = Task { [store] in try await store.confirmCleanup(plan) }
    pendingCommit = task
    defer {
      isWorking = false
      pendingCommit = nil
    }
    do {
      _ = try await task.value
      self.plan = nil
      message = nil
    } catch RecordStoreError.membershipChanged {
      do {
        self.plan = try await store.refreshCleanupPlan(plan)
        message = .cleanupChanged
      } catch {
        self.plan = nil
        message = .cleanupChanged
      }
    } catch { message = .failed }
  }

  public func seal() {
    isClosed = true
  }

  public func shutdown() async {
    seal()
    _ = await pendingCommit?.result
  }

  public func cancel() {
    guard !isWorking else { return }
    plan = nil
    message = nil
  }
}

public enum RecordSemanticPanelState: Equatable {
  case idle, working, needsModel, ready, failed, changed, invalidQuery
}

@MainActor @Observable
public final class RecordQuickPanelModel {
  public var pasteTargetName: String?

  public var searchText = "" { didSet { if oldValue != searchText { scheduleSearch() } } }
  public var pinnedOnly = false { didSet { if oldValue != pinnedOnly { scheduleSearch() } } }
  public var currentAppOnly = false {
    didSet { if oldValue != currentAppOnly { scheduleSearch() } }
  }
  public var kind: RecordPayloadKind? { didSet { if oldValue != kind { scheduleSearch() } } }
  public var selectedID: RecordID? { didSet { if selectedID != oldValue { loadPreview() } } }
  public private(set) var results: [RecordSummary] = []
  public private(set) var capacity = RecordCapacity(count: 0, byteCount: 0)
  public private(set) var isSearching = false
  public private(set) var isPreviewVisible = false
  public private(set) var isLoadingPreview = false
  public private(set) var preview: RecordProjection?
  public private(set) var message: QuickRecordText?
  public private(set) var nextOffset: Int?
  public let cleanup: RecordCleanupModel
  public let jev: RecordJevPanelModel?
  public private(set) var semanticResults: [RecordSummary] = []
  public private(set) var semanticState: RecordSemanticPanelState = .idle
  public private(set) var semanticProgress: RecordSemanticSearchProgress?
  public private(set) var semanticLimitedRecordCount = 0
  private let semanticSearch: RecordSemanticSearch?
  private var semanticRequestID: UUID?
  private var semanticTasks: [UUID: Task<Void, Never>] = [:]
  private let store: RecordStore
  private var sourceBundleIdentifier: String?
  private var observationTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var pinTask: Task<RecordMetadata, Error>?
  private var isClosed = false
  private var searchGeneration: UInt64 = 0
  private var pendingComparison: RecordComparisonReturn?
  private var searchRevision: UInt64?
  private var searchCursor: RecordSearchCursor?

  public init(store: RecordStore, semanticSearch: RecordSemanticSearch? = nil, jevSettings: JevAPISettingsModel? = nil) {
    self.store = store
    self.semanticSearch = semanticSearch
    jev = jevSettings.map { RecordJevPanelModel(settings: $0) }
    cleanup = RecordCleanupModel(store: store)
  }
  isolated deinit {
    observationTask?.cancel()
    searchTask?.cancel()
    previewTask?.cancel()
    for task in semanticTasks.values { task.cancel() }
  }

  public func start(sourceBundleIdentifier: String?) {
    stop()
    self.sourceBundleIdentifier = sourceBundleIdentifier
    searchText = ""
    pinnedOnly = false
    currentAppOnly = false
    kind = nil
    selectedID = nil
    results = []
    searchRevision = nil
    preview = nil
    message = nil
    resume()
  }

  public func resume() {
    scheduleSearch()
    observationTask?.cancel()
    observationTask = Task { [weak self, store] in
      do {
        let stream = try await store.catalogStream()
        for await snapshot in stream {
          guard !Task.isCancelled, let self else { return }
          self.receiveCatalogSnapshot(snapshot)
        }
      } catch { self?.message = .failed }
    }
  }

  func receiveCatalogSnapshot(_ snapshot: RecordCatalogSnapshot) {
    guard !isClosed else { return }
    capacity = snapshot.capacity
    // The initial stream snapshot may arrive after a query has already published.
    if searchRevision.map({ snapshot.revision > $0 }) ?? true { scheduleSearch() }
  }

  public func stop() {
    pendingComparison = nil
    cancelSemanticSearch()
    observationTask?.cancel()
    observationTask = nil
    searchTask?.cancel()
    searchTask = nil
    previewTask?.cancel()
    previewTask = nil
    searchGeneration &+= 1
    preview = nil
    isLoadingPreview = false
    isPreviewVisible = false
    isSearching = false
  }

  public func shutdown() async {
    isClosed = true
    stop()
    await jev?.shutdown()
    cleanup.seal()
    let pendingSemanticTasks = Array(semanticTasks.values)
    for task in pendingSemanticTasks { await task.value }
    _ = await pinTask?.result
    await cleanup.shutdown()
  }

  public var canFilterCurrentApp: Bool { sourceBundleIdentifier != nil }
  public var canSearchByMeaning: Bool {
    semanticSearch != nil && kind != .image && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  public var additionalSemanticResults: [RecordSummary] {
    let existing = Set(results.map(\.id))
    return semanticResults.filter { !existing.contains($0.id) }
  }
  public var selectableResults: [RecordSummary] { results + additionalSemanticResults }
  public var selectedRecord: RecordSummary? { selectableResults.first { $0.id == selectedID } }

  public func cancelSemanticSearch() {
    jev?.invalidate()
    semanticRequestID = nil
    for task in semanticTasks.values { task.cancel() }
    semanticResults = []
    semanticState = .idle
    semanticProgress = nil
    semanticLimitedRecordCount = 0
    if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
  }

  public func searchByMeaning(downloadIfNeeded: Bool = false) {
    guard !isClosed, !isSearching, semanticState != .working, canSearchByMeaning,
      let semanticSearch else { return }
    cancelSemanticSearch()
    let requestID = UUID()
    semanticRequestID = requestID
    semanticState = .working
    semanticProgress = .preparing(0)
    let query = RecordQuery(text: searchText,
      sourceBundleIdentifier: currentAppOnly ? sourceBundleIdentifier : nil,
      kind: kind, pinnedOnly: pinnedOnly)
    semanticTasks[requestID] = Task { [weak self] in
      defer { self?.semanticTasks.removeValue(forKey: requestID) }
      do {
        let result = try await semanticSearch.search(query, downloadIfNeeded: downloadIfNeeded) { [weak self] progress in
          Task { @MainActor [weak self] in
            guard let self, self.semanticRequestID == requestID, self.semanticState == .working else { return }
            self.semanticProgress = progress
          }
        }
        guard !Task.isCancelled, let self, self.semanticRequestID == requestID else { return }
        self.semanticResults = result.records
        self.semanticLimitedRecordCount = result.limitedRecordCount
        self.semanticState = .ready
        self.semanticProgress = nil
        if self.selectedID == nil { self.selectedID = self.selectableResults.first?.id }
      } catch {
        guard !Task.isCancelled, let self, self.semanticRequestID == requestID else { return }
        switch error {
        case RecordEmbeddingError.modelUnavailable: self.semanticState = .needsModel
        case RecordEmbeddingError.invalidInput: self.semanticState = .invalidQuery
        case RecordStoreError.membershipChanged: self.semanticState = .changed
        default: self.semanticState = .failed
        }
        self.semanticProgress = nil
      }
    }
  }
  public func subject(at index: Int) -> RecordReuseSubject? {
    let items = selectableResults
    guard items.indices.contains(index) else { return nil }
    return items[index].reuseSubject
  }

  public func moveSelection(_ offset: Int) {
    let results = selectableResults
    guard !results.isEmpty else {
      selectedID = nil
      return
    }
    let index =
      selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : 0)
    selectedID = results[min(max(index + offset, 0), results.count - 1)].id
  }

  public func togglePreview() {
    if isPreviewVisible {
      closePreview()
    } else {
      isPreviewVisible = true
      loadPreview()
    }
  }

  private func loadPreview() {
    previewTask?.cancel()
    previewTask = nil
    isLoadingPreview = false
    guard !isClosed, isPreviewVisible, let subject = selectedRecord?.reuseSubject else {
      preview = nil
      return
    }
    if preview?.id == subject.recordID, preview?.metadata.revision == subject.metadataRevision { return }
    preview = nil
    isLoadingPreview = true
    previewTask = Task { [weak self, store] in
      defer { if !Task.isCancelled { self?.isLoadingPreview = false } }
      do {
        let record = try await store.record(id: subject.recordID)
        guard !Task.isCancelled, self?.selectedRecord?.reuseSubject == subject else { return }
        self?.preview = record
      } catch {
        guard !Task.isCancelled, self?.selectedRecord?.reuseSubject == subject else { return }
        self?.message = .recordUnavailable
      }
    }
  }

  public func closePreview() {
    isPreviewVisible = false
    isLoadingPreview = false
    previewTask?.cancel()
    previewTask = nil
    preview = nil
  }

  public func togglePin(_ item: RecordSummary) async {
    guard !isClosed, pinTask == nil else { return }
    let task = Task { [store] in
      try await store.updateMetadata(
        recordID: item.id, isPinned: !item.metadata.isPinned,
        expectedRevision: item.metadata.revision)
    }
    pinTask = task
    defer { pinTask = nil }
    do {
      _ = try await task.value
    } catch { message = .failed }
  }

  public func report(_ result: RecordReuseOutcome) {
    message = result.feedback
  }

  public func loadMore() {
    guard let nextOffset, !isSearching else { return }
    scheduleSearch(offset: nextOffset)
  }

  public var canCompareWithJev: Bool {
    jev != nil && !isSearching && semanticState != .working && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && selectableResults.contains { $0.header.kind != .image }
  }

  public func compareWithJev() {
    guard !isClosed, canCompareWithJev else { return }
    var ids: [RecordID] = []
    for index in 0..<max(results.count, semanticResults.count) {
      for list in [results, semanticResults] where list.indices.contains(index) {
        let item = list[index]
        if item.header.kind != .image && !ids.contains(item.id) { ids.append(item.id) }
      }
      if ids.count >= 10 { break }
    }
    jev?.prepare(query: searchText, recordIDs: Array(ids.prefix(10)))
  }

  public func comparisonReturnContext() -> RecordComparisonReturn? {
    guard let jev, !jev.candidateIDs.isEmpty, !jev.isWorking else { return nil }
    return RecordComparisonReturn(query: jev.query, resultLimit: results.count, candidateIDs: jev.candidateIDs,
      semanticIDs: semanticResults.map(\.id), selectedID: selectedID,
      sourceBundleIdentifier: sourceBundleIdentifier, currentAppOnly: currentAppOnly,
      kind: kind, pinnedOnly: pinnedOnly)
  }

  public func restoreComparison(_ context: RecordComparisonReturn) {
    sourceBundleIdentifier = context.sourceBundleIdentifier
    currentAppOnly = context.currentAppOnly
    kind = context.kind
    pinnedOnly = context.pinnedOnly
    searchText = context.query
    selectedID = context.selectedID
    pendingComparison = context
    scheduleSearch()
  }

  public func selectJevCandidate(_ id: RecordID) {
    guard !isClosed, selectableResults.contains(where: { $0.id == id }) else { return }
    selectedID = id
  }

  private func scheduleSearch(offset: Int = 0) {
    guard !isClosed else { return }
    if let context = pendingComparison,
      context.query != searchText || context.kind != kind || context.pinnedOnly != pinnedOnly
        || context.currentAppOnly != currentAppOnly {
      pendingComparison = nil
    }
    if offset == 0 {
      cancelSemanticSearch()
      previewTask?.cancel()
      isLoadingPreview = false
    }
    if message == .copied { message = nil }
    searchTask?.cancel()
    searchGeneration &+= 1
    let generation = searchGeneration
    let query = RecordQuery(
      text: searchText, sourceBundleIdentifier: currentAppOnly ? sourceBundleIdentifier : nil,
      kind: kind, pinnedOnly: pinnedOnly)
    let cursor = offset == 0 ? nil : searchCursor
    let pageLimit = max(50, pendingComparison?.resultLimit ?? 50)
    isSearching = true
    searchTask = Task { [weak self, store] in
      do {
        let page = try await RecordSearch.page(in: store, query: query, after: cursor, limit: pageLimit)
        guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
        if offset == 0 { self.results = page.records } else { self.results += page.records }
        self.nextOffset = page.nextOffset
        self.searchCursor = page.cursor
        self.searchRevision = page.revision
        if !self.selectableResults.contains(where: { $0.id == self.selectedID }) {
          self.selectedID = self.selectableResults.first?.id
        }
        if let context = self.pendingComparison {
          let snapshot = try await store.catalogSnapshot()
          guard !Task.isCancelled, self.searchGeneration == generation else { return }
          self.pendingComparison = nil
          let available = snapshot.records.filter { record in
            (context.candidateIDs.contains(record.id) || context.semanticIDs.contains(record.id))
              && (!context.currentAppOnly || record.header.provenance.sourceBundleIdentifier == context.sourceBundleIdentifier)
              && (context.kind == nil || record.header.kind == context.kind)
              && (!context.pinnedOnly || record.metadata.isPinned)
          }
          let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
          let candidates = context.candidateIDs.compactMap { byID[$0] }
          self.semanticResults = context.semanticIDs.compactMap { byID[$0] }
          self.semanticState = self.semanticResults.isEmpty ? .idle : .ready
          if self.selectableResults.contains(where: { $0.id == context.selectedID }) { self.selectedID = context.selectedID }
          if candidates.count == context.candidateIDs.count {
            self.jev?.prepare(query: context.query, recordIDs: context.candidateIDs)
          } else {
            self.jev?.showChangedCandidates(query: context.query, recordIDs: candidates.map(\.id))
          }
        }
        self.isSearching = false
        self.loadPreview()
      } catch is CancellationError {
      } catch RecordStoreError.membershipChanged {
        guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
        self.scheduleSearch()
      } catch {
        guard let self, self.searchGeneration == generation else { return }
        self.isSearching = false
        self.message = .failed
      }
    }
  }
}
