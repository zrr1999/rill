import Darwin
import Foundation
import XCTest

@testable import RillCore
@testable import RillPlatform

final class EncryptedFailedAudioRecoveryStoreTests: XCTestCase {
  func testRoundTripKeepsAudioAndReceiptPlaintextOutOfRecoveryFiles() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x41)
    let audioBytes = Data("failed-audio-private-sentinel".utf8)
    let audio = try makeAudio(bytes: audioBytes, in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let workflowID = UUID()

    let receipt = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: workflowID,
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )

    let receipts = try await store.receipts(now: Date(timeIntervalSince1970: 101))
    XCTAssertEqual(receipts, [receipt])
    let materialized = try await store.materializeForRetry(
      id: receipt.id,
      attemptID: UUID(),
      now: Date(timeIntervalSince1970: 101)
    )
    defer { _ = try? materialized.removeManagedTemporaryFile() }
    XCTAssertEqual(materialized.fileOwnership, .managedTemporary)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(materialized.fileURL)), audioBytes)
    let materializedPermissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(
        atPath: XCTUnwrap(materialized.fileURL).path
      )[.posixPermissions] as? NSNumber
    ).intValue
    XCTAssertEqual(materializedPermissions & 0o777, 0o600)

    let forbiddenValues = [
      audioBytes,
      Data(runID.uuidString.utf8),
      Data(workflowID.uuidString.utf8),
    ]
    for file in try recoveryFiles(in: fixture.recoveryDirectory) {
      let storedBytes = try Data(contentsOf: file)
      for forbidden in forbiddenValues {
        XCTAssertNil(storedBytes.range(of: forbidden))
      }
    }

    try await store.delete(id: receipt.id)
    XCTAssertTrue(try recoveryFiles(in: fixture.recoveryDirectory).isEmpty)
  }

  func testWrongKeyAndTamperedAudioFailClosed() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x42)
    let audio = try makeAudio(bytes: Data([1, 2, 3, 4]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let receipt = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )

    let wrongKeyStore = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x43
    )
    await assertRecoveryError(.invalidEntry) {
      _ = try await wrongKeyStore.receipts(now: Date(timeIntervalSince1970: 101))
    }

    let audioFile = try XCTUnwrap(
      recoveryFiles(in: fixture.recoveryDirectory).first {
        $0.pathExtension == "vtaudio"
      }
    )
    try Data("rill:v1:tampered".utf8).write(to: audioFile, options: [.atomic])
    await assertRecoveryError(.invalidEntry) {
      _ = try await store.materializeForRetry(
        id: receipt.id,
        attemptID: UUID(),
        now: Date(timeIntervalSince1970: 101)
      )
    }
  }

  func testOversizedProtectedEnvelopeIsRejectedBeforeUnboundedRead() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 60,
      maximumEntryCount: 1,
      maximumEntryBytes: 4,
      maximumTotalBytes: 4
    )
    let store = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x4A,
      policy: policy
    )
    let audio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let receipt = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )
    let receiptFile = fixture.recoveryDirectory.appendingPathComponent(
      receipt.id.uuidString + ".vtreceipt"
    )
    try Data(repeating: 0x41, count: 65_545).write(to: receiptFile)

    await assertRecoveryError(.invalidEntry) {
      _ = try await store.receipts(now: Date(timeIntervalSince1970: 101))
    }
  }

  func testLiveReadRejectsTrailingGrowthAfterExpectedBytes() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let keyByte: UInt8 = 0x78
    let writer = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: keyByte
    )
    let audio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    _ = try await writer.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )
    let growth = RecoveryTrailingGrowthProbe(
      directory: fixture.recoveryDirectory
    )
    let reader = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: makeProtector(keyByte: keyByte),
      policy: .default,
      fileManager: .default,
      evictionFileOperations: .live,
      readHooks: growth.hooks
    )

    await assertRecoveryError(.invalidEntry) {
      _ = try await reader.receipts(now: Date(timeIntervalSince1970: 101))
    }
    XCTAssertTrue(growth.didAppend)
    XCTAssertNil(growth.errorDescription)
  }

  func testLiveReadMapsBodyAndTrailingSystemErrorsToStorageUnavailable() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let keyByte: UInt8 = 0x79
    let writer = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: keyByte
    )
    let audio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    _ = try await writer.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )

    for phase in RecoveryReadSystemErrorPhase.allCases {
      let reader = try EncryptedFailedAudioRecoveryStore(
        directoryURL: fixture.recoveryDirectory,
        localDataProtector: makeProtector(keyByte: keyByte),
        policy: .default,
        fileManager: .default,
        evictionFileOperations: .live,
        readHooks: phase.hooks
      )
      await assertRecoveryError(.storageUnavailable) {
        _ = try await reader.receipts(
          now: Date(timeIntervalSince1970: 101)
        )
      }
    }
  }

  func testExpiredEntriesArePurgedWithBothEncryptedFiles() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 10,
      maximumEntryCount: 3,
      maximumEntryBytes: 64,
      maximumTotalBytes: 128
    )
    let store = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x44,
      policy: policy
    )
    let audio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    _ = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )

    let removedBeforeExpiry = try await store.purgeExpired(
      now: Date(timeIntervalSince1970: 109)
    )
    let removedAtExpiry = try await store.purgeExpired(
      now: Date(timeIntervalSince1970: 110)
    )
    XCTAssertEqual(removedBeforeExpiry, 0)
    XCTAssertEqual(removedAtExpiry, 1)
    XCTAssertTrue(try recoveryFiles(in: fixture.recoveryDirectory).isEmpty)
  }

  func testCorruptReceiptDoesNotBlockOtherExpiryAndUsesArtifactMtimesForFallback() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 10,
      maximumEntryCount: 3,
      maximumEntryBytes: 64,
      maximumTotalBytes: 128
    )
    let store = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x4B,
      policy: policy
    )

    let firstAudio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? firstAudio.removeManagedTemporaryFile() }
    let firstRunID = UUID()
    let firstReceipt = try await store.preserve(
      audio: firstAudio,
      originalRunID: firstRunID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: firstRunID),
      now: Date(timeIntervalSince1970: 100)
    )

    let corruptAudio = try makeAudio(bytes: Data([4, 5, 6]), in: fixture.root)
    defer { _ = try? corruptAudio.removeManagedTemporaryFile() }
    let corruptRunID = UUID()
    let corruptReceipt = try await store.preserve(
      audio: corruptAudio,
      originalRunID: corruptRunID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: corruptRunID),
      now: Date(timeIntervalSince1970: 105)
    )

    let firstURLs = recoveryPairURLs(
      id: firstReceipt.id,
      directory: fixture.recoveryDirectory
    )
    let corruptURLs = recoveryPairURLs(
      id: corruptReceipt.id,
      directory: fixture.recoveryDirectory
    )
    try Data("tampered-receipt".utf8).write(
      to: corruptURLs.receipt,
      options: [.atomic]
    )
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 105)],
      ofItemAtPath: corruptURLs.audio.path
    )
    // A retry legitimately rewrites only the receipt. That later mtime
    // must not extend the encrypted audio's fallback retention window.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 114)],
      ofItemAtPath: corruptURLs.receipt.path
    )

    await assertRecoveryError(.invalidEntry) {
      _ = try await store.purgeExpired(
        now: Date(timeIntervalSince1970: 114)
      )
    }
    for url in [firstURLs.audio, firstURLs.receipt] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    for url in [corruptURLs.audio, corruptURLs.receipt] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    let fallbackRemoved = try await store.purgeExpired(
      now: Date(timeIntervalSince1970: 116)
    )
    XCTAssertEqual(fallbackRemoved, 1)
    XCTAssertTrue(try recoveryFiles(in: fixture.recoveryDirectory).isEmpty)
  }

  func testMaintenancePreservesMalformedOwnedNamesUntilExplicitDeletion() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x4D
    )
    let malformedAudio = fixture.recoveryDirectory.appendingPathComponent(
      "malformed.vtaudio"
    )
    let malformedReceipt = fixture.recoveryDirectory.appendingPathComponent(
      "malformed.vtreceipt"
    )
    try Data([1]).write(to: malformedAudio)
    try Data([2]).write(to: malformedReceipt)

    await assertRecoveryError(.invalidEntry) {
      _ = try await store.purgeExpired(now: Date())
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: malformedAudio.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: malformedReceipt.path))

    try await store.deleteAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: malformedAudio.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: malformedReceipt.path))
    let secondRemoved = try await store.purgeExpired(now: Date())
    XCTAssertEqual(secondRemoved, 0)
  }

  func testCapacityEvictsOldestEntryAndRejectsOversizedAudio() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 100,
      maximumEntryCount: 2,
      maximumEntryBytes: 5,
      maximumTotalBytes: 8
    )
    let store = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x45,
      policy: policy
    )
    var receipts: [FailedAudioRecoveryReceipt] = []
    for index in 0..<3 {
      let audio = try makeAudio(
        bytes: Data(repeating: UInt8(index + 1), count: 4),
        in: fixture.root
      )
      let runID = UUID()
      receipts.append(
        try await store.preserve(
          audio: audio,
          originalRunID: runID,
          workflowID: UUID(),
          failure: recoverableFailure(runID: runID),
          now: Date(timeIntervalSince1970: TimeInterval(100 + index))
        )
      )
      _ = try? audio.removeManagedTemporaryFile()
    }

    let remaining = try await store.receipts(now: Date(timeIntervalSince1970: 103))
    XCTAssertEqual(Set(remaining.map(\.id)), Set(receipts.suffix(2).map(\.id)))
    XCTAssertFalse(remaining.contains { $0.id == receipts[0].id })

    let oversized = try makeAudio(bytes: Data(repeating: 7, count: 6), in: fixture.root)
    defer { _ = try? oversized.removeManagedTemporaryFile() }
    await assertRecoveryError(.entryTooLarge) {
      _ = try await store.preserve(
        audio: oversized,
        originalRunID: UUID(),
        workflowID: UUID(),
        failure: self.recoverableFailure(runID: UUID()),
        now: Date(timeIntervalSince1970: 104)
      )
    }
    let receiptsAfterOversizedAttempt = try await store.receipts(
      now: Date(timeIntervalSince1970: 104)
    )
    XCTAssertEqual(receiptsAfterOversizedAttempt, remaining)
  }

  func testReceiptsConvergesAuthenticatedEntriesThatExceedCurrentQuota() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let loosePolicy = FailedAudioRecoveryPolicy(
      retentionInterval: 1_000,
      maximumEntryCount: 2,
      maximumEntryBytes: 8,
      maximumTotalBytes: 16
    )
    let looseStore = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x4C,
      policy: loosePolicy
    )
    var saved: [FailedAudioRecoveryReceipt] = []
    for index in 0..<2 {
      let audio = try makeAudio(
        bytes: Data(repeating: UInt8(index + 1), count: 4),
        in: fixture.root
      )
      let runID = UUID()
      saved.append(
        try await looseStore.preserve(
          audio: audio,
          originalRunID: runID,
          workflowID: UUID(),
          failure: recoverableFailure(runID: runID),
          now: Date(timeIntervalSince1970: TimeInterval(100 + index))
        )
      )
      _ = try? audio.removeManagedTemporaryFile()
    }

    // Opening the same durable pairs with a tighter policy reproduces the
    // state left by a crash after a replacement pair was committed but
    // before its quota eviction began.
    let strictStore = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: 0x4C,
      policy: FailedAudioRecoveryPolicy(
        retentionInterval: 1_000,
        maximumEntryCount: 1,
        maximumEntryBytes: 8,
        maximumTotalBytes: 8
      )
    )
    let converged = try await strictStore.receipts(
      now: Date(timeIntervalSince1970: 102)
    )

    XCTAssertEqual(converged, [saved[1]])
    XCTAssertEqual(try recoveryFiles(in: fixture.recoveryDirectory).count, 2)
    let oldestURLs = recoveryPairURLs(
      id: saved[0].id,
      directory: fixture.recoveryDirectory
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldestURLs.audio.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldestURLs.receipt.path))
  }

  func testProtectionFailureDoesNotEvictPreviouslyRecoverableEntry() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 100,
      maximumEntryCount: 1,
      maximumEntryBytes: 8,
      maximumTotalBytes: 8
    )
    let key = Data(repeating: 0x5A, count: AESGCMDataProtector.keyByteCount)
    let baseProtector = try AESGCMDataProtector(key: key)
    let store = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: baseProtector,
      policy: policy
    )
    let firstAudio = try makeAudio(bytes: Data([1, 2, 3, 4]), in: fixture.root)
    defer { _ = try? firstAudio.removeManagedTemporaryFile() }
    let firstRunID = UUID()
    let firstReceipt = try await store.preserve(
      audio: firstAudio,
      originalRunID: firstRunID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: firstRunID),
      now: Date(timeIntervalSince1970: 100)
    )

    let failingStore = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: SealFailingProtector(base: baseProtector),
      policy: policy
    )
    let replacementAudio = try makeAudio(bytes: Data([5, 6, 7, 8]), in: fixture.root)
    defer { _ = try? replacementAudio.removeManagedTemporaryFile() }
    await assertRecoveryError(.protectionUnavailable) {
      _ = try await failingStore.preserve(
        audio: replacementAudio,
        originalRunID: UUID(),
        workflowID: UUID(),
        failure: self.recoverableFailure(runID: UUID()),
        now: Date(timeIntervalSince1970: 101)
      )
    }

    let remaining = try await store.receipts(now: Date(timeIntervalSince1970: 102))
    XCTAssertEqual(remaining, [firstReceipt])
  }

  func testCertainEvictionRollbackRemovesReplacementAndPreservesOldPair() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 100,
      maximumEntryCount: 1,
      maximumEntryBytes: 8,
      maximumTotalBytes: 8
    )
    let key = Data(repeating: 0x5D, count: AESGCMDataProtector.keyByteCount)
    let protector = try AESGCMDataProtector(key: key)
    let baseStore = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: protector,
      policy: policy
    )
    let oldAudio = try makeAudio(bytes: Data([1, 2, 3, 4]), in: fixture.root)
    defer { _ = try? oldAudio.removeManagedTemporaryFile() }
    let oldRunID = UUID()
    let oldReceipt = try await baseStore.preserve(
      audio: oldAudio,
      originalRunID: oldRunID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: oldRunID),
      now: Date(timeIntervalSince1970: 100)
    )

    let operations = EvictionOperationProbe(renameFailures: [2]).operations
    let failingStore = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: protector,
      policy: policy,
      fileManager: .default,
      evictionFileOperations: operations
    )
    let replacementAudio = try makeAudio(
      bytes: Data([5, 6, 7, 8]),
      in: fixture.root
    )
    defer { _ = try? replacementAudio.removeManagedTemporaryFile() }
    let replacementRunID = UUID()
    await assertRecoveryError(.storageUnavailable) {
      _ = try await failingStore.preserve(
        audio: replacementAudio,
        originalRunID: replacementRunID,
        workflowID: UUID(),
        failure: self.recoverableFailure(runID: replacementRunID),
        now: Date(timeIntervalSince1970: 101)
      )
    }

    let remaining = try await baseStore.receipts(
      now: Date(timeIntervalSince1970: 102)
    )
    XCTAssertEqual(remaining, [oldReceipt])
    XCTAssertEqual(try recoveryFiles(in: fixture.recoveryDirectory).count, 2)
  }

  func testUncertainEvictionRollbackKeepsReplacementUntilQuotaConverges() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let policy = FailedAudioRecoveryPolicy(
      retentionInterval: 100,
      maximumEntryCount: 1,
      maximumEntryBytes: 8,
      maximumTotalBytes: 8
    )
    let key = Data(repeating: 0x5E, count: AESGCMDataProtector.keyByteCount)
    let protector = try AESGCMDataProtector(key: key)
    let baseStore = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: protector,
      policy: policy
    )
    let oldAudio = try makeAudio(bytes: Data([1, 2, 3, 4]), in: fixture.root)
    defer { _ = try? oldAudio.removeManagedTemporaryFile() }
    let oldRunID = UUID()
    _ = try await baseStore.preserve(
      audio: oldAudio,
      originalRunID: oldRunID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: oldRunID),
      now: Date(timeIntervalSince1970: 100)
    )

    // The first sync reports that staging was not durable; restoration
    // renames succeed, but the second sync cannot prove the rollback.
    let operations = EvictionOperationProbe(
      synchronizeFailures: [1, 2]
    ).operations
    let uncertainStore = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: protector,
      policy: policy,
      fileManager: .default,
      evictionFileOperations: operations
    )
    let replacementAudio = try makeAudio(
      bytes: Data([5, 6, 7, 8]),
      in: fixture.root
    )
    defer { _ = try? replacementAudio.removeManagedTemporaryFile() }
    let replacementRunID = UUID()
    let replacement = try await uncertainStore.preserve(
      audio: replacementAudio,
      originalRunID: replacementRunID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: replacementRunID),
      now: Date(timeIntervalSince1970: 101)
    )

    XCTAssertEqual(try recoveryFiles(in: fixture.recoveryDirectory).count, 4)
    let converged = try await uncertainStore.receipts(
      now: Date(timeIntervalSince1970: 102)
    )
    XCTAssertEqual(converged, [replacement])
    XCTAssertEqual(try recoveryFiles(in: fixture.recoveryDirectory).count, 2)
  }

  func testRetryStateIsDurableAndMustBeExplicitlyRestoredAfterKnownFailure() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x5B)
    let audio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let receipt = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date(timeIntervalSince1970: 100)
    )
    let attemptID = UUID()
    let materialized = try await store.materializeForRetry(
      id: receipt.id,
      attemptID: attemptID,
      now: Date(timeIntervalSince1970: 101)
    )
    defer { _ = try? materialized.removeManagedTemporaryFile() }

    let inFlight = try await store.receipts(now: Date(timeIntervalSince1970: 101))
    XCTAssertEqual(inFlight.count, 1)
    XCTAssertFalse(inFlight[0].status.canRetry)
    await assertRecoveryError(.retryOutcomeUnknown) {
      _ = try await store.materializeForRetry(
        id: receipt.id,
        attemptID: UUID(),
        now: Date(timeIntervalSince1970: 101)
      )
    }

    try await store.restoreAfterFailedRetry(id: receipt.id, attemptID: attemptID)
    let restored = try await store.receipts(now: Date(timeIntervalSince1970: 101))
    XCTAssertTrue(try XCTUnwrap(restored.first).status.canRetry)
  }

  func testStoreRejectsCallerManagedAudioAtItsOwnBoundary() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x5C)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-recovery-caller-\(UUID().uuidString).wav"
    )
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let audio = try CapturedAudio(
      durationSeconds: 1,
      format: audioFormat,
      fileURL: url,
      fileOwnership: .callerManaged
    )

    await assertRecoveryError(.unsupportedPayload) {
      _ = try await store.preserve(
        audio: audio,
        originalRunID: UUID(),
        workflowID: UUID(),
        failure: self.recoverableFailure(runID: UUID()),
        now: Date()
      )
    }
  }

  func testSymlinkPayloadAndRecoveryDirectoryAreRejected() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x46)
    let target = fixture.root.appendingPathComponent("target.wav")
    try Data([1, 2, 3]).write(to: target)
    let link = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-recovery-link-\(UUID().uuidString).wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: link) }
    let linkedAudio = try CapturedAudio(
      durationSeconds: 1,
      format: audioFormat,
      fileURL: link,
      fileOwnership: .managedTemporary
    )
    await assertRecoveryError(.unsupportedPayload) {
      _ = try await store.preserve(
        audio: linkedAudio,
        originalRunID: UUID(),
        workflowID: UUID(),
        failure: self.recoverableFailure(runID: UUID()),
        now: Date()
      )
    }

    let realDirectory = fixture.root.appendingPathComponent("real-recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    let directoryLink = fixture.root.appendingPathComponent("linked-recovery", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: directoryLink,
      withDestinationURL: realDirectory
    )
    XCTAssertThrowsError(
      try makeStore(directoryURL: directoryLink, keyByte: 0x47)
    ) { error in
      XCTAssertEqual(error as? FailedAudioRecoveryError, .storageUnavailable)
    }
  }

  func testNonemptyRecoveryDirectoryRequiresExistingProtectionKey() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    XCTAssertFalse(
      EncryptedFailedAudioRecoveryStore.requiresExistingDataProtectionKey(
        directoryURL: fixture.recoveryDirectory
      )
    )
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x48)
    let audio = try makeAudio(bytes: Data([9]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    _ = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date()
    )

    XCTAssertTrue(
      EncryptedFailedAudioRecoveryStore.requiresExistingDataProtectionKey(
        directoryURL: fixture.recoveryDirectory
      )
    )
    try await store.deleteAll()
    XCTAssertFalse(
      EncryptedFailedAudioRecoveryStore.requiresExistingDataProtectionKey(
        directoryURL: fixture.recoveryDirectory
      )
    )
  }

  func testExistingKeyProbeReturnsUnboundWithoutOwnedArtifactsAndDoesNotMutate() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let missingSnapshot = try recoveryDirectorySnapshot(
      fixture.recoveryDirectory
    )
    XCTAssertEqual(
      try probeExistingKey(
        directoryURL: fixture.recoveryDirectory,
        keyByte: 0x61
      ),
      .unbound
    )
    XCTAssertEqual(
      try recoveryDirectorySnapshot(fixture.recoveryDirectory),
      missingSnapshot
    )

    try FileManager.default.createDirectory(
      at: fixture.recoveryDirectory,
      withIntermediateDirectories: true
    )
    try Data("unrelated".utf8).write(
      to: fixture.recoveryDirectory.appendingPathComponent("keep-me.txt")
    )
    let unrelatedSnapshot = try recoveryDirectorySnapshot(
      fixture.recoveryDirectory
    )
    XCTAssertEqual(
      try probeExistingKey(
        directoryURL: fixture.recoveryDirectory,
        keyByte: 0x61
      ),
      .unbound
    )
    XCTAssertEqual(
      try recoveryDirectorySnapshot(fixture.recoveryDirectory),
      unrelatedSnapshot
    )
  }

  func testExistingKeyProbeAuthenticatesCompletePairWithoutMutation() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    _ = try writeRecoveryPair(
      audioBytes: Data([1, 2, 3]),
      keyByte: 0x62,
      directory: fixture.recoveryDirectory
    )
    let snapshot = try recoveryDirectorySnapshot(fixture.recoveryDirectory)

    XCTAssertEqual(
      try probeExistingKey(
        directoryURL: fixture.recoveryDirectory,
        keyByte: 0x62
      ),
      .boundAndValid
    )
    XCTAssertEqual(
      try recoveryDirectorySnapshot(fixture.recoveryDirectory),
      snapshot
    )
  }

  func testExistingKeyProbeRejectsWrongKeyWithoutMutation() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    _ = try writeRecoveryPair(
      audioBytes: Data([1, 2, 3]),
      keyByte: 0x63,
      directory: fixture.recoveryDirectory
    )

    try assertProbeFailurePreservesDirectory(
      fixture.recoveryDirectory,
      keyByte: 0x64
    )
  }

  func testExistingKeyProbeRejectsMixedKeysWithoutMutation() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    _ = try writeRecoveryPair(
      audioBytes: Data([1, 2]),
      keyByte: 0x65,
      directory: fixture.recoveryDirectory
    )
    _ = try writeRecoveryPair(
      audioBytes: Data([3, 4]),
      keyByte: 0x66,
      directory: fixture.recoveryDirectory
    )

    try assertProbeFailurePreservesDirectory(
      fixture.recoveryDirectory,
      keyByte: 0x65
    )
  }

  func testExistingKeyProbeRejectsCanonicalSingleSidedArtifactWithoutMutation() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let pair = try writeRecoveryPair(
      audioBytes: Data([1, 2, 3]),
      keyByte: 0x67,
      directory: fixture.recoveryDirectory
    )
    let urls = recoveryPairURLs(
      id: pair.id,
      directory: fixture.recoveryDirectory
    )
    try FileManager.default.removeItem(at: urls.receipt)
    XCTAssertTrue(
      EncryptedFailedAudioRecoveryStore.requiresExistingDataProtectionKey(
        directoryURL: fixture.recoveryDirectory
      )
    )

    try assertProbeFailurePreservesDirectory(
      fixture.recoveryDirectory,
      keyByte: 0x67
    )
  }

  func testExistingKeyProbeRejectsRecognizedTemporaryArtifactWithoutMutation() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.recoveryDirectory,
      withIntermediateDirectories: true
    )
    try Data([9]).write(
      to: fixture.recoveryDirectory.appendingPathComponent(
        ".\(UUID().uuidString).vttmp"
      )
    )
    XCTAssertTrue(
      EncryptedFailedAudioRecoveryStore.requiresExistingDataProtectionKey(
        directoryURL: fixture.recoveryDirectory
      )
    )

    try assertProbeFailurePreservesDirectory(
      fixture.recoveryDirectory,
      keyByte: 0x67
    )
  }

  func testExistingKeyProbeRejectsSymlinkArtifactWithoutFollowingOrMutation() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let pair = try writeRecoveryPair(
      audioBytes: Data([1, 2, 3]),
      keyByte: 0x68,
      directory: fixture.recoveryDirectory
    )
    let urls = recoveryPairURLs(
      id: pair.id,
      directory: fixture.recoveryDirectory
    )
    let target = fixture.recoveryDirectory.appendingPathComponent("target.bin")
    try FileManager.default.moveItem(at: urls.audio, to: target)
    try FileManager.default.createSymbolicLink(
      at: urls.audio,
      withDestinationURL: target
    )

    try assertProbeFailurePreservesDirectory(
      fixture.recoveryDirectory,
      keyByte: 0x68
    )
  }

  func testExistingKeyProbeRejectsIllegalNamesHardLinksAndNonregularArtifactsWithoutMutation()
    throws
  {
    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      try FileManager.default.createDirectory(
        at: fixture.recoveryDirectory,
        withIntermediateDirectories: true
      )
      for suffix in [".vtaudio", ".vtreceipt"] {
        try Data([1]).write(
          to: fixture.recoveryDirectory.appendingPathComponent(
            "not-a-uuid" + suffix
          )
        )
      }
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x6E
      )
    }

    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let pair = try writeRecoveryPair(
        audioBytes: Data([1, 2, 3]),
        keyByte: 0x6F,
        directory: fixture.recoveryDirectory
      )
      let audioURL = recoveryPairURLs(
        id: pair.id,
        directory: fixture.recoveryDirectory
      ).audio
      try FileManager.default.linkItem(
        at: audioURL,
        to: fixture.recoveryDirectory.appendingPathComponent("duplicate.bin")
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x6F
      )
    }

    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let pair = try writeRecoveryPair(
        audioBytes: Data([1, 2, 3]),
        keyByte: 0x70,
        directory: fixture.recoveryDirectory
      )
      let audioURL = recoveryPairURLs(
        id: pair.id,
        directory: fixture.recoveryDirectory
      ).audio
      try FileManager.default.removeItem(at: audioURL)
      try FileManager.default.createDirectory(
        at: audioURL,
        withIntermediateDirectories: false
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x70
      )
    }
  }

  func testExistingKeyProbeRejectsEntryCountAndByteLimitsWithoutMutation() throws {
    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      _ = try writeRecoveryPair(
        audioBytes: Data([1, 2]),
        keyByte: 0x69,
        directory: fixture.recoveryDirectory
      )
      _ = try writeRecoveryPair(
        audioBytes: Data([3, 4]),
        keyByte: 0x69,
        directory: fixture.recoveryDirectory
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x69,
        policy: FailedAudioRecoveryPolicy(
          retentionInterval: 60,
          maximumEntryCount: 1,
          maximumEntryBytes: 4,
          maximumTotalBytes: 4
        )
      )
    }

    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      _ = try writeRecoveryPair(
        audioBytes: Data([1, 2, 3, 4, 5]),
        keyByte: 0x6A,
        directory: fixture.recoveryDirectory
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x6A,
        policy: FailedAudioRecoveryPolicy(
          retentionInterval: 60,
          maximumEntryCount: 1,
          maximumEntryBytes: 4,
          maximumTotalBytes: 4
        )
      )
    }
  }

  func testExistingKeyProbeRejectsAuthenticatedInvalidReceiptStructuresWithoutMutation() throws {
    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let pair = try writeRecoveryPair(
        audioBytes: Data([1, 2, 3]),
        keyByte: 0x6B,
        directory: fixture.recoveryDirectory
      )
      try overwriteProtectedReceipt(
        id: pair.id,
        plaintext: Data("not-json".utf8),
        keyByte: 0x6B,
        directory: fixture.recoveryDirectory
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x6B
      )
    }

    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      _ = try writeRecoveryPair(
        audioBytes: Data([1, 2, 3]),
        keyByte: 0x6C,
        directory: fixture.recoveryDirectory,
        mutateReceipt: { receipt in
          receipt.id = UUID()
        }
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x6C
      )
    }

    do {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      _ = try writeRecoveryPair(
        audioBytes: Data([1, 2, 3]),
        keyByte: 0x6D,
        directory: fixture.recoveryDirectory,
        mutateReceipt: { receipt in
          receipt.plaintextByteCount = 2
          receipt.expiresAt = receipt.createdAt
        }
      )
      try assertProbeFailurePreservesDirectory(
        fixture.recoveryDirectory,
        keyByte: 0x6D
      )
    }
  }

  func testInitializationPreservesStaleIncompleteAndRecognizedTemporaryArtifacts() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.recoveryDirectory,
      withIntermediateDirectories: true
    )
    let orphanAudio = fixture.recoveryDirectory.appendingPathComponent(
      UUID().uuidString + ".vtaudio"
    )
    let orphanReceipt = fixture.recoveryDirectory.appendingPathComponent(
      UUID().uuidString + ".vtreceipt"
    )
    let pendingWrite = fixture.recoveryDirectory.appendingPathComponent(
      ".\(UUID().uuidString).vttmp"
    )
    let pendingEviction = fixture.recoveryDirectory.appendingPathComponent(
      ".evict-\(UUID().uuidString)-audio.vttmp"
    )
    let unrelated = fixture.recoveryDirectory.appendingPathComponent("keep-me.txt")
    let preservedArtifacts = [
      orphanAudio,
      orphanReceipt,
      pendingWrite,
      pendingEviction,
    ]
    for url in preservedArtifacts + [unrelated] {
      try Data([1]).write(to: url)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -86_400)],
        ofItemAtPath: url.path
      )
    }

    _ = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x49)

    for artifact in preservedArtifacts {
      XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertThrowsError(
      try probeExistingKey(
        directoryURL: fixture.recoveryDirectory,
        keyByte: 0x49
      )
    ) { error in
      XCTAssertEqual(error as? FailedAudioRecoveryError, .invalidEntry)
    }
  }

  func testInitializationFailsClosedWithoutDeletingIllegalOwnedArtifacts() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.recoveryDirectory,
      withIntermediateDirectories: true
    )
    let illegalReceipt = fixture.recoveryDirectory.appendingPathComponent(
      "not-a-uuid.vtreceipt"
    )
    let illegalTemporary = fixture.recoveryDirectory.appendingPathComponent(
      ".interrupted.vttmp"
    )
    try Data([1]).write(to: illegalReceipt)
    try Data([2]).write(to: illegalTemporary)
    let snapshot = try recoveryDirectorySnapshot(fixture.recoveryDirectory)

    XCTAssertThrowsError(
      try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x74)
    ) { error in
      XCTAssertEqual(error as? FailedAudioRecoveryError, .invalidEntry)
    }
    XCTAssertEqual(
      try recoveryDirectorySnapshot(fixture.recoveryDirectory),
      snapshot
    )
  }

  func testExplicitOwnedArtifactPurgeDoesNotRecursivelyDeleteDirectoryArtifact() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let artifactDirectory = fixture.recoveryDirectory.appendingPathComponent(
      UUID().uuidString + ".vtaudio",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: true
    )
    let sentinel = artifactDirectory.appendingPathComponent("must-survive.txt")
    try Data("sentinel".utf8).write(to: sentinel)

    XCTAssertThrowsError(
      try EncryptedFailedAudioRecoveryStore.deleteOwnedArtifactsWithoutOpening(
        directoryURL: fixture.recoveryDirectory
      )
    ) { error in
      XCTAssertEqual(error as? FailedAudioRecoveryError, .storageUnavailable)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
  }

  func testLiveAudioReadRejectsHardLinkedArtifact() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = try makeStore(directoryURL: fixture.recoveryDirectory, keyByte: 0x76)
    let audio = try makeAudio(bytes: Data([1, 2, 3]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let receipt = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date()
    )
    let audioURL = recoveryPairURLs(
      id: receipt.id,
      directory: fixture.recoveryDirectory
    ).audio
    try FileManager.default.linkItem(
      at: audioURL,
      to: fixture.recoveryDirectory.appendingPathComponent("duplicate.bin")
    )

    await assertRecoveryError(.invalidEntry) {
      _ = try await store.materializeForRetry(
        id: receipt.id,
        attemptID: UUID(),
        now: Date()
      )
    }
  }

  func testSecondStoreInitializationWaitsForHalfCommittedPair() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let keyByte: UInt8 = 0x75
    let gate = RecoveryHalfCommitGate()
    defer { gate.allowReceiptCommit() }
    let protector = try makeProtector(keyByte: keyByte)
    let writer = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: protector,
      policy: .default,
      fileManager: .default,
      evictionFileOperations: .live,
      commitHooks: gate.hooks
    )
    let audio = try makeAudio(bytes: Data([1, 2, 3, 4]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()
    let failure = recoverableFailure(runID: runID)
    let preserveTask = Task {
      try await writer.preserve(
        audio: audio,
        originalRunID: runID,
        workflowID: UUID(),
        failure: failure,
        now: Date()
      )
    }

    XCTAssertTrue(gate.waitForAudioCommit(timeout: 2))
    let filesAtHalfCommit = try recoveryFiles(in: fixture.recoveryDirectory)
    XCTAssertEqual(filesAtHalfCommit.filter { $0.pathExtension == "vtaudio" }.count, 1)
    XCTAssertTrue(filesAtHalfCommit.filter { $0.pathExtension == "vtreceipt" }.isEmpty)

    let initialization = RecoveryStoreInitializationProbe()
    initialization.start(
      directoryURL: fixture.recoveryDirectory,
      keyByte: keyByte
    )
    XCTAssertTrue(initialization.waitUntilLockContention(timeout: 2))
    XCTAssertEqual(
      try recoveryFiles(in: fixture.recoveryDirectory)
        .filter { $0.pathExtension == "vtaudio" }.count,
      1
    )

    gate.allowReceiptCommit()
    let committedReceipt = try await preserveTask.value
    XCTAssertTrue(initialization.waitUntilFinished(timeout: 2))
    XCTAssertNil(initialization.errorDescription)

    let reader = try makeStore(
      directoryURL: fixture.recoveryDirectory,
      keyByte: keyByte
    )
    let receipts = try await reader.receipts(now: Date())
    XCTAssertEqual(receipts.map(\.id), [committedReceipt.id])
    XCTAssertEqual(try recoveryFiles(in: fixture.recoveryDirectory).count, 2)
  }

  func testPreserveStaysOnLockedDirectoryInodeAfterPathReplacement() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let movedDirectory = fixture.root.appendingPathComponent(
      "locked-recovery",
      isDirectory: true
    )
    let replacement = RecoveryDirectoryReplacementProbe(
      originalDirectory: fixture.recoveryDirectory,
      movedDirectory: movedDirectory
    )
    let keyByte: UInt8 = 0x77
    let store = try EncryptedFailedAudioRecoveryStore(
      directoryURL: fixture.recoveryDirectory,
      localDataProtector: makeProtector(keyByte: keyByte),
      policy: .default,
      fileManager: .default,
      evictionFileOperations: .live,
      commitHooks: replacement.hooks
    )
    let audio = try makeAudio(bytes: Data([1, 2, 3, 4]), in: fixture.root)
    defer { _ = try? audio.removeManagedTemporaryFile() }
    let runID = UUID()

    let receipt = try await store.preserve(
      audio: audio,
      originalRunID: runID,
      workflowID: UUID(),
      failure: recoverableFailure(runID: runID),
      now: Date()
    )

    XCTAssertNil(replacement.errorDescription)
    XCTAssertEqual(
      try recoveryFiles(in: movedDirectory).map(\.lastPathComponent).sorted(),
      [
        receipt.id.uuidString + ".vtaudio",
        receipt.id.uuidString + ".vtreceipt",
      ]
    )
    XCTAssertEqual(
      try recoveryFiles(in: fixture.recoveryDirectory).map(\.lastPathComponent),
      [RecoveryDirectoryReplacementProbe.sentinelName]
    )
    let replacementSnapshot = try recoveryDirectorySnapshot(
      fixture.recoveryDirectory
    )
    await assertRecoveryError(.storageUnavailable) {
      try await store.deleteAll()
    }
    XCTAssertEqual(
      try recoveryDirectorySnapshot(fixture.recoveryDirectory),
      replacementSnapshot
    )
    let reader = try makeStore(directoryURL: movedDirectory, keyByte: keyByte)
    let movedReceipts = try await reader.receipts(now: Date())
    XCTAssertEqual(
      movedReceipts.map(\.id),
      [receipt.id]
    )
  }

  func testOptOutPurgerWorksWithoutAProtectionKeyAndPreservesUnrelatedFiles() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.recoveryDirectory,
      withIntermediateDirectories: true
    )
    let id = UUID().uuidString
    let owned = [
      fixture.recoveryDirectory.appendingPathComponent(id + ".vtaudio"),
      fixture.recoveryDirectory.appendingPathComponent(id + ".vtreceipt"),
      fixture.recoveryDirectory.appendingPathComponent(".pending.vttmp"),
    ]
    let unrelated = fixture.recoveryDirectory.appendingPathComponent("keep-me.txt")
    for file in owned + [unrelated] {
      try Data([1]).write(to: file)
    }

    try EncryptedFailedAudioRecoveryStore.deleteOwnedArtifactsWithoutOpening(
      directoryURL: fixture.recoveryDirectory
    )

    for file in owned {
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  private var audioFormat: AudioFormat {
    AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16)
  }

  private func makeStore(
    directoryURL: URL,
    keyByte: UInt8,
    policy: FailedAudioRecoveryPolicy = .default
  ) throws -> EncryptedFailedAudioRecoveryStore {
    try EncryptedFailedAudioRecoveryStore(
      directoryURL: directoryURL,
      localDataProtector: AESGCMDataProtector(
        key: Data(repeating: keyByte, count: 32)
      ),
      policy: policy
    )
  }

  private func makeAudio(bytes: Data, in directory: URL) throws -> CapturedAudio {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-recovery-test-\(UUID().uuidString).wav")
    try bytes.write(to: url)
    return try CapturedAudio(
      durationSeconds: 1,
      format: audioFormat,
      fileURL: url,
      fileOwnership: .managedTemporary
    )
  }

  private func recoverableFailure(runID: UUID) -> WorkflowRunFailureSummary {
    WorkflowRunFailureSummary(runID: runID, stage: .recognizing, code: .processing)
  }

  private func recoveryFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
  }

  private func recoveryPairURLs(
    id: UUID,
    directory: URL
  ) -> (audio: URL, receipt: URL) {
    (
      directory.appendingPathComponent(id.uuidString + ".vtaudio"),
      directory.appendingPathComponent(id.uuidString + ".vtreceipt")
    )
  }

  private func probeExistingKey(
    directoryURL: URL,
    keyByte: UInt8,
    policy: FailedAudioRecoveryPolicy = .default
  ) throws -> EncryptedFailedAudioRecoveryStore.ExistingKeyProbeResult {
    try EncryptedFailedAudioRecoveryStore.probeExistingDataProtectionKey(
      directoryURL: directoryURL,
      localDataProtector: makeProtector(keyByte: keyByte),
      policy: policy
    )
  }

  private func assertProbeFailurePreservesDirectory(
    _ directoryURL: URL,
    keyByte: UInt8,
    policy: FailedAudioRecoveryPolicy = .default,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let snapshot = try recoveryDirectorySnapshot(directoryURL)
    XCTAssertThrowsError(
      try probeExistingKey(
        directoryURL: directoryURL,
        keyByte: keyByte,
        policy: policy
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? FailedAudioRecoveryError,
        .invalidEntry,
        file: file,
        line: line
      )
    }
    XCTAssertEqual(
      try recoveryDirectorySnapshot(directoryURL),
      snapshot,
      file: file,
      line: line
    )
  }

  @discardableResult
  private func writeRecoveryPair(
    id: UUID = UUID(),
    audioBytes: Data,
    keyByte: UInt8,
    directory: URL,
    mutateReceipt: ((inout FailedAudioRecoveryReceipt) -> Void)? = nil
  ) throws -> FailedAudioRecoveryReceipt {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    var receipt = FailedAudioRecoveryReceipt(
      id: id,
      originalRunID: UUID(),
      workflowID: UUID(),
      createdAt: Date(timeIntervalSince1970: 100),
      expiresAt: Date(timeIntervalSince1970: 200),
      durationSeconds: 1,
      format: audioFormat,
      plaintextByteCount: audioBytes.count,
      failureStage: .recognizing,
      failureCode: .processing
    )
    mutateReceipt?(&receipt)
    let protector = try makeProtector(keyByte: keyByte)
    let urls = recoveryPairURLs(id: id, directory: directory)
    let protectedAudio = try protector.seal(
      audioBytes,
      context: recoveryProtectionContext(id: id, field: "audio")
    )
    let protectedReceipt = try protector.seal(
      JSONEncoder().encode(receipt),
      context: recoveryProtectionContext(id: id, field: "receipt")
    )
    try Data(protectedAudio.utf8).write(to: urls.audio)
    try Data(protectedReceipt.utf8).write(to: urls.receipt)
    return receipt
  }

  private func overwriteProtectedReceipt(
    id: UUID,
    plaintext: Data,
    keyByte: UInt8,
    directory: URL
  ) throws {
    let protector = try makeProtector(keyByte: keyByte)
    let envelope = try protector.seal(
      plaintext,
      context: recoveryProtectionContext(id: id, field: "receipt")
    )
    try Data(envelope.utf8).write(
      to: recoveryPairURLs(id: id, directory: directory).receipt
    )
  }

  private func makeProtector(keyByte: UInt8) throws -> AESGCMDataProtector {
    try AESGCMDataProtector(
      key: Data(
        repeating: keyByte,
        count: AESGCMDataProtector.keyByteCount
      )
    )
  }

  private func recoveryProtectionContext(
    id: UUID,
    field: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "failed_audio_recovery",
      recordID: id.uuidString,
      field: field
    )
  }

  private func recoveryDirectorySnapshot(
    _ directoryURL: URL
  ) throws -> RecoveryDirectorySnapshot {
    var directoryInfo = stat()
    guard lstat(directoryURL.path, &directoryInfo) == 0 else {
      if errno == ENOENT {
        return RecoveryDirectorySnapshot(
          exists: false,
          modificationTimeSeconds: 0,
          modificationTimeNanoseconds: 0,
          entries: []
        )
      }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: []
    ).map { url -> RecoveryDirectoryEntrySnapshot in
      var info = stat()
      guard lstat(url.path, &info) == 0 else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      let kind = info.st_mode & S_IFMT
      let bytes: Data
      if kind == S_IFREG {
        bytes = try Data(contentsOf: url)
      } else if kind == S_IFLNK {
        bytes = Data(
          try FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
          ).utf8
        )
      } else {
        bytes = Data()
      }
      return RecoveryDirectoryEntrySnapshot(
        name: url.lastPathComponent,
        kind: UInt16(kind),
        byteCount: Int64(info.st_size),
        bytes: bytes,
        modificationTimeSeconds: Int64(info.st_mtimespec.tv_sec),
        modificationTimeNanoseconds: Int64(info.st_mtimespec.tv_nsec)
      )
    }.sorted { $0.name < $1.name }
    return RecoveryDirectorySnapshot(
      exists: true,
      modificationTimeSeconds: Int64(directoryInfo.st_mtimespec.tv_sec),
      modificationTimeNanoseconds: Int64(directoryInfo.st_mtimespec.tv_nsec),
      entries: entries
    )
  }

  private func makeFixture() throws -> RecoveryStoreFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return RecoveryStoreFixture(root: root, recoveryDirectory: recoveryDirectory)
  }

  private func assertRecoveryError(
    _ expected: FailedAudioRecoveryError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected).")
    } catch {
      XCTAssertEqual(error as? FailedAudioRecoveryError, expected)
    }
  }
}

private struct RecoveryDirectorySnapshot: Equatable {
  let exists: Bool
  let modificationTimeSeconds: Int64
  let modificationTimeNanoseconds: Int64
  let entries: [RecoveryDirectoryEntrySnapshot]
}

private struct RecoveryDirectoryEntrySnapshot: Equatable {
  let name: String
  let kind: UInt16
  let byteCount: Int64
  let bytes: Data
  let modificationTimeSeconds: Int64
  let modificationTimeNanoseconds: Int64
}

private enum RecoveryReadSystemErrorPhase: CaseIterable, Sendable {
  case expectedBytes
  case trailingEOF

  var hooks: EncryptedFailedAudioRecoveryReadHooks {
    EncryptedFailedAudioRecoveryReadHooks(
      expectedBytesReadError: { [self] name in
        guard name.hasSuffix(".vtreceipt"), self == .expectedBytes else {
          return nil
        }
        return EIO
      },
      didReadExpectedBytes: { _ in },
      trailingEOFReadError: { [self] name in
        guard name.hasSuffix(".vtreceipt"), self == .trailingEOF else {
          return nil
        }
        return EIO
      }
    )
  }
}

private struct SealFailingProtector: LocalDataProtector {
  let base: AESGCMDataProtector

  func seal(
    _ plaintext: Data,
    context: LocalDataProtectionContext
  ) throws -> String {
    throw FailedAudioRecoveryError.protectionUnavailable
  }

  func open(
    _ envelope: String,
    context: LocalDataProtectionContext
  ) throws -> Data {
    try base.open(envelope, context: context)
  }
}

private final class EvictionOperationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let renameFailures: Set<Int>
  private let synchronizeFailures: Set<Int>
  private var renameCallCount = 0
  private var synchronizeCallCount = 0

  init(
    renameFailures: Set<Int> = [],
    synchronizeFailures: Set<Int> = []
  ) {
    self.renameFailures = renameFailures
    self.synchronizeFailures = synchronizeFailures
  }

  var operations: EncryptedFailedAudioRecoveryEvictionFileOperations {
    EncryptedFailedAudioRecoveryEvictionFileOperations(
      renameItem: { [self] directoryDescriptor, sourceName, destinationName in
        renameItem(
          directoryDescriptor,
          sourceName,
          destinationName
        )
      },
      synchronizeDirectory: { [self] directoryDescriptor in
        synchronizeDirectory(directoryDescriptor)
      }
    )
  }

  private func renameItem(
    _ directoryDescriptor: Int32,
    _ sourceName: String,
    _ destinationName: String
  ) -> Int32 {
    lock.lock()
    renameCallCount += 1
    let shouldFail = renameFailures.contains(renameCallCount)
    lock.unlock()
    guard !shouldFail else { return -1 }
    return Darwin.renameat(
      directoryDescriptor,
      sourceName,
      directoryDescriptor,
      destinationName
    )
  }

  private func synchronizeDirectory(_ directoryDescriptor: Int32) -> Bool {
    lock.lock()
    synchronizeCallCount += 1
    let shouldFail = synchronizeFailures.contains(synchronizeCallCount)
    lock.unlock()
    guard !shouldFail else { return false }
    return EncryptedFailedAudioRecoveryEvictionFileOperations.live
      .synchronizeDirectory(directoryDescriptor)
  }
}

private final class RecoveryHalfCommitGate: @unchecked Sendable {
  private let audioCommitted = DispatchSemaphore(value: 0)
  private let receiptCommitAllowed = DispatchSemaphore(value: 0)

  var hooks: EncryptedFailedAudioRecoveryCommitHooks {
    EncryptedFailedAudioRecoveryCommitHooks(
      didCommitAudioArtifact: { [self] in
        audioCommitted.signal()
        receiptCommitAllowed.wait()
      }
    )
  }

  func waitForAudioCommit(timeout: TimeInterval) -> Bool {
    audioCommitted.wait(timeout: .now() + timeout) == .success
  }

  func allowReceiptCommit() {
    receiptCommitAllowed.signal()
  }
}

private final class RecoveryDirectoryReplacementProbe: @unchecked Sendable {
  static let sentinelName = "replacement-sentinel.txt"

  private let lock = NSLock()
  private let originalDirectory: URL
  private let movedDirectory: URL
  private var storedErrorDescription: String?

  init(originalDirectory: URL, movedDirectory: URL) {
    self.originalDirectory = originalDirectory
    self.movedDirectory = movedDirectory
  }

  var hooks: EncryptedFailedAudioRecoveryCommitHooks {
    EncryptedFailedAudioRecoveryCommitHooks(
      didCommitAudioArtifact: { [self] in replaceDirectoryPath() }
    )
  }

  var errorDescription: String? {
    lock.withLock { storedErrorDescription }
  }

  private func replaceDirectoryPath() {
    do {
      try FileManager.default.moveItem(
        at: originalDirectory,
        to: movedDirectory
      )
      try FileManager.default.createDirectory(
        at: originalDirectory,
        withIntermediateDirectories: false
      )
      try Data("replacement".utf8).write(
        to: originalDirectory.appendingPathComponent(Self.sentinelName)
      )
    } catch {
      lock.withLock { storedErrorDescription = String(describing: error) }
    }
  }
}

private final class RecoveryTrailingGrowthProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let directory: URL
  private var storedDidAppend = false
  private var storedErrorDescription: String?

  init(directory: URL) {
    self.directory = directory
  }

  var hooks: EncryptedFailedAudioRecoveryReadHooks {
    EncryptedFailedAudioRecoveryReadHooks(
      expectedBytesReadError: { _ in nil },
      didReadExpectedBytes: { [self] name in appendIfNeeded(named: name) },
      trailingEOFReadError: { _ in nil }
    )
  }

  var didAppend: Bool {
    lock.withLock { storedDidAppend }
  }

  var errorDescription: String? {
    lock.withLock { storedErrorDescription }
  }

  private func appendIfNeeded(named name: String) {
    guard name.hasSuffix(".vtreceipt") else { return }
    let shouldAppend = lock.withLock {
      guard !storedDidAppend else { return false }
      storedDidAppend = true
      return true
    }
    guard shouldAppend else { return }

    let descriptor = Darwin.open(
      directory.appendingPathComponent(name).path,
      O_WRONLY | O_APPEND | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      lock.withLock { storedErrorDescription = "open errno \(errno)" }
      return
    }
    defer { _ = Darwin.close(descriptor) }
    var trailingByte: UInt8 = 0x41
    guard Darwin.write(descriptor, &trailingByte, 1) == 1 else {
      lock.withLock { storedErrorDescription = "write errno \(errno)" }
      return
    }
  }
}

private final class RecoveryStoreInitializationProbe: @unchecked Sendable {
  private let lockContention = DispatchSemaphore(value: 0)
  private let finished = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var storedErrorDescription: String?

  var errorDescription: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedErrorDescription
  }

  func start(directoryURL: URL, keyByte: UInt8) {
    DispatchQueue.global().async { [self] in
      do {
        _ = try EncryptedFailedAudioRecoveryStore(
          directoryURL: directoryURL,
          localDataProtector: AESGCMDataProtector(
            key: Data(
              repeating: keyByte,
              count: AESGCMDataProtector.keyByteCount
            )
          ),
          policy: .default,
          fileManager: .default,
          evictionFileOperations: .live,
          directoryLockHooks: EncryptedFailedAudioRecoveryDirectoryLockHooks(
            didObserveContention: { [self] in lockContention.signal() }
          )
        )
      } catch {
        lock.lock()
        storedErrorDescription = String(describing: error)
        lock.unlock()
      }
      finished.signal()
    }
  }

  func waitUntilLockContention(timeout: TimeInterval) -> Bool {
    lockContention.wait(timeout: .now() + timeout) == .success
  }

  func waitUntilFinished(timeout: TimeInterval) -> Bool {
    finished.wait(timeout: .now() + timeout) == .success
  }
}

private struct RecoveryStoreFixture {
  let root: URL
  let recoveryDirectory: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
