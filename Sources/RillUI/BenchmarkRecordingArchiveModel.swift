import Foundation
import Observation
import RillCore

@MainActor @Observable
public final class BenchmarkRecordingArchiveModel {
  public private(set) var isEnabled = false
  public private(set) var isUpdating = false
  public private(set) var receipts: [BenchmarkRecordingReceipt] = []
  public var selection: Set<UUID> = []
  public var evidenceKind: BenchmarkEvidenceKind?
  public var split: BenchmarkCorpusSplit = .development
  public var authorizesPlaintextExport = false
  public private(set) var state: State = .idle
  public private(set) var lastExportedURL: URL?
  public private(set) var cleanupPendingURLs: [URL] = []
  private var operationID = UUID()
  private var errorKey: RunStatusTextKey?
  private let settings: SettingsPersistenceModel
  private let store: (any SettingsStore)?
  private let reader: (any BenchmarkRecordingArchiveReading)?
  private let exporter: (any BenchmarkCorpusExporting)?
  private let refreshAction: @Sendable (Bool) async throws -> Void
  private let clearAction: @Sendable () async throws -> Void
  private var operation: Task<Void, Never>?
  private var shuttingDown = false

  public enum State: Equatable {
    case idle, loading, selecting, exporting
  }

  public var error: String? { errorKey.map { L10n.runText($0, language: settings.language) } }
  public var canExport: Bool {
    !shuttingDown && !isUpdating && operation == nil && state != .loading && state != .exporting
      && !selection.isEmpty && selection.isSubset(of: Set(receipts.map(\.runID)))
      && evidenceKind != nil && authorizesPlaintextExport && exporter != nil
  }

  init(settings: SettingsPersistenceModel, store: (any SettingsStore)?,
    reader: (any BenchmarkRecordingArchiveReading)?, exporter: (any BenchmarkCorpusExporting)?,
    refresh: @escaping @Sendable (Bool) async throws -> Void,
    clear: @escaping @Sendable () async throws -> Void) {
    self.settings = settings
    self.store = store
    self.reader = reader
    self.exporter = exporter
    refreshAction = refresh
    clearAction = clear
  }

  func applyStored(_ value: String?, available: Bool) {
    isEnabled = available && value == "true"
    if available && ![nil, "", "true", "false"].contains(value) {
      errorKey = .benchmarkSettingInvalid
    }
  }

  public func setEnabled(_ enabled: Bool) {
    guard !shuttingDown, !settings.isLoading, enabled != isEnabled, !isUpdating else { return }
    guard let store else { errorKey = .benchmarkStorageUnavailable; return }
    isUpdating = true
    errorKey = nil
    let task = Task { [self] in
      defer { isUpdating = false }
      do {
        try await store.setString(enabled ? "true" : "false", forKey: .benchmarkRecordingArchiveEnabled)
        isEnabled = enabled
        do {
          try await refreshAction(enabled)
        } catch {
          if enabled {
            try? await refreshAction(false)
            do {
              try await store.setString("false", forKey: .benchmarkRecordingArchiveEnabled)
              isEnabled = false
            } catch {
              errorKey = .benchmarkEnabledStorageUnavailable
              return
            }
          }
          errorKey = .benchmarkRetentionUpdateFailed
        }
      } catch {
        errorKey = .benchmarkRetentionUpdateFailed
      }
    }
    settings.writes.track(task)
  }

  public func clear() {
    guard !shuttingDown, !isUpdating, state != .exporting else { return }
    cancelSelection()
    isUpdating = true
    errorKey = nil
    let task = Task { [self] in
      defer { isUpdating = false }
      do {
        try await clearAction()
        receipts = []
        selection = []
      } catch { errorKey = .benchmarkClearFailed }
    }
    settings.writes.track(task)
  }

  public func loadSelection() {
    guard !shuttingDown, !isUpdating else { return }
    let previous = operation
    previous?.cancel()
    let id = UUID()
    operationID = id
    authorizesPlaintextExport = false
    evidenceKind = nil
    selection = []
    receipts = []
    state = .loading
    errorKey = nil
    operation = Task { [self] in
      defer { if operationID == id { operation = nil } }
      await previous?.value
      do {
        try Task.checkCancellation()
        guard let reader else { throw BenchmarkRecordingArchiveError.storageUnavailable }
        var loaded: [BenchmarkRecordingReceipt] = []
        for id in try await reader.recordingIDs() {
          try Task.checkCancellation()
          loaded.append(try await reader.receipt(runID: id))
        }
        try Task.checkCancellation()
        guard operationID == id else { return }
        receipts = loaded.sorted { $0.createdAt > $1.createdAt }
        state = .selecting
      } catch is CancellationError {
        if operationID == id { state = .idle }
      } catch {
        guard operationID == id else { return }
        state = .selecting
        errorKey = .benchmarkReadFailed
      }
    }
  }

  public func exportSelection(to directory: URL) {
    guard canExport, let evidenceKind, let exporter else { return }
    let selected = BenchmarkCorpusSelection(runIDs: selection.sorted { $0.uuidString < $1.uuidString },
      evidenceKind: evidenceKind, split: split)
    let id = UUID()
    operationID = id
    state = .exporting
    errorKey = nil
    operation = Task { [self] in
      defer { if operationID == id { operation = nil } }
      do {
        let url = try await exporter.export(selected, to: directory)
        // A committed export remains discoverable even if its sheet closed meanwhile.
        lastExportedURL = url
        if operationID == id { state = .selecting }
      } catch BenchmarkCorpusExportError.cleanupPending(let url) {
        if !cleanupPendingURLs.contains(url) { cleanupPendingURLs.append(url) }
        if operationID == id { state = .selecting }
      } catch is CancellationError {
        if operationID == id { state = .idle }
      } catch {
        guard operationID == id else { return }
        state = .selecting
        errorKey = .benchmarkExportFailed
      }
    }
  }

  public func cancelSelection() {
    authorizesPlaintextExport = false
    evidenceKind = nil
    operation?.cancel()
  }
  func waitForOperation() async { await operation?.value }
  func beginShutdown() { shuttingDown = true; cancelSelection() }
}
