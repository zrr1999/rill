import Darwin
import Foundation
import RillCore

struct EncryptedFailedAudioRecoveryEvictionFileOperations: Sendable {
  let renameItem:
    @Sendable (
      _ directoryDescriptor: Int32,
      _ sourceName: String,
      _ destinationName: String
    ) -> Int32
  let synchronizeDirectory: @Sendable (_ directoryDescriptor: Int32) -> Bool

  static let live = Self(
    renameItem: { directoryDescriptor, sourceName, destinationName in
      Darwin.renameat(
        directoryDescriptor,
        sourceName,
        directoryDescriptor,
        destinationName
      )
    },
    synchronizeDirectory: { directoryDescriptor in
      Darwin.fsync(directoryDescriptor) == 0
    }
  )
}

struct EncryptedFailedAudioRecoveryCommitHooks: Sendable {
  let didCommitAudioArtifact: @Sendable () -> Void

  static let live = Self(didCommitAudioArtifact: {})
}

struct EncryptedFailedAudioRecoveryReadHooks: Sendable {
  let expectedBytesReadError: @Sendable (_ name: String) -> Int32?
  let didReadExpectedBytes: @Sendable (_ name: String) -> Void
  let trailingEOFReadError: @Sendable (_ name: String) -> Int32?

  static let live = Self(
    expectedBytesReadError: { _ in nil },
    didReadExpectedBytes: { _ in },
    trailingEOFReadError: { _ in nil }
  )
}

struct EncryptedFailedAudioRecoveryDirectoryLockHooks: Sendable {
  let didObserveContention: @Sendable () -> Void

  static let live = Self(didObserveContention: {})
}

/// A bounded, local-only cache for recordings whose workflow failed before delivery.
///
/// Both the audio payload and its receipt are authenticated with field-specific
/// AAD before any bytes are written to the recovery directory.
public actor EncryptedFailedAudioRecoveryStore: FailedAudioRecoveryStore {
  public enum ExistingKeyProbeResult: Sendable, Equatable {
    case unbound
    case boundAndValid
  }

  private struct DirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
  }

  private static let audioSuffix = ".vtaudio"
  private static let receiptSuffix = ".vtreceipt"
  private static let temporarySuffix = ".vttmp"

  public let directoryURL: URL

  private let localDataProtector: any LocalDataProtector
  private let policy: FailedAudioRecoveryPolicy
  private let fileManager: FileManager
  private let evictionFileOperations: EncryptedFailedAudioRecoveryEvictionFileOperations
  private let commitHooks: EncryptedFailedAudioRecoveryCommitHooks
  private let readHooks: EncryptedFailedAudioRecoveryReadHooks
  private let directoryIdentity: DirectoryIdentity
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(
    directoryURL: URL,
    localDataProtector: any LocalDataProtector,
    policy: FailedAudioRecoveryPolicy = .default,
    fileManager: FileManager = .default
  ) throws {
    try self.init(
      directoryURL: directoryURL,
      localDataProtector: localDataProtector,
      policy: policy,
      fileManager: fileManager,
      evictionFileOperations: .live,
      commitHooks: .live,
      readHooks: .live,
      directoryLockHooks: .live
    )
  }

  init(
    directoryURL: URL,
    localDataProtector: any LocalDataProtector,
    policy: FailedAudioRecoveryPolicy,
    fileManager: FileManager,
    evictionFileOperations: EncryptedFailedAudioRecoveryEvictionFileOperations,
    commitHooks: EncryptedFailedAudioRecoveryCommitHooks = .live,
    readHooks: EncryptedFailedAudioRecoveryReadHooks = .live,
    directoryLockHooks: EncryptedFailedAudioRecoveryDirectoryLockHooks = .live
  ) throws {
    guard Self.isValid(policy: policy) else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    let standardizedDirectoryURL = directoryURL.standardizedFileURL
    self.directoryURL = standardizedDirectoryURL
    self.localDataProtector = localDataProtector
    self.policy = policy
    self.fileManager = fileManager
    self.evictionFileOperations = evictionFileOperations
    self.commitHooks = commitHooks
    self.readHooks = readHooks
    try Self.ensurePrivateDirectory(at: standardizedDirectoryURL, fileManager: fileManager)
    self.directoryIdentity = try Self.withExclusiveDirectoryLock(
      at: standardizedDirectoryURL,
      hooks: directoryLockHooks
    ) { directoryDescriptor in
      guard Darwin.fchmod(directoryDescriptor, S_IRWXU) == 0 else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      try Self.reconcileIncompleteEntries(
        relativeTo: directoryDescriptor
      )
      return try Self.identity(of: directoryDescriptor)
    }
  }

  public static func defaultDirectoryURL(
    fileManager: FileManager = .default
  ) throws -> URL {
    guard
      let appSupportURL = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    return
      appSupportURL
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("FailedAudioRecovery", isDirectory: true)
  }

  /// Authenticates every Rill-owned recovery artifact without changing
  /// the directory or initializing the mutable recovery store.
  ///
  /// An absent directory, or a directory containing no Rill artifacts,
  /// is unbound. Once any owned artifact exists, malformed or incomplete
  /// storage fails closed instead of being treated as permission to create a
  /// replacement local-data key.
  public static func probeExistingDataProtectionKey(
    directoryURL: URL,
    localDataProtector: any LocalDataProtector,
    policy: FailedAudioRecoveryPolicy = .default,
    fileManager: FileManager = .default
  ) throws -> ExistingKeyProbeResult {
    guard isValid(policy: policy) else {
      throw FailedAudioRecoveryError.storageUnavailable
    }

    let directoryURL = directoryURL.standardizedFileURL
    return try withExclusiveDirectoryLockIfPresent(
      at: directoryURL
    ) { directoryDescriptor in
      let entries = try directoryEntryNames(relativeTo: directoryDescriptor)

      let (maximumArtifactCount, artifactCountOverflow) = policy.maximumEntryCount
        .multipliedReportingOverflow(by: 2)
      guard !artifactCountOverflow else {
        throw FailedAudioRecoveryError.storageUnavailable
      }

      var ownedArtifactCount = 0
      var hasInvalidStructure = false
      var audioByID: [UUID: String] = [:]
      var receiptByID: [UUID: String] = [:]
      for entry in entries {
        guard let kind = probeArtifactKind(for: entry) else {
          continue
        }
        ownedArtifactCount += 1
        if ownedArtifactCount > maximumArtifactCount {
          hasInvalidStructure = true
        }
        guard
          try isRegularProbeArtifact(
            named: entry,
            relativeTo: directoryDescriptor
          )
        else {
          hasInvalidStructure = true
          continue
        }
        guard kind != .temporary else {
          hasInvalidStructure = true
          continue
        }

        let suffix = kind == .audio ? audioSuffix : receiptSuffix
        let rawID = String(entry.dropLast(suffix.count))
        guard let id = UUID(uuidString: rawID), rawID == id.uuidString else {
          hasInvalidStructure = true
          continue
        }
        switch kind {
        case .audio:
          if audioByID.updateValue(entry, forKey: id) != nil {
            hasInvalidStructure = true
          }
        case .receipt:
          if receiptByID.updateValue(entry, forKey: id) != nil {
            hasInvalidStructure = true
          }
        case .temporary:
          hasInvalidStructure = true
        }
      }

      guard ownedArtifactCount > 0 else { return .unbound }
      guard !hasInvalidStructure,
        audioByID.count == receiptByID.count,
        audioByID.count <= policy.maximumEntryCount,
        Set(audioByID.keys) == Set(receiptByID.keys)
      else {
        throw FailedAudioRecoveryError.invalidEntry
      }

      let envelopeByteLimit = try protectedEnvelopeByteLimit(for: policy)
      let decoder = JSONDecoder()
      var totalPlaintextBytes = 0
      for id in audioByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        guard let audioURL = audioByID[id],
          let receiptURL = receiptByID[id]
        else {
          throw FailedAudioRecoveryError.invalidEntry
        }
        let receipt = try probeReceipt(
          id: id,
          named: receiptURL,
          relativeTo: directoryDescriptor,
          localDataProtector: localDataProtector,
          policy: policy,
          decoder: decoder,
          envelopeByteLimit: envelopeByteLimit
        )
        let audioByteCount = try probeAudioByteCount(
          id: id,
          named: audioURL,
          relativeTo: directoryDescriptor,
          localDataProtector: localDataProtector,
          maximumEntryBytes: policy.maximumEntryBytes,
          envelopeByteLimit: envelopeByteLimit
        )
        guard audioByteCount == receipt.plaintextByteCount else {
          throw FailedAudioRecoveryError.invalidEntry
        }
        let (updatedTotal, totalOverflow) =
          totalPlaintextBytes
          .addingReportingOverflow(audioByteCount)
        guard !totalOverflow, updatedTotal <= policy.maximumTotalBytes else {
          throw FailedAudioRecoveryError.invalidEntry
        }
        totalPlaintextBytes = updatedTotal
      }
      return .boundAndValid
    } ?? .unbound
  }

  /// Removes only Rill-owned encrypted recovery artifacts without opening
  /// them. This keeps opt-out enforceable even when Keychain or the encrypted
  /// store cannot be initialized.
  public static func deleteOwnedArtifactsWithoutOpening(
    directoryURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let directoryURL = directoryURL.standardizedFileURL
    _ = try withExclusiveDirectoryLockIfPresent(
      at: directoryURL
    ) { directoryDescriptor in
      let entries = try directoryEntryNames(relativeTo: directoryDescriptor)
      for entry in entries {
        guard
          entry.hasSuffix(audioSuffix)
            || entry.hasSuffix(receiptSuffix)
            || entry.hasSuffix(temporarySuffix)
        else {
          continue
        }
        try removeNonDirectoryEntry(
          named: entry,
          relativeTo: directoryDescriptor
        )
      }
      guard fsync(directoryDescriptor) == 0 else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    }
  }

  /// A nonempty recovery directory is cryptographically bound to the existing
  /// local-data key and must never cause a replacement key to be generated.
  public static func requiresExistingDataProtectionKey(
    directoryURL: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    let directoryURL = directoryURL.standardizedFileURL
    do {
      return try withExclusiveDirectoryLockIfPresent(
        at: directoryURL
      ) { directoryDescriptor in
        let entries = try directoryEntryNames(relativeTo: directoryDescriptor)
        return entries.contains { entry in
          entry.hasSuffix(audioSuffix)
            || entry.hasSuffix(receiptSuffix)
            || entry.hasSuffix(temporarySuffix)
        }
      } ?? false
    } catch {
      // Key resolution must fail closed when the directory cannot be
      // inspected under the same coordination boundary as writers.
      return true
    }
  }

  public func preserve(
    audio: CapturedAudio,
    originalRunID: UUID,
    workflowID: UUID,
    failure: WorkflowRunFailureSummary,
    now: Date
  ) async throws -> FailedAudioRecoveryReceipt {
    guard failure.isCapturedAudioRecoveryEligible else {
      throw FailedAudioRecoveryError.unsupportedPayload
    }
    guard audio.fileOwnership == .managedTemporary,
      let sourceURL = audio.fileURL,
      sourceURL.isFileURL
    else {
      throw FailedAudioRecoveryError.unsupportedPayload
    }

    let plaintext = try readSourceAudio(from: sourceURL)
    return try withExclusiveDirectoryLock { directoryDescriptor in
      try preserveUnlocked(
        plaintext: plaintext,
        audio: audio,
        originalRunID: originalRunID,
        workflowID: workflowID,
        failure: failure,
        now: now,
        relativeTo: directoryDescriptor
      )
    }
  }

  private func preserveUnlocked(
    plaintext: Data,
    audio: CapturedAudio,
    originalRunID: UUID,
    workflowID: UUID,
    failure: WorkflowRunFailureSummary,
    now: Date,
    relativeTo directoryDescriptor: Int32
  ) throws -> FailedAudioRecoveryReceipt {
    _ = try purgeExpiredUnlocked(
      now: now,
      relativeTo: directoryDescriptor
    )
    let evictionCandidates = try evictionCandidatesToFit(
      addingBytes: plaintext.count,
      relativeTo: directoryDescriptor
    )

    let receipt = FailedAudioRecoveryReceipt(
      originalRunID: originalRunID,
      workflowID: workflowID,
      createdAt: now,
      expiresAt: now.addingTimeInterval(policy.retentionInterval),
      durationSeconds: audio.durationSeconds,
      format: audio.format,
      plaintextByteCount: plaintext.count,
      failureStage: failure.stage,
      failureCode: failure.code
    )

    let protectedAudio: String
    let protectedReceipt: String
    do {
      protectedAudio = try localDataProtector.seal(
        plaintext,
        context: Self.protectionContext(id: receipt.id, field: "audio")
      )
      protectedReceipt = try localDataProtector.seal(
        try encoder.encode(receipt),
        context: Self.protectionContext(id: receipt.id, field: "receipt")
      )
    } catch {
      throw FailedAudioRecoveryError.protectionUnavailable
    }

    let audioName = self.audioName(for: receipt.id)
    let receiptName = self.receiptName(for: receipt.id)
    do {
      try writePrivate(
        Data(protectedAudio.utf8),
        named: audioName,
        relativeTo: directoryDescriptor
      )
      commitHooks.didCommitAudioArtifact()
      try writePrivate(
        Data(protectedReceipt.utf8),
        named: receiptName,
        relativeTo: directoryDescriptor
      )
    } catch {
      try? Self.removeNonDirectoryEntry(
        named: audioName,
        relativeTo: directoryDescriptor
      )
      try? Self.removeNonDirectoryEntry(
        named: receiptName,
        relativeTo: directoryDescriptor
      )
      throw FailedAudioRecoveryError.storageUnavailable
    }
    do {
      try commitEvictions(
        evictionCandidates,
        relativeTo: directoryDescriptor
      )
    } catch EvictionCommitError.restored {
      try? removePair(id: receipt.id, relativeTo: directoryDescriptor)
      throw FailedAudioRecoveryError.storageUnavailable
    } catch {
      // The replacement pair is already durable. If rollback of an old
      // pair cannot be proven durable, retaining the replacement is the
      // only outcome that cannot lose both recordings.
      return receipt
    }
    return receipt
  }

  public func receipts(now: Date) async throws -> [FailedAudioRecoveryReceipt] {
    try withExclusiveDirectoryLock { directoryDescriptor in
      try Self.reconcileIncompleteEntries(
        relativeTo: directoryDescriptor
      )
      _ = try purgeExpiredUnlocked(
        now: now,
        relativeTo: directoryDescriptor
      )
      var authenticatedReceipts = try loadAllReceipts(
        relativeTo: directoryDescriptor
      )
      let quotaEvictions = evictionCandidatesToConverge(
        authenticatedReceipts
      )
      do {
        try commitEvictions(
          quotaEvictions,
          relativeTo: directoryDescriptor
        )
      } catch {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      let evictedIDs = Set(quotaEvictions.map(\.id))
      authenticatedReceipts.removeAll { evictedIDs.contains($0.id) }
      return authenticatedReceipts.sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    }
  }

  public func materializeForRetry(
    id: UUID,
    attemptID: UUID,
    now: Date
  ) async throws -> CapturedAudio {
    try withExclusiveDirectoryLock { directoryDescriptor in
      try materializeForRetryUnlocked(
        id: id,
        attemptID: attemptID,
        now: now,
        relativeTo: directoryDescriptor
      )
    }
  }

  private func materializeForRetryUnlocked(
    id: UUID,
    attemptID: UUID,
    now: Date,
    relativeTo directoryDescriptor: Int32
  ) throws -> CapturedAudio {
    var receipt = try loadReceipt(
      id: id,
      relativeTo: directoryDescriptor
    )
    guard !receipt.isExpired(at: now) else {
      try removePair(id: id, relativeTo: directoryDescriptor)
      throw FailedAudioRecoveryError.expired
    }
    guard receipt.status.canRetry else {
      throw FailedAudioRecoveryError.retryOutcomeUnknown
    }

    let availableReceipt = receipt
    receipt.status = .retrying(attemptID: attemptID, startedAt: now)
    try writeProtectedReceipt(receipt, relativeTo: directoryDescriptor)

    var temporaryURL: URL?
    do {
      let encryptedAudio = try readProtectedString(
        named: audioName(for: id),
        relativeTo: directoryDescriptor
      )
      let plaintext = try localDataProtector.open(
        encryptedAudio,
        context: Self.protectionContext(id: id, field: "audio")
      )
      guard plaintext.count == receipt.plaintextByteCount,
        !plaintext.isEmpty,
        plaintext.count <= policy.maximumEntryBytes
      else {
        throw FailedAudioRecoveryError.invalidEntry
      }

      let materializedURL = fileManager.temporaryDirectory
        .appendingPathComponent("rill-recovery-\(UUID().uuidString).wav")
      temporaryURL = materializedURL
      try writeDecryptedTemporary(plaintext, to: materializedURL)
      return try CapturedAudio(
        durationSeconds: receipt.durationSeconds,
        format: receipt.format,
        fileURL: materializedURL,
        fileOwnership: .managedTemporary
      )
    } catch {
      if let temporaryURL {
        try? fileManager.removeItem(at: temporaryURL)
      }
      // No provider request has begun, so a local materialization
      // failure can safely return this entry to the available state.
      try? writeProtectedReceipt(
        availableReceipt,
        relativeTo: directoryDescriptor
      )
      if let recoveryError = error as? FailedAudioRecoveryError {
        throw recoveryError
      }
      if error is LocalDataProtectionError || error is CapturedAudio.ValidationError {
        throw FailedAudioRecoveryError.invalidEntry
      }
      throw FailedAudioRecoveryError.storageUnavailable
    }
  }

  public func restoreAfterFailedRetry(id: UUID, attemptID: UUID) async throws {
    try withExclusiveDirectoryLock { directoryDescriptor in
      var receipt = try loadReceipt(
        id: id,
        relativeTo: directoryDescriptor
      )
      guard case .retrying(let storedAttemptID, _) = receipt.status,
        storedAttemptID == attemptID
      else {
        throw FailedAudioRecoveryError.retryOutcomeUnknown
      }
      receipt.status = .available
      try writeProtectedReceipt(receipt, relativeTo: directoryDescriptor)
    }
  }

  public func delete(id: UUID) async throws {
    try withExclusiveDirectoryLock { directoryDescriptor in
      do {
        try removePair(id: id, relativeTo: directoryDescriptor)
      } catch {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    }
  }

  public func deleteAll() async throws {
    try withExclusiveDirectoryLock { directoryDescriptor in
      let entries = try Self.directoryEntryNames(relativeTo: directoryDescriptor)
      do {
        for entry in entries {
          guard
            entry.hasSuffix(Self.audioSuffix)
              || entry.hasSuffix(Self.receiptSuffix)
              || entry.hasSuffix(Self.temporarySuffix)
          else {
            continue
          }
          try Self.removeNonDirectoryEntry(
            named: entry,
            relativeTo: directoryDescriptor
          )
        }
        guard fsync(directoryDescriptor) == 0 else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
      } catch {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    }
  }

  public func purgeExpired(now: Date) async throws -> Int {
    try withExclusiveDirectoryLock { directoryDescriptor in
      try purgeExpiredUnlocked(
        now: now,
        relativeTo: directoryDescriptor
      )
    }
  }

  private func purgeExpiredUnlocked(
    now: Date,
    relativeTo directoryDescriptor: Int32
  ) throws -> Int {
    // Validate owned artifacts on every maintenance pass without deleting
    // files that may still belong to a lockless legacy writer.
    try Self.reconcileIncompleteEntries(
      relativeTo: directoryDescriptor
    )
    try synchronizeDirectory(directoryDescriptor)
    let entries = try Self.directoryEntryNames(relativeTo: directoryDescriptor)

    var removedCount = 0
    var firstError: FailedAudioRecoveryError?
    for entry in entries where entry.hasSuffix(Self.receiptSuffix) {
      let rawID = String(
        entry.dropLast(Self.receiptSuffix.count)
      )
      guard let id = UUID(uuidString: rawID) else {
        if firstError == nil { firstError = .invalidEntry }
        continue
      }

      do {
        let receipt = try loadReceipt(
          id: id,
          relativeTo: directoryDescriptor
        )
        guard receipt.isExpired(at: now) else { continue }
        try removePair(id: id, relativeTo: directoryDescriptor)
        removedCount += 1
      } catch {
        let receiptError =
          error as? FailedAudioRecoveryError
          ?? .storageUnavailable
        do {
          guard
            try unreadablePairReachedFallbackExpiry(
              id: id,
              now: now,
              relativeTo: directoryDescriptor
            )
          else {
            if firstError == nil { firstError = receiptError }
            continue
          }
          try removePair(id: id, relativeTo: directoryDescriptor)
          removedCount += 1
        } catch {
          if firstError == nil {
            firstError =
              error as? FailedAudioRecoveryError
              ?? .storageUnavailable
          }
        }
      }
    }
    if let firstError {
      throw firstError
    }
    return removedCount
  }

  private func unreadablePairReachedFallbackExpiry(
    id: UUID,
    now: Date,
    relativeTo directoryDescriptor: Int32
  ) throws -> Bool {
    let audioModificationDate = try artifactModificationDate(
      named: audioName(for: id),
      relativeTo: directoryDescriptor
    )
    let receiptModificationDate = try artifactModificationDate(
      named: receiptName(for: id),
      relativeTo: directoryDescriptor
    )
    // Receipt ciphertext is legitimately rewritten when a retry starts or
    // is restored. The earlier artifact timestamp keeps that rewrite from
    // extending the fail-closed retention window beyond the audio pair's
    // original lifetime.
    let earliestModificationDate = min(
      audioModificationDate,
      receiptModificationDate
    )
    return earliestModificationDate.addingTimeInterval(
      policy.retentionInterval
    ) <= now
  }

  private func artifactModificationDate(
    named name: String,
    relativeTo directoryDescriptor: Int32
  ) throws -> Date {
    var info = stat()
    guard
      fstatat(
        directoryDescriptor,
        name,
        &info,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    else {
      if errno == ENOENT { throw FailedAudioRecoveryError.invalidEntry }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    let kind = info.st_mode & S_IFMT
    guard kind == S_IFREG || kind == S_IFLNK else {
      throw FailedAudioRecoveryError.invalidEntry
    }
    return Date(
      timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    )
  }

  private func evictionCandidatesToFit(
    addingBytes: Int,
    relativeTo directoryDescriptor: Int32
  ) throws -> [FailedAudioRecoveryReceipt] {
    var receipts = try loadAllReceipts(relativeTo: directoryDescriptor).sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    var totalBytes = receipts.reduce(0) { $0 + $1.plaintextByteCount }
    var evictions: [FailedAudioRecoveryReceipt] = []
    while !receipts.isEmpty,
      receipts.count >= policy.maximumEntryCount
        || totalBytes + addingBytes > policy.maximumTotalBytes
    {
      let oldest = receipts.removeFirst()
      totalBytes -= oldest.plaintextByteCount
      evictions.append(oldest)
    }
    guard totalBytes + addingBytes <= policy.maximumTotalBytes else {
      throw FailedAudioRecoveryError.entryTooLarge
    }
    return evictions
  }

  private func evictionCandidatesToConverge(
    _ authenticatedReceipts: [FailedAudioRecoveryReceipt]
  ) -> [FailedAudioRecoveryReceipt] {
    var receipts = authenticatedReceipts.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    var totalBytes = receipts.reduce(0) { $0 + $1.plaintextByteCount }
    var evictions: [FailedAudioRecoveryReceipt] = []
    while !receipts.isEmpty,
      receipts.count > policy.maximumEntryCount
        || totalBytes > policy.maximumTotalBytes
    {
      let oldest = receipts.removeFirst()
      totalBytes -= oldest.plaintextByteCount
      evictions.append(oldest)
    }
    return evictions
  }

  private struct StagedEviction {
    let audioName: String
    let receiptName: String
    let stagedAudioName: String
    let stagedReceiptName: String
  }

  private enum EvictionCommitError: Error {
    case restored
    case rollbackUncertain
  }

  /// Commits quota eviction only after the replacement pair is durable.
  /// Old pairs are first renamed to ignored, encrypted staging names. A
  /// staging failure attempts a durable rollback; the caller discards the
  /// replacement only when every restore rename and directory sync succeeds.
  private func commitEvictions(
    _ receipts: [FailedAudioRecoveryReceipt],
    relativeTo directoryDescriptor: Int32
  ) throws {
    guard !receipts.isEmpty else { return }
    var staged: [StagedEviction] = []
    var pendingAudioOnly: StagedEviction?
    do {
      for receipt in receipts {
        let audioName = audioName(for: receipt.id)
        let receiptName = receiptName(for: receipt.id)
        let token = UUID().uuidString
        let stagedAudioName = ".evict-\(token)-audio\(Self.temporarySuffix)"
        let stagedReceiptName = ".evict-\(token)-receipt\(Self.temporarySuffix)"
        let entry = StagedEviction(
          audioName: audioName,
          receiptName: receiptName,
          stagedAudioName: stagedAudioName,
          stagedReceiptName: stagedReceiptName
        )
        guard
          evictionFileOperations.renameItem(
            directoryDescriptor,
            audioName,
            stagedAudioName
          ) == 0
        else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        pendingAudioOnly = entry
        guard
          evictionFileOperations.renameItem(
            directoryDescriptor,
            receiptName,
            stagedReceiptName
          ) == 0
        else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        staged.append(entry)
        pendingAudioOnly = nil
      }
      guard evictionFileOperations.synchronizeDirectory(directoryDescriptor) else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    } catch {
      let restored = rollbackEvictions(
        staged,
        pendingAudioOnly: pendingAudioOnly,
        relativeTo: directoryDescriptor
      )
      throw restored
        ? EvictionCommitError.restored
        : EvictionCommitError.rollbackUncertain
    }

    // The logical eviction is committed once the staging renames are
    // durable. Cleanup failures leave only authenticated ciphertext with
    // the owned temporary suffix. Reconciliation preserves those artifacts
    // so a later process cannot guess that another writer no longer owns them.
    for entry in staged {
      try? Self.removeNonDirectoryEntry(
        named: entry.stagedAudioName,
        relativeTo: directoryDescriptor
      )
      try? Self.removeNonDirectoryEntry(
        named: entry.stagedReceiptName,
        relativeTo: directoryDescriptor
      )
    }
    try? synchronizeDirectory(directoryDescriptor)
  }

  private func rollbackEvictions(
    _ staged: [StagedEviction],
    pendingAudioOnly: StagedEviction?,
    relativeTo directoryDescriptor: Int32
  ) -> Bool {
    var restored = true
    let changedDirectory = pendingAudioOnly != nil || !staged.isEmpty

    if let pendingAudioOnly,
      evictionFileOperations.renameItem(
        directoryDescriptor,
        pendingAudioOnly.stagedAudioName,
        pendingAudioOnly.audioName
      ) != 0
    {
      restored = false
    }
    for entry in staged.reversed() {
      if evictionFileOperations.renameItem(
        directoryDescriptor,
        entry.stagedReceiptName,
        entry.receiptName
      ) != 0 {
        restored = false
      }
      if evictionFileOperations.renameItem(
        directoryDescriptor,
        entry.stagedAudioName,
        entry.audioName
      ) != 0 {
        restored = false
      }
    }
    if changedDirectory,
      !evictionFileOperations.synchronizeDirectory(directoryDescriptor)
    {
      restored = false
    }
    return restored
  }

  private func removePair(
    id: UUID,
    relativeTo directoryDescriptor: Int32
  ) throws {
    // Audio is removed before its index. If the first unlink fails, the
    // receipt remains usable and accurately represents the store state.
    for name in [audioName(for: id), receiptName(for: id)] {
      try Self.removeNonDirectoryEntry(
        named: name,
        relativeTo: directoryDescriptor
      )
    }
    try synchronizeDirectory(directoryDescriptor)
  }

  private func writeProtectedReceipt(
    _ receipt: FailedAudioRecoveryReceipt,
    relativeTo directoryDescriptor: Int32
  ) throws {
    let protectedReceipt: String
    do {
      protectedReceipt = try localDataProtector.seal(
        try encoder.encode(receipt),
        context: Self.protectionContext(id: receipt.id, field: "receipt")
      )
    } catch {
      throw FailedAudioRecoveryError.protectionUnavailable
    }
    try writePrivate(
      Data(protectedReceipt.utf8),
      named: receiptName(for: receipt.id),
      relativeTo: directoryDescriptor
    )
  }

  private func synchronizeDirectory(_ directoryDescriptor: Int32) throws {
    guard fsync(directoryDescriptor) == 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
  }

  private func withExclusiveDirectoryLock<T>(
    _ operation: (_ directoryDescriptor: Int32) throws -> T
  ) throws -> T {
    try Self.withExclusiveDirectoryLock(at: directoryURL) { directoryDescriptor in
      guard try Self.identity(of: directoryDescriptor) == directoryIdentity else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      return try operation(directoryDescriptor)
    }
  }

  private func loadAllReceipts(
    relativeTo directoryDescriptor: Int32
  ) throws -> [FailedAudioRecoveryReceipt] {
    let entries = try Self.directoryEntryNames(relativeTo: directoryDescriptor)

    return try entries.compactMap { name in
      guard name.hasSuffix(Self.receiptSuffix) else { return nil }
      let rawID = String(name.dropLast(Self.receiptSuffix.count))
      guard let id = UUID(uuidString: rawID) else {
        throw FailedAudioRecoveryError.invalidEntry
      }
      return try loadReceipt(id: id, relativeTo: directoryDescriptor)
    }
  }

  private func loadReceipt(
    id: UUID,
    relativeTo directoryDescriptor: Int32
  ) throws -> FailedAudioRecoveryReceipt {
    let protectedReceipt = try readProtectedString(
      named: receiptName(for: id),
      relativeTo: directoryDescriptor
    )
    let plaintext: Data
    do {
      plaintext = try localDataProtector.open(
        protectedReceipt,
        context: Self.protectionContext(id: id, field: "receipt")
      )
    } catch {
      throw FailedAudioRecoveryError.invalidEntry
    }
    let receipt: FailedAudioRecoveryReceipt
    do {
      receipt = try decoder.decode(FailedAudioRecoveryReceipt.self, from: plaintext)
    } catch {
      throw FailedAudioRecoveryError.invalidEntry
    }
    guard receipt.id == id,
      receipt.createdAt < receipt.expiresAt,
      receipt.durationSeconds.isFinite,
      receipt.durationSeconds >= 0,
      receipt.format.sampleRateHz.isFinite,
      receipt.format.sampleRateHz > 0,
      (1...8).contains(receipt.format.channelCount),
      (1...policy.maximumEntryBytes).contains(receipt.plaintextByteCount),
      try Self.isRegularProbeArtifact(
        named: audioName(for: id),
        relativeTo: directoryDescriptor
      )
    else {
      throw FailedAudioRecoveryError.invalidEntry
    }
    return receipt
  }

  private func readProtectedString(
    named name: String,
    relativeTo directoryDescriptor: Int32
  ) throws -> String {
    do {
      let (doubledLimit, overflow) = policy.maximumEntryBytes
        .multipliedReportingOverflow(by: 2)
      let (envelopeLimit, additionOverflow) =
        doubledLimit
        .addingReportingOverflow(65_536)
      guard !overflow, !additionOverflow else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      let data = try readBoundedRegularFile(
        named: name,
        relativeTo: directoryDescriptor,
        maximumBytes: envelopeLimit
      )
      guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
        throw FailedAudioRecoveryError.invalidEntry
      }
      return value
    } catch let error as FailedAudioRecoveryError {
      throw error
    } catch {
      throw FailedAudioRecoveryError.storageUnavailable
    }
  }

  private func readBoundedRegularFile(
    named name: String,
    relativeTo directoryDescriptor: Int32,
    maximumBytes: Int
  ) throws -> Data {
    let descriptor = openat(
      directoryDescriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ENOENT { throw FailedAudioRecoveryError.notFound }
      if errno == ELOOP { throw FailedAudioRecoveryError.invalidEntry }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    defer { _ = close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    guard (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1,
      info.st_size > 0,
      info.st_size <= Int64(maximumBytes)
    else {
      throw FailedAudioRecoveryError.invalidEntry
    }

    let data = try Self.readExactly(
      byteCount: Int(info.st_size),
      from: descriptor,
      forcedReadError: readHooks.expectedBytesReadError(name)
    )
    readHooks.didReadExpectedBytes(name)
    try Self.requireEndOfFile(
      on: descriptor,
      forcedReadError: readHooks.trailingEOFReadError(name)
    )
    return data
  }

  private func writePrivate(
    _ data: Data,
    named name: String,
    relativeTo directoryDescriptor: Int32
  ) throws {
    let temporaryName = ".\(UUID().uuidString)\(Self.temporarySuffix)"
    do {
      try writeNewPrivateFile(
        data,
        named: temporaryName,
        relativeTo: directoryDescriptor
      )
      guard
        renameat(
          directoryDescriptor,
          temporaryName,
          directoryDescriptor,
          name
        ) == 0
      else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      guard fsync(directoryDescriptor) == 0 else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    } catch let error as FailedAudioRecoveryError {
      try? Self.removeNonDirectoryEntry(
        named: temporaryName,
        relativeTo: directoryDescriptor
      )
      throw error
    } catch {
      try? Self.removeNonDirectoryEntry(
        named: temporaryName,
        relativeTo: directoryDescriptor
      )
      throw FailedAudioRecoveryError.storageUnavailable
    }
  }

  private func readSourceAudio(from url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ELOOP || errno == ENOENT {
        throw FailedAudioRecoveryError.unsupportedPayload
      }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    defer { _ = close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw FailedAudioRecoveryError.unsupportedPayload
    }
    guard info.st_size > 0, info.st_size <= Int64(Int.max) else {
      throw FailedAudioRecoveryError.invalidEntry
    }
    guard info.st_size <= Int64(policy.maximumEntryBytes) else {
      throw FailedAudioRecoveryError.entryTooLarge
    }

    var data = Data(count: Int(info.st_size))
    try data.withUnsafeMutableBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        throw FailedAudioRecoveryError.invalidEntry
      }
      var readByteCount = 0
      while readByteCount < rawBuffer.count {
        let result = Darwin.read(
          descriptor,
          baseAddress.advanced(by: readByteCount),
          rawBuffer.count - readByteCount
        )
        if result < 0, errno == EINTR {
          continue
        }
        guard result > 0 else {
          throw FailedAudioRecoveryError.invalidEntry
        }
        readByteCount += result
      }
    }
    return data
  }

  private func writeDecryptedTemporary(_ data: Data, to url: URL) throws {
    try writeNewPrivateFile(data, toExternalURL: url)
  }

  private func writeNewPrivateFile(
    _ data: Data,
    named name: String,
    relativeTo directoryDescriptor: Int32
  ) throws {
    let descriptor = openat(
      directoryDescriptor,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    var shouldRemove = true
    defer {
      _ = close(descriptor)
      if shouldRemove {
        try? Self.removeNonDirectoryEntry(
          named: name,
          relativeTo: directoryDescriptor
        )
      }
    }

    try writeAndSynchronize(
      data,
      to: descriptor,
      didFinish: { shouldRemove = false }
    )
  }

  private func writeNewPrivateFile(
    _ data: Data,
    toExternalURL url: URL
  ) throws {
    let descriptor = open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    var shouldRemove = true
    defer {
      _ = close(descriptor)
      if shouldRemove {
        _ = Darwin.unlink(url.path)
      }
    }

    try writeAndSynchronize(
      data,
      to: descriptor,
      didFinish: { shouldRemove = false }
    )
  }

  private func writeAndSynchronize(
    _ data: Data,
    to descriptor: Int32,
    didFinish: () -> Void
  ) throws {
    do {
      try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var writtenByteCount = 0
        while writtenByteCount < rawBuffer.count {
          let result = Darwin.write(
            descriptor,
            baseAddress.advanced(by: writtenByteCount),
            rawBuffer.count - writtenByteCount
          )
          if result < 0, errno == EINTR { continue }
          guard result > 0 else {
            throw FailedAudioRecoveryError.storageUnavailable
          }
          writtenByteCount += result
        }
      }
      guard fsync(descriptor) == 0 else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      didFinish()
    } catch let error as FailedAudioRecoveryError {
      throw error
    } catch {
      throw FailedAudioRecoveryError.storageUnavailable
    }
  }

  private func audioName(for id: UUID) -> String {
    id.uuidString + Self.audioSuffix
  }

  private func receiptName(for id: UUID) -> String {
    id.uuidString + Self.receiptSuffix
  }

  private enum ProbeArtifactKind: Equatable {
    case audio
    case receipt
    case temporary
  }

  private static func isValid(policy: FailedAudioRecoveryPolicy) -> Bool {
    policy.retentionInterval.isFinite
      && policy.retentionInterval > 0
      && policy.maximumEntryCount > 0
      && policy.maximumEntryBytes > 0
      && policy.maximumTotalBytes >= policy.maximumEntryBytes
  }

  private static func probeArtifactKind(for name: String) -> ProbeArtifactKind? {
    if name.hasSuffix(temporarySuffix) { return .temporary }
    if name.hasSuffix(audioSuffix) { return .audio }
    if name.hasSuffix(receiptSuffix) { return .receipt }
    return nil
  }

  private static func isRegularProbeArtifact(
    named name: String,
    relativeTo directoryDescriptor: Int32
  ) throws -> Bool {
    var info = stat()
    guard
      fstatat(
        directoryDescriptor,
        name,
        &info,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    else {
      if errno == ENOENT { return false }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
  }

  private static func protectedEnvelopeByteLimit(
    for policy: FailedAudioRecoveryPolicy
  ) throws -> Int {
    let (doubledLimit, multiplicationOverflow) = policy.maximumEntryBytes
      .multipliedReportingOverflow(by: 2)
    let (envelopeLimit, additionOverflow) =
      doubledLimit
      .addingReportingOverflow(65_536)
    guard !multiplicationOverflow, !additionOverflow else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    return envelopeLimit
  }

  private static func probeReceipt(
    id: UUID,
    named name: String,
    relativeTo directoryDescriptor: Int32,
    localDataProtector: any LocalDataProtector,
    policy: FailedAudioRecoveryPolicy,
    decoder: JSONDecoder,
    envelopeByteLimit: Int
  ) throws -> FailedAudioRecoveryReceipt {
    let envelope = try readProbeProtectedString(
      named: name,
      relativeTo: directoryDescriptor,
      maximumBytes: envelopeByteLimit
    )
    let plaintext: Data
    do {
      plaintext = try localDataProtector.open(
        envelope,
        context: protectionContext(id: id, field: "receipt")
      )
    } catch {
      throw FailedAudioRecoveryError.invalidEntry
    }

    let receipt: FailedAudioRecoveryReceipt
    do {
      receipt = try decoder.decode(
        FailedAudioRecoveryReceipt.self,
        from: plaintext
      )
    } catch {
      throw FailedAudioRecoveryError.invalidEntry
    }
    let createdAt = receipt.createdAt.timeIntervalSinceReferenceDate
    let expiresAt = receipt.expiresAt.timeIntervalSinceReferenceDate
    let statusDateIsValid: Bool
    switch receipt.status {
    case .available:
      statusDateIsValid = true
    case .retrying(_, let startedAt):
      statusDateIsValid = startedAt.timeIntervalSinceReferenceDate.isFinite
    }
    guard receipt.id == id,
      createdAt.isFinite,
      expiresAt.isFinite,
      receipt.createdAt < receipt.expiresAt,
      receipt.durationSeconds.isFinite,
      receipt.durationSeconds >= 0,
      receipt.format.sampleRateHz.isFinite,
      receipt.format.sampleRateHz > 0,
      (1...8).contains(receipt.format.channelCount),
      (1...policy.maximumEntryBytes).contains(receipt.plaintextByteCount),
      statusDateIsValid
    else {
      throw FailedAudioRecoveryError.invalidEntry
    }
    return receipt
  }

  private static func probeAudioByteCount(
    id: UUID,
    named name: String,
    relativeTo directoryDescriptor: Int32,
    localDataProtector: any LocalDataProtector,
    maximumEntryBytes: Int,
    envelopeByteLimit: Int
  ) throws -> Int {
    let envelope = try readProbeProtectedString(
      named: name,
      relativeTo: directoryDescriptor,
      maximumBytes: envelopeByteLimit
    )
    let plaintext: Data
    do {
      plaintext = try localDataProtector.open(
        envelope,
        context: protectionContext(id: id, field: "audio")
      )
    } catch {
      throw FailedAudioRecoveryError.invalidEntry
    }
    guard !plaintext.isEmpty, plaintext.count <= maximumEntryBytes else {
      throw FailedAudioRecoveryError.invalidEntry
    }
    return plaintext.count
  }

  private static func readProbeProtectedString(
    named name: String,
    relativeTo directoryDescriptor: Int32,
    maximumBytes: Int
  ) throws -> String {
    let descriptor = openat(
      directoryDescriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ENOENT || errno == ELOOP {
        throw FailedAudioRecoveryError.invalidEntry
      }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    defer { _ = close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    guard (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1,
      info.st_size > 0,
      info.st_size <= Int64(maximumBytes)
    else {
      throw FailedAudioRecoveryError.invalidEntry
    }

    let data = try readExactly(
      byteCount: Int(info.st_size),
      from: descriptor
    )
    try requireEndOfFile(on: descriptor)
    guard let envelope = String(data: data, encoding: .utf8),
      !envelope.isEmpty
    else {
      throw FailedAudioRecoveryError.invalidEntry
    }
    return envelope
  }

  private static func readExactly(
    byteCount: Int,
    from descriptor: Int32,
    forcedReadError: Int32? = nil
  ) throws -> Data {
    var pendingForcedReadError = forcedReadError
    var data = Data(count: byteCount)
    try data.withUnsafeMutableBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        throw FailedAudioRecoveryError.invalidEntry
      }
      var readByteCount = 0
      while readByteCount < rawBuffer.count {
        let result: Int
        if let forcedError = pendingForcedReadError {
          pendingForcedReadError = nil
          errno = forcedError
          result = -1
        } else {
          result = Darwin.read(
            descriptor,
            baseAddress.advanced(by: readByteCount),
            rawBuffer.count - readByteCount
          )
        }
        if result < 0 {
          if errno == EINTR { continue }
          throw FailedAudioRecoveryError.storageUnavailable
        }
        guard result > 0 else {
          throw FailedAudioRecoveryError.invalidEntry
        }
        readByteCount += result
      }
    }
    return data
  }

  private static func requireEndOfFile(
    on descriptor: Int32,
    forcedReadError: Int32? = nil
  ) throws {
    var pendingForcedReadError = forcedReadError
    var trailingByte: UInt8 = 0
    while true {
      let result: Int
      if let forcedError = pendingForcedReadError {
        pendingForcedReadError = nil
        errno = forcedError
        result = -1
      } else {
        result = Darwin.read(descriptor, &trailingByte, 1)
      }
      if result < 0 {
        if errno == EINTR { continue }
        throw FailedAudioRecoveryError.storageUnavailable
      }
      guard result == 0 else {
        throw FailedAudioRecoveryError.invalidEntry
      }
      return
    }
  }

  private static func protectionContext(id: UUID, field: String) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "failed_audio_recovery",
      recordID: id.uuidString,
      field: field
    )
  }

  private static func ensurePrivateDirectory(
    at directoryURL: URL,
    fileManager: FileManager
  ) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue, !isSymbolicLink(at: directoryURL) else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    } else {
      do {
        try fileManager.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      } catch {
        throw FailedAudioRecoveryError.storageUnavailable
      }
    }
  }

  private static func reconcileIncompleteEntries(
    relativeTo directoryDescriptor: Int32
  ) throws {
    let entries = try directoryEntryNames(relativeTo: directoryDescriptor)

    for name in entries {
      if name.hasSuffix(temporarySuffix) {
        guard isRecognizedTemporaryArtifactName(name),
          try isRegularProbeArtifact(
            named: name,
            relativeTo: directoryDescriptor
          )
        else {
          throw FailedAudioRecoveryError.invalidEntry
        }
        continue
      }

      let suffix: String
      if name.hasSuffix(audioSuffix) {
        suffix = audioSuffix
      } else if name.hasSuffix(receiptSuffix) {
        suffix = receiptSuffix
      } else {
        continue
      }
      let rawID = String(name.dropLast(suffix.count))
      guard let id = UUID(uuidString: rawID), rawID == id.uuidString,
        try isRegularProbeArtifact(
          named: name,
          relativeTo: directoryDescriptor
        )
      else {
        throw FailedAudioRecoveryError.invalidEntry
      }
    }
  }

  private static func isRecognizedTemporaryArtifactName(_ name: String) -> Bool {
    guard name.hasSuffix(temporarySuffix) else { return false }
    let stem = String(name.dropLast(temporarySuffix.count))
    if stem.first == ".",
      let id = UUID(uuidString: String(stem.dropFirst())),
      stem == "." + id.uuidString
    {
      return true
    }

    let evictionPrefix = ".evict-"
    guard stem.hasPrefix(evictionPrefix) else { return false }
    for kind in ["-audio", "-receipt"] where stem.hasSuffix(kind) {
      let rawID = String(
        stem.dropFirst(evictionPrefix.count).dropLast(kind.count)
      )
      if let id = UUID(uuidString: rawID), rawID == id.uuidString {
        return true
      }
    }
    return false
  }

  private static func withExclusiveDirectoryLock<T>(
    at directoryURL: URL,
    hooks: EncryptedFailedAudioRecoveryDirectoryLockHooks = .live,
    _ operation: (_ directoryDescriptor: Int32) throws -> T
  ) throws -> T {
    guard
      let result = try withExclusiveDirectoryLockIfPresent(
        at: directoryURL,
        hooks: hooks,
        operation
      )
    else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    return result
  }

  private static func identity(
    of directoryDescriptor: Int32
  ) throws -> DirectoryIdentity {
    var info = stat()
    guard Darwin.fstat(directoryDescriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR
    else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    return DirectoryIdentity(
      device: UInt64(truncatingIfNeeded: info.st_dev),
      inode: UInt64(truncatingIfNeeded: info.st_ino)
    )
  }

  private static func withExclusiveDirectoryLockIfPresent<T>(
    at directoryURL: URL,
    hooks: EncryptedFailedAudioRecoveryDirectoryLockHooks = .live,
    _ operation: (_ directoryDescriptor: Int32) throws -> T
  ) throws -> T? {
    let descriptor = Darwin.open(
      directoryURL.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
    )
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw FailedAudioRecoveryError.storageUnavailable
    }
    defer { _ = Darwin.close(descriptor) }

    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR
    else {
      throw FailedAudioRecoveryError.storageUnavailable
    }

    while true {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
      let lockError = errno
      if lockError == EINTR { continue }
      guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
        throw FailedAudioRecoveryError.storageUnavailable
      }
      hooks.didObserveContention()
      while flock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
      }
      break
    }
    return try operation(descriptor)
  }

  private static func directoryEntryNames(
    relativeTo directoryDescriptor: Int32
  ) throws -> [String] {
    let enumerationDescriptor = Darwin.openat(
      directoryDescriptor,
      ".",
      O_RDONLY | O_CLOEXEC | O_DIRECTORY
    )
    guard enumerationDescriptor >= 0 else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
      _ = Darwin.close(enumerationDescriptor)
      throw FailedAudioRecoveryError.storageUnavailable
    }
    defer { _ = Darwin.closedir(directory) }

    var names: [String] = []
    while true {
      errno = 0
      guard let entry = Darwin.readdir(directory) else {
        guard errno == 0 else {
          throw FailedAudioRecoveryError.storageUnavailable
        }
        return names
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
        namePointer.withMemoryRebound(
          to: CChar.self,
          capacity: Int(entry.pointee.d_namlen) + 1
        ) { String(cString: $0) }
      }
      guard name != ".", name != ".." else { continue }
      guard isSafeRelativeName(name) else {
        throw FailedAudioRecoveryError.invalidEntry
      }
      names.append(name)
    }
  }

  private static func removeNonDirectoryEntry(
    named name: String,
    relativeTo directoryDescriptor: Int32
  ) throws {
    guard isSafeRelativeName(name) else {
      throw FailedAudioRecoveryError.storageUnavailable
    }
    let result = Darwin.unlinkat(directoryDescriptor, name, 0)
    if result == 0 || errno == ENOENT { return }
    // unlink and unlinkat never recursively remove directories. In
    // particular, a directory substituted for an artifact remains intact.
    throw FailedAudioRecoveryError.storageUnavailable
  }

  private static func isSafeRelativeName(_ name: String) -> Bool {
    !name.isEmpty
      && name != "."
      && name != ".."
      && !name.contains("/")
      && !name.utf8.contains(0)
  }

  private static func isSymbolicLink(at url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFLNK
  }
}
