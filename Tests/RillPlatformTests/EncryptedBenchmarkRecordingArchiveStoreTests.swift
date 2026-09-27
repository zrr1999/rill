import Darwin
import Foundation
import XCTest

@testable import RillCore
@testable import RillPlatform

final class EncryptedBenchmarkRecordingArchiveStoreTests: XCTestCase {
  func testPreserveStoresOnlyEncryptedPrivateArtifacts() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let keyByte: UInt8 = 0x31
    let store = try makeStore(directoryURL: fixture.archiveDirectory, keyByte: keyByte)
    let audioBytes = Data("benchmark-audio-private-sentinel".utf8)
    let audio = try makeAudio(bytes: audioBytes)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let workflowID = UUID()

    let receipt = try await store.preserve(
      audio: audio,
      runID: runID,
      workflowID: workflowID,
      trigger: .hotkey,
      outcome: .completed,
      metadata: ["recognizerID": "local-speech"],
      now: Date(timeIntervalSince1970: 100)
    )

    XCTAssertEqual(receipt.runID, runID)
    XCTAssertEqual(receipt.workflowID, workflowID)
    XCTAssertEqual(receipt.plaintextByteCount, audioBytes.count)
    XCTAssertEqual(receipt.outcome, .completed)
    XCTAssertEqual(receipt.trigger, .hotkey)
    let identifiers = try await store.recordingIDs()
    XCTAssertEqual(identifiers, [runID])
    let reopened = try await store.recording(runID: runID)
    XCTAssertEqual(reopened.receipt, receipt)
    XCTAssertEqual(reopened.audioBytes, audioBytes)

    let archiveFiles = try ownedFiles(in: fixture.archiveDirectory)
    XCTAssertEqual(archiveFiles.count, 2)
    for file in archiveFiles {
      let storedBytes = try Data(contentsOf: file)
      XCTAssertNil(storedBytes.range(of: audioBytes))
      XCTAssertNil(storedBytes.range(of: Data(runID.uuidString.utf8)))
      let permissions = try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
          as? NSNumber
      ).intValue
      XCTAssertEqual(permissions & 0o777, 0o600)
    }
    let directoryPermissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(
        atPath: fixture.archiveDirectory.path
      )[.posixPermissions] as? NSNumber
    ).intValue
    XCTAssertEqual(directoryPermissions & 0o777, 0o700)
    XCTAssertEqual(
      try EncryptedBenchmarkRecordingArchiveStore.probeExistingDataProtectionKey(
        directoryURL: fixture.archiveDirectory,
        localDataProtector: makeProtector(keyByte: keyByte)
      ),
      .boundAndValid
    )
  }

  func testReplayReadRejectsTamperedAudioAndSymlinks() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.archiveDirectory, keyByte: 0x33)
    let audio = try makeAudio(bytes: Data([1, 2, 3]))
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    _ = try await store.preserve(audio: audio, runID: runID, workflowID: UUID(),
      trigger: .hotkey, outcome: .completed, metadata: [:], now: Date())
    let stored = fixture.archiveDirectory.appendingPathComponent(runID.uuidString + ".rillaudio")
    try Data("tampered".utf8).write(to: stored)
    do {
      _ = try await store.recording(runID: runID)
      XCTFail("Authenticated audio must be required")
    } catch { XCTAssertEqual(error as? BenchmarkRecordingArchiveError, .invalidEntry) }
    try FileManager.default.removeItem(at: stored)
    try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: try XCTUnwrap(audio.fileURL))
    do {
      _ = try await store.recording(runID: runID)
      XCTFail("Replay reads must not follow symbolic links")
    } catch { XCTAssertEqual(error as? BenchmarkRecordingArchiveError, .invalidEntry) }
  }

  func testWrongKeyCannotOpenExistingArchiveBinding() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    _ = try makeStore(directoryURL: fixture.archiveDirectory, keyByte: 0x41)

    XCTAssertThrowsError(
      try makeStore(directoryURL: fixture.archiveDirectory, keyByte: 0x42)
    ) {
      XCTAssertEqual($0 as? BenchmarkRecordingArchiveError, .invalidEntry)
    }
  }

  func testDeleteAllRemovesRecordingsButKeepsKeyBindingAndUnrelatedFiles() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.archiveDirectory, keyByte: 0x51)
    let audio = try makeAudio(bytes: Data([1, 2, 3, 4]))
    defer { _ = try? audio.removeManagedTemporaryFile() }
    _ = try await store.preserve(
      audio: audio,
      runID: UUID(),
      workflowID: UUID(),
      trigger: nil,
      outcome: .failed,
      metadata: [:],
      now: Date()
    )
    let unrelated = fixture.archiveDirectory.appendingPathComponent("keep-me.txt")
    try Data("unrelated".utf8).write(to: unrelated)

    try await store.deleteAll()

    XCTAssertTrue(try ownedFiles(in: fixture.archiveDirectory).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertTrue(
      EncryptedBenchmarkRecordingArchiveStore.requiresExistingDataProtectionKey(
        directoryURL: fixture.archiveDirectory
      )
    )
  }

  func testRejectsAudioThatIsNotOwnedByRill() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.archiveDirectory, keyByte: 0x61)
    let audio = try CapturedAudio(
      durationSeconds: 1,
      format: audioFormat,
      inlineData: Data([0, 1, 2]),
      fileOwnership: .callerManaged
    )

    do {
      _ = try await store.preserve(
        audio: audio,
        runID: UUID(),
        workflowID: UUID(),
        trigger: nil,
        outcome: .completed,
        metadata: [:],
        now: Date()
      )
      XCTFail("Expected unsupported payload.")
    } catch {
      XCTAssertEqual(error as? BenchmarkRecordingArchiveError, .unsupportedPayload)
    }
  }

  private var audioFormat: AudioFormat {
    AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16)
  }

  private func makeStore(
    directoryURL: URL,
    keyByte: UInt8
  ) throws -> EncryptedBenchmarkRecordingArchiveStore {
    try EncryptedBenchmarkRecordingArchiveStore(
      directoryURL: directoryURL,
      localDataProtector: makeProtector(keyByte: keyByte)
    )
  }

  private func makeProtector(keyByte: UInt8) throws -> AESGCMDataProtector {
    try AESGCMDataProtector(
      key: Data(repeating: keyByte, count: AESGCMDataProtector.keyByteCount)
    )
  }

  private func makeAudio(bytes: Data) throws -> CapturedAudio {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-benchmark-test-\(UUID().uuidString).wav")
    try bytes.write(to: url)
    return try CapturedAudio(
      durationSeconds: 1,
      format: audioFormat,
      fileURL: url,
      fileOwnership: .managedTemporary
    )
  }

  private func ownedFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "rillaudio" || $0.pathExtension == "rillmeta" }
  }

  private func makeFixture() throws -> BenchmarkArchiveFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let archiveDirectory = root.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BenchmarkArchiveFixture(root: root, archiveDirectory: archiveDirectory)
  }
}

private struct BenchmarkArchiveFixture {
  let root: URL
  let archiveDirectory: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
