import Foundation
import Observation
import RillCore
import RillRuntime

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

@MainActor @Observable
public final class RecordQuickPanelModel {
  public var pasteTargetName: String?

  public var searchText = "" { didSet { if oldValue != searchText { scheduleSearch() } } }
  public var pinnedOnly = false { didSet { if oldValue != pinnedOnly { scheduleSearch() } } }
  public var currentAppOnly = false {
    didSet { if oldValue != currentAppOnly { scheduleSearch() } }
  }
  public var kind: RecordPayloadKind? { didSet { if oldValue != kind { scheduleSearch() } } }
  public var selectedID: RecordID? { didSet { if selectedID != oldValue { closePreview() } } }
  public private(set) var results: [RecordSummary] = []
  public private(set) var capacity = RecordCapacity(count: 0, byteCount: 0)
  public private(set) var isSearching = false
  public private(set) var preview: RecordProjection?
  public private(set) var message: QuickRecordText?
  public private(set) var nextOffset: Int?
  public let cleanup: RecordCleanupModel
  private let store: RecordStore
  private var sourceBundleIdentifier: String?
  private var observationTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var pinTask: Task<RecordMetadata, Error>?
  private var isClosed = false
  private var searchGeneration: UInt64 = 0

  public init(store: RecordStore) {
    self.store = store
    cleanup = RecordCleanupModel(store: store)
  }
  isolated deinit {
    observationTask?.cancel()
    searchTask?.cancel()
    previewTask?.cancel()
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
    preview = nil
    message = nil
    resume()
  }

  public func resume() {
    isSearching = true
    observationTask?.cancel()
    observationTask = Task { [weak self, store] in
      do {
        let stream = try await store.catalogStream()
        for await snapshot in stream {
          guard !Task.isCancelled, let self else { return }
          self.capacity = snapshot.capacity
          self.scheduleSearch()
        }
      } catch { self?.message = .failed }
    }
  }

  public func stop() {
    observationTask?.cancel()
    observationTask = nil
    searchTask?.cancel()
    searchTask = nil
    previewTask?.cancel()
    previewTask = nil
    searchGeneration &+= 1
    preview = nil
    isSearching = false
  }

  public func shutdown() async {
    isClosed = true
    stop()
    cleanup.seal()
    _ = await pinTask?.result
    await cleanup.shutdown()
  }

  public var canFilterCurrentApp: Bool { sourceBundleIdentifier != nil }
  public var selectedRecord: RecordSummary? { results.first { $0.id == selectedID } }
  public func subject(at index: Int) -> RecordReuseSubject? {
    guard results.indices.contains(index) else { return nil }
    return results[index].reuseSubject
  }

  public func moveSelection(_ offset: Int) {
    guard !results.isEmpty else {
      selectedID = nil
      return
    }
    let index =
      selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : 0)
    selectedID = results[min(max(index + offset, 0), results.count - 1)].id
  }

  public func togglePreview() {
    if preview != nil {
      closePreview()
      return
    }
    guard let subject = selectedRecord?.reuseSubject else { return }
    previewTask?.cancel()
    previewTask = Task { [weak self, store] in
      do {
        let record = try await store.record(id: subject.recordID)
        guard !Task.isCancelled, self?.selectedRecord?.reuseSubject == subject else { return }
        self?.preview = record
      } catch { self?.message = .failed }
    }
  }

  public func closePreview() {
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

  private func scheduleSearch(offset: Int = 0) {
    if message == .copied { message = nil }
    searchTask?.cancel()
    searchGeneration &+= 1
    let generation = searchGeneration
    let query = RecordQuery(
      text: searchText, sourceBundleIdentifier: currentAppOnly ? sourceBundleIdentifier : nil,
      kind: kind, pinnedOnly: pinnedOnly)
    isSearching = true
    searchTask = Task { [weak self, store] in
      do {
        var scanOffset = offset
        var matches: [RecordSummary] = []
        repeat {
          let page = try await store.query(query, offset: scanOffset, limit: 50 - matches.count)
          guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
          matches += page.records
          if offset == 0 { self.results = matches }
          self.nextOffset = page.nextOffset
          if self.selectedID == nil { self.selectedID = self.results.first?.id }
          guard let next = page.nextOffset, matches.count < 50 else { break }
          scanOffset = next
        } while true
        guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
        if offset != 0 { self.results += matches }
        if !self.results.contains(where: { $0.id == self.selectedID }) {
          self.selectedID = self.results.first?.id
        }
        self.isSearching = false
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
