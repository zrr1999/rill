import CryptoKit
import Foundation
import RillCore
import Testing
@testable import RillPlatform

struct BenchmarkCorpusExporterTests {
  @Test func exportsOnlyExplicitSelectionWithNoInventedReferences() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let selected = try await fixture.preserve()
    _ = try await fixture.preserve()
    let directory = try await BenchmarkCorpusExporter(archive: fixture.archive).export(
      .init(runIDs: [selected], evidenceKind: .synthetic, split: .validation), to: fixture.exports)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(Set(files) == [selected.uuidString + ".wav", "README.txt", "corpus.json"])
    #expect(try mode(directory) == 0o700)
    for file in files { #expect(try mode(directory.appendingPathComponent(file)) == 0o600) }
    let manifest = try #require(JSONSerialization.jsonObject(with:
      Data(contentsOf: directory.appendingPathComponent("corpus.json"))) as? [String: Any])
    #expect(manifest["evidence_kind"] as? String == "synthetic")
    let entry = try #require((manifest["cases"] as? [[String: Any]])?.first)
    #expect(entry["split"] as? String == "validation")
    #expect(entry["consent"] as? String == "authorized")
    #expect((entry["references"] as? [String: String])?.isEmpty == true)
    #expect(entry["audio_sha256"] as? String == SHA256.hash(data: fixture.audioBytes).map { String(format: "%02x", $0) }.joined())
    #expect(try Data(contentsOf: directory.appendingPathComponent(selected.uuidString + ".wav")) == fixture.audioBytes)
    #expect(try await fixture.archive.recordingIDs().count == 2)
  }

  @Test func failedAuthenticationRemovesEveryPartialPlaintextFile() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try await fixture.preserve()
    let damaged = try await fixture.preserve()
    try Data("tampered".utf8).write(to: await fixture.archive.directoryURL.appendingPathComponent(damaged.uuidString + ".rillaudio"))
    // Listing metadata must not open or trust the damaged audio.
    #expect(try await fixture.archive.receipt(runID: damaged).runID == damaged)
    await #expect(throws: BenchmarkRecordingArchiveError.invalidEntry) {
      _ = try await BenchmarkCorpusExporter(archive: fixture.archive).export(
        .init(runIDs: [first, damaged], evidenceKind: .synthetic, split: .development), to: fixture.exports)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path).isEmpty)
  }

  @Test func failedCleanupReportsTheExactRemainingDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try await fixture.preserve()
    let missing = UUID()
    let exporter = BenchmarkCorpusExporter(archive: fixture.archive, removeEntry: { _, _, _ in false })
    do {
      _ = try await exporter.export(.init(runIDs: [first, missing], evidenceKind: .synthetic, split: .development), to: fixture.exports)
      Issue.record("Missing recording must fail")
    } catch BenchmarkCorpusExportError.cleanupPending(let url) {
      #expect(url.deletingLastPathComponent().standardizedFileURL.path == fixture.exports.resolvingSymlinksInPath().standardizedFileURL.path)
      #expect(try Data(contentsOf: url.appendingPathComponent(first.uuidString + ".wav")) == fixture.audioBytes)
    }
  }

  @Test func cancellationDuringReadRemovesPreviouslyDecryptedFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try await fixture.preserve()
    let delayed = try await fixture.preserve()
    let gate = ReadGate(archive: fixture.archive, delayed: delayed)
    let task = Task {
      try await BenchmarkCorpusExporter(archive: gate).export(
        .init(runIDs: [first, delayed], evidenceKind: .synthetic, split: .development), to: fixture.exports)
    }
    await gate.waitUntilReading()
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path).isEmpty)
  }

  private func mode(_ url: URL) throws -> Int {
    let value = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
  }

  private struct Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archive: EncryptedBenchmarkRecordingArchiveStore
    let exports: URL
    let audioBytes = Data([0, 1, 2, 3])
    init() throws {
      exports = directory.appendingPathComponent("exports")
      try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
      archive = try EncryptedBenchmarkRecordingArchiveStore(directoryURL: directory.appendingPathComponent("encrypted"),
        localDataProtector: AESGCMDataProtector(key: Data(repeating: 7, count: AESGCMDataProtector.keyByteCount)))
    }
    func preserve() async throws -> UUID {
      let id = UUID()
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("rill-benchmark-test-" + id.uuidString + ".wav")
      try audioBytes.write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      let audio = try CapturedAudio(durationSeconds: 1, format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16), fileURL: url, fileOwnership: .managedTemporary)
      _ = try await archive.preserve(audio: audio, runID: id, workflowID: UUID(), trigger: .hotkey,
        outcome: .completed, metadata: ["private": "not exported"], now: Date())
      return id
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
  }
}

private actor ReadGate: BenchmarkRecordingArchiveReading {
  let archive: EncryptedBenchmarkRecordingArchiveStore
  let delayed: UUID
  var waiting: CheckedContinuation<Void, Never>?
  var entered = false
  var observers: [CheckedContinuation<Void, Never>] = []
  init(archive: EncryptedBenchmarkRecordingArchiveStore, delayed: UUID) { self.archive = archive; self.delayed = delayed }
  func recordingIDs() async throws -> [UUID] { try await archive.recordingIDs() }
  func receipt(runID: UUID) async throws -> BenchmarkRecordingReceipt { try await archive.receipt(runID: runID) }
  func recording(runID: UUID) async throws -> BenchmarkRecording {
    if runID == delayed {
      entered = true
      observers.forEach { $0.resume() }; observers = []
      await withCheckedContinuation { waiting = $0 }
    }
    return try await archive.recording(runID: runID)
  }
  func waitUntilReading() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() { waiting?.resume(); waiting = nil }
}
