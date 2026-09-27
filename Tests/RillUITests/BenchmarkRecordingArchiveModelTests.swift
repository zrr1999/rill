import Foundation
import RillCore
import Testing
@testable import RillUI

@MainActor
struct BenchmarkRecordingArchiveModelTests {
  @Test func closingAndReopeningWaitsForOldReadAndClearsExportAuthorization() async throws {
    let reader = SelectionReadGate()
    let exporter = SelectionExportProbe()
    let model = makeModel(reader: reader, exporter: exporter)
    model.loadSelection()
    await reader.waitForRead()
    model.selection = [reader.id]
    model.evidenceKind = .microphone
    model.authorizesPlaintextExport = true
    model.cancelSelection()
    model.loadSelection()
    #expect(model.selection.isEmpty)
    #expect(!model.authorizesPlaintextExport)
    #expect(model.evidenceKind == nil)
    await reader.release()
    await model.waitForOperation()
    #expect(model.receipts.map(\.runID) == [reader.id])
    #expect(model.state == .selecting)
    #expect(!model.canExport)
  }

  @Test func exportRequiresSelectionSourceAndConsentAndFreezesTheSelection() async throws {
    let reader = SelectionReadGate(blocks: false)
    let exporter = SelectionExportProbe()
    let model = makeModel(reader: reader, exporter: exporter)
    model.loadSelection()
    await model.waitForOperation()
    let target = URL(fileURLWithPath: "/private/var/tmp/rill-export-test")
    model.exportSelection(to: target)
    #expect(await exporter.selection == nil)
    model.selection = [reader.id]
    model.evidenceKind = .synthetic
    model.exportSelection(to: target)
    #expect(await exporter.selection == nil)
    model.authorizesPlaintextExport = true
    model.exportSelection(to: target)
    model.selection = []
    model.evidenceKind = .publicFixture
    await exporter.waitForExport()
    #expect(await exporter.selection == .init(runIDs: [reader.id], evidenceKind: .synthetic, split: .development))
    model.cancelSelection()
    await exporter.complete(.cleanupPending(target))
    await model.waitForOperation()
    #expect(model.cleanupPendingURLs == [target])
    model.loadSelection()
    await model.waitForOperation()
    #expect(model.cleanupPendingURLs == [target])
    #expect(!model.authorizesPlaintextExport)
  }

  private func makeModel(reader: SelectionReadGate, exporter: SelectionExportProbe) -> BenchmarkRecordingArchiveModel {
    let store = UITestSettingsStore()
    let settings = SettingsPersistenceModel(store: store, language: .english, verifyOpenAIConfiguration: { _ in }, configurationChanged: {})
    settings.isLoading = false
    return BenchmarkRecordingArchiveModel(settings: settings, store: store,
      reader: reader, exporter: exporter, refresh: { _ in }, clear: {})
  }
}

private actor SelectionReadGate: BenchmarkRecordingArchiveReading {
  nonisolated let id = UUID()
  private var blocks: Bool
  private var entered = false
  private var waiting: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  init(blocks: Bool = true) { self.blocks = blocks }
  func recordingIDs() async throws -> [UUID] { [id] }
  func receipt(runID: UUID) async throws -> BenchmarkRecordingReceipt {
    if blocks {
      blocks = false
      entered = true
      observers.forEach { $0.resume() }; observers = []
      await withCheckedContinuation { waiting = $0 }
    }
    return .init(runID: id, workflowID: UUID(), createdAt: Date(), durationSeconds: 1,
      format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16), plaintextByteCount: 2,
      trigger: .hotkey, outcome: .completed, metadata: [:])
  }
  func recording(runID: UUID) async throws -> BenchmarkRecording { throw BenchmarkRecordingArchiveError.invalidEntry }
  func waitForRead() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() { waiting?.resume(); waiting = nil }
}

private actor SelectionExportProbe: BenchmarkCorpusExporting {
  private(set) var selection: BenchmarkCorpusSelection?
  private var waiting: CheckedContinuation<URL, Error>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func export(_ selection: BenchmarkCorpusSelection, to directory: URL) async throws -> URL {
    self.selection = selection
    observers.forEach { $0.resume() }; observers = []
    return try await withCheckedThrowingContinuation { waiting = $0 }
  }
  func waitForExport() async {
    if selection != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func complete(_ error: BenchmarkCorpusExportError) { waiting?.resume(throwing: error); waiting = nil }
}
