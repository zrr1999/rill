import CryptoKit
import Darwin
import Foundation
import HuggingFace
import RillSpeechContracts

/// File mechanics shared by model adapters. Each adapter still owns its pinned
/// inventory, receipt format, and verification policy before publication.
enum ModelFiles {
  static func preparePrivateDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard isRegularDirectory(directory) else { throw MLXAudioSwiftRuntimeError.invalidModelStore }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  static func isRegularDirectory(_ directory: URL) -> Bool {
    let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values?.isDirectory == true && values?.isSymbolicLink != true
  }

  static func sha256(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let block = try handle.read(upToCount: 4 * 1_024 * 1_024), !block.isEmpty {
      try Task.checkCancellation()
      hash.update(data: block)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// The candidate has already passed the caller's trust checks. A filesystem
  /// swap keeps the old publication available until the new one is installed;
  /// interruption can leave only a disposable old directory at the staging path.
  static func publish(_ candidate: URL, at publication: URL) throws {
    try Task.checkCancellation()
    guard candidate.standardizedFileURL != publication.standardizedFileURL,
      isRegularDirectory(candidate), isRegularDirectory(publication.deletingLastPathComponent())
    else { throw MLXAudioSwiftRuntimeError.invalidModelStore }
    let existing = try? publication.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let flags: UInt32
    if let existing {
      guard existing.isDirectory == true, existing.isSymbolicLink != true else {
        throw MLXAudioSwiftRuntimeError.invalidModelStore
      }
      flags = UInt32(RENAME_SWAP)
    } else {
      flags = UInt32(RENAME_EXCL)
    }
    guard renamex_np(candidate.path, publication.path, flags) == 0 else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    if flags == UInt32(RENAME_SWAP) { try? FileManager.default.removeItem(at: candidate) }
  }

  static func download(
    repository: String, revision: String, files: [String], to destination: URL,
    cache: URL? = nil, attempts: Int = 1, concurrency: Int = 4,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws {
    guard let repositoryID = Repo.ID(rawValue: repository), attempts > 0 else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 3_600
    let client = HubClient(
      session: URLSession(configuration: configuration),
      cache: cache.map { HubCache(cacheDirectory: $0) } ?? HubCache())
    for attempt in 1...attempts {
      try Task.checkCancellation()
      do {
        _ = try await client.downloadSnapshot(
          of: repositoryID, kind: .model, to: destination, revision: revision,
          matching: files, localFilesOnly: false, maxConcurrentDownloads: concurrency,
          progressHandler: { update in
            let total = max(1, update.totalUnitCount)
            progress(
              .init(
                phase: .downloading,
                completedUnitCount: min(max(0, update.completedUnitCount), total),
                totalUnitCount: total))
          })
        try Task.checkCancellation()
        return
      } catch {
        try Task.checkCancellation()
        guard !(error is CancellationError), attempt < attempts else { throw error }
        try await Task.sleep(for: .seconds(attempt * 2))
      }
    }
  }
}

/// Serializes publication and abandoned-staging cleanup across worker processes.
/// The descriptor is held across awaits and released on every exit path.
final class ModelDownloadLease: Sendable {
  private let descriptor: Int32

  init(directory: URL, identity: String) throws {
    let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    let opened = open(
      directory.appendingPathComponent(".download-\(name).lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard opened >= 0 else { throw MLXAudioSwiftRuntimeError.invalidModelStore }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
      _ = close(opened)
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    descriptor = opened
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }
}
