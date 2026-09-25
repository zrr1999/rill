import Darwin
import Foundation
import RillCore

/// An opt-in, local-only archive of recordings selected for personal ASR evaluation.
///
/// Audio and metadata use separate authenticated fields under the same root key as
/// other protected local Rill content. The directory marker binds an unbounded archive
/// without decrypting every audio artifact during application startup.
public actor EncryptedBenchmarkRecordingArchiveStore: BenchmarkRecordingArchiveStore, BenchmarkRecordingArchiveReading {
  public enum ExistingKeyProbeResult: Sendable, Equatable {
    case unbound
    case boundAndValid
  }

  private static let audioSuffix = ".rillaudio"
  private static let receiptSuffix = ".rillmeta"
  private static let temporarySuffix = ".rilltmp"
  private static let markerName = ".key-verification"
  private static let markerPlaintext = Data("Rill benchmark recording key verification v1".utf8)
  private static let namespace = "benchmark_recordings"

  public let directoryURL: URL

  private let localDataProtector: any LocalDataProtector
  private let fileManager: FileManager
  private let encoder = JSONEncoder()

  public init(
    directoryURL: URL,
    localDataProtector: any LocalDataProtector,
    fileManager: FileManager = .default
  ) throws {
    self.directoryURL = directoryURL.standardizedFileURL
    self.localDataProtector = localDataProtector
    self.fileManager = fileManager
    try Self.ensurePrivateDirectory(at: self.directoryURL, fileManager: fileManager)
    try Self.prepareKeyBinding(
      directoryURL: self.directoryURL,
      localDataProtector: localDataProtector,
      fileManager: fileManager
    )
    try Self.removeTemporaryArtifacts(
      directoryURL: self.directoryURL,
      fileManager: fileManager
    )
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
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    return
      appSupportURL
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("BenchmarkRecordings", isDirectory: true)
  }

  public static func requiresExistingDataProtectionKey(
    directoryURL: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    let directoryURL = directoryURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
      return false
    }
    guard isDirectory.boolValue else { return true }
    do {
      return try fileManager.contentsOfDirectory(atPath: directoryURL.path).contains {
        $0 == markerName
          || $0.hasSuffix(audioSuffix)
          || $0.hasSuffix(receiptSuffix)
          || $0.hasSuffix(temporarySuffix)
      }
    } catch {
      return true
    }
  }

  public static func probeExistingDataProtectionKey(
    directoryURL: URL,
    localDataProtector: any LocalDataProtector,
    fileManager: FileManager = .default
  ) throws -> ExistingKeyProbeResult {
    let directoryURL = directoryURL.standardizedFileURL
    guard requiresExistingDataProtectionKey(directoryURL: directoryURL, fileManager: fileManager)
    else {
      return .unbound
    }
    let markerURL = directoryURL.appendingPathComponent(markerName)
    guard isRegularFile(markerURL),
      let envelope = try? String(contentsOf: markerURL, encoding: .utf8)
    else {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
    let plaintext: Data
    do {
      plaintext = try localDataProtector.open(envelope, context: markerContext)
    } catch {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
    guard plaintext == markerPlaintext else {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
    return .boundAndValid
  }

  public func preserve(
    audio: CapturedAudio,
    runID: UUID,
    workflowID: UUID,
    trigger: WorkflowRunTriggerKind?,
    outcome: BenchmarkRecordingOutcome,
    metadata: [String: String],
    now: Date
  ) async throws -> BenchmarkRecordingReceipt {
    guard audio.fileOwnership == .managedTemporary,
      let sourceURL = audio.fileURL?.standardizedFileURL,
      sourceURL.isFileURL,
      Self.isRegularFile(sourceURL)
    else {
      throw BenchmarkRecordingArchiveError.unsupportedPayload
    }

    let plaintext: Data
    do {
      plaintext = try Data(contentsOf: sourceURL, options: [.mappedIfSafe, .uncached])
    } catch {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    let receipt = BenchmarkRecordingReceipt(
      runID: runID,
      workflowID: workflowID,
      createdAt: now,
      durationSeconds: audio.durationSeconds,
      format: audio.format,
      plaintextByteCount: plaintext.count,
      trigger: trigger,
      outcome: outcome,
      metadata: metadata
    )
    let protectedAudio: Data
    let protectedReceipt: Data
    do {
      protectedAudio = try localDataProtector.sealBinary(
        plaintext,
        context: Self.protectionContext(runID: runID, field: "audio")
      )
      protectedReceipt = try localDataProtector.sealBinary(
        encoder.encode(receipt),
        context: Self.protectionContext(runID: runID, field: "receipt")
      )
    } catch {
      throw BenchmarkRecordingArchiveError.protectionUnavailable
    }
    try commit(
      protectedAudio: protectedAudio,
      protectedReceipt: protectedReceipt,
      runID: runID
    )
    return receipt
  }

  public func recordingIDs() async throws -> [UUID] {
    try fileManager.contentsOfDirectory(atPath: directoryURL.path)
      .filter { $0.hasSuffix(Self.receiptSuffix) }
      .compactMap { UUID(uuidString: String($0.dropLast(Self.receiptSuffix.count))) }
      .sorted { $0.uuidString < $1.uuidString }
  }

  public func receipt(runID: UUID) async throws -> BenchmarkRecordingReceipt {
    do {
      let receiptBytes = try readProtectedArtifact(at: receiptURL(for: runID), runID: runID, field: "receipt")
      let receipt = try JSONDecoder().decode(BenchmarkRecordingReceipt.self, from: receiptBytes)
      guard receipt.schemaVersion == 1, receipt.runID == runID,
        receipt.durationSeconds.isFinite, receipt.durationSeconds >= 0,
        receipt.plaintextByteCount >= 0 else {
        throw BenchmarkRecordingArchiveError.invalidEntry
      }
      return receipt
    } catch { throw BenchmarkRecordingArchiveError.invalidEntry }
  }

  public func recording(runID: UUID) async throws -> BenchmarkRecording {
    do {
      let receipt = try await receipt(runID: runID)
      let audio = try readProtectedArtifact(at: audioURL(for: runID), runID: runID, field: "audio")
      guard audio.count == receipt.plaintextByteCount else {
        throw BenchmarkRecordingArchiveError.invalidEntry
      }
      return BenchmarkRecording(receipt: receipt, audioBytes: audio)
    } catch {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
  }

  private func readProtectedArtifact(at url: URL, runID: UUID, field: String) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw BenchmarkRecordingArchiveError.invalidEntry }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      let envelope = try file.readToEnd() else {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
    return try localDataProtector.openBinary(envelope, context: Self.protectionContext(runID: runID, field: field))
  }

  public func delete(runID: UUID) async throws {
    try removeOwnedArtifactIfPresent(at: audioURL(for: runID))
    try removeOwnedArtifactIfPresent(at: receiptURL(for: runID))
  }

  public func deleteAll() async throws {
    let names: [String]
    do {
      names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
    } catch {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    for name in names where Self.isOwnedArtifactName(name) {
      try removeOwnedArtifactIfPresent(at: directoryURL.appendingPathComponent(name))
    }
  }

  private func commit(
    protectedAudio: Data,
    protectedReceipt: Data,
    runID: UUID
  ) throws {
    let audioURL = audioURL(for: runID)
    let receiptURL = receiptURL(for: runID)
    guard !fileManager.fileExists(atPath: audioURL.path),
      !fileManager.fileExists(atPath: receiptURL.path)
    else {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
    let transactionID = UUID().uuidString
    let temporaryAudioURL = directoryURL.appendingPathComponent(
      ".\(transactionID)-audio\(Self.temporarySuffix)"
    )
    let temporaryReceiptURL = directoryURL.appendingPathComponent(
      ".\(transactionID)-receipt\(Self.temporarySuffix)"
    )
    do {
      try Self.writePrivate(protectedAudio, to: temporaryAudioURL)
      try Self.writePrivate(protectedReceipt, to: temporaryReceiptURL)
      try fileManager.moveItem(at: temporaryAudioURL, to: audioURL)
      do {
        try fileManager.moveItem(at: temporaryReceiptURL, to: receiptURL)
      } catch {
        try? removeOwnedArtifactIfPresent(at: audioURL)
        throw error
      }
    } catch {
      try? Self.removeNonDirectoryEntry(at: temporaryAudioURL)
      try? Self.removeNonDirectoryEntry(at: temporaryReceiptURL)
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
  }

  private func audioURL(for runID: UUID) -> URL {
    directoryURL.appendingPathComponent(runID.uuidString + Self.audioSuffix)
  }

  private func receiptURL(for runID: UUID) -> URL {
    directoryURL.appendingPathComponent(runID.uuidString + Self.receiptSuffix)
  }

  private func removeOwnedArtifactIfPresent(at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try Self.removeNonDirectoryEntry(at: url)
  }

  private static var markerContext: LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: "benchmark_recordings_key",
      recordID: "1",
      field: "key_verification"
    )
  }

  private static func protectionContext(
    runID: UUID,
    field: String
  ) -> LocalDataProtectionContext {
    LocalDataProtectionContext(
      namespace: namespace,
      recordID: runID.uuidString,
      field: field
    )
  }

  private static func prepareKeyBinding(
    directoryURL: URL,
    localDataProtector: any LocalDataProtector,
    fileManager: FileManager
  ) throws {
    let markerURL = directoryURL.appendingPathComponent(markerName)
    if fileManager.fileExists(atPath: markerURL.path) {
      guard
        try probeExistingDataProtectionKey(
          directoryURL: directoryURL,
          localDataProtector: localDataProtector,
          fileManager: fileManager
        ) == .boundAndValid
      else {
        throw BenchmarkRecordingArchiveError.invalidEntry
      }
      return
    }
    let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
    guard !names.contains(where: isOwnedArtifactName) else {
      throw BenchmarkRecordingArchiveError.invalidEntry
    }
    let envelope: String
    do {
      envelope = try localDataProtector.seal(markerPlaintext, context: markerContext)
    } catch {
      throw BenchmarkRecordingArchiveError.protectionUnavailable
    }
    try writePrivate(Data(envelope.utf8), to: markerURL)
  }

  private static func ensurePrivateDirectory(
    at directoryURL: URL,
    fileManager: FileManager
  ) throws {
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      let values = try directoryURL.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw BenchmarkRecordingArchiveError.storageUnavailable
      }
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: directoryURL.path
      )
    } catch let error as BenchmarkRecordingArchiveError {
      throw error
    } catch {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
  }

  private static func removeTemporaryArtifacts(
    directoryURL: URL,
    fileManager: FileManager
  ) throws {
    let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
    for name in names where name.hasSuffix(temporarySuffix) {
      try removeNonDirectoryEntry(at: directoryURL.appendingPathComponent(name))
    }
  }

  private static func isOwnedArtifactName(_ name: String) -> Bool {
    name.hasSuffix(audioSuffix)
      || name.hasSuffix(receiptSuffix)
      || name.hasSuffix(temporarySuffix)
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    var information = stat()
    return lstat(url.path, &information) == 0
      && information.st_mode & S_IFMT == S_IFREG
  }

  private static func writePrivate(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: [.atomic])
      guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
        throw BenchmarkRecordingArchiveError.storageUnavailable
      }
    } catch let error as BenchmarkRecordingArchiveError {
      throw error
    } catch {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
  }

  private static func removeNonDirectoryEntry(at url: URL) throws {
    var information = stat()
    guard lstat(url.path, &information) == 0 else {
      if errno == ENOENT { return }
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    guard information.st_mode & S_IFMT != S_IFDIR, unlink(url.path) == 0 else {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
  }
}
