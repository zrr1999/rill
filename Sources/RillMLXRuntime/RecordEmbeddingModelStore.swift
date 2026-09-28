import Foundation
import RillSpeechContracts

struct RecordEmbeddingModelStore: Sendable {
  let root: URL

  init(
    root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Rill/Models/record-search", isDirectory: true)
  ) {
    self.root = root
  }

  func directory(
    downloadIfNeeded: Bool, progress: @escaping @Sendable (SpeechWorkerProgress) -> Void
  ) async throws -> URL {
    if FileManager.default.fileExists(atPath: root.path),
      try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    let published = root.appendingPathComponent(
      RecordEmbeddingModelCatalog.revision, isDirectory: true)
    if try validate(published) { return published }
    guard downloadIfNeeded else {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(RecordEmbeddingModelCatalog.modelID)
    }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard
      try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true
    else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let lease = try ModelDownloadLease(directory: root, identity: RecordEmbeddingModelCatalog.modelID)
    defer { withExtendedLifetime(lease) {} }
    // Reclaim only this store's abandoned staging after acquiring the cross-process lock.
    for item in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    where (item.lastPathComponent.hasPrefix(".download-") && !item.lastPathComponent.hasSuffix(".lock"))
      || item.lastPathComponent.hasPrefix(".replaced-")
    {
      try FileManager.default.removeItem(at: item)
    }
    let staging = root.appendingPathComponent(".download-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let downloaded = staging.appendingPathComponent("download", isDirectory: true)
    let candidate = staging.appendingPathComponent("model", isDirectory: true)
    try await ModelFiles.download(
      repository: RecordEmbeddingModelCatalog.repository,
      revision: RecordEmbeddingModelCatalog.revision,
      files: RecordEmbeddingModelCatalog.files.map(\.path), to: downloaded,
      concurrency: 3, progress: progress)
    try Task.checkCancellation()
    // Hub's cache fast path copies the entire snapshot, even with matching patterns.
    // Move only reviewed regular files into the directory the recursive MLX loader sees.
    for item in RecordEmbeddingModelCatalog.files {
      let source = downloaded.appendingPathComponent(item.path)
      let parent = try source.deletingLastPathComponent().resourceValues(forKeys: [
        .isSymbolicLinkKey
      ])
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard parent.isSymbolicLink != true, values.isSymbolicLink != true,
        values.isRegularFile == true
      else {
        throw MLXAudioSwiftRuntimeError.invalidModelStore
      }
      let destination = candidate.appendingPathComponent(item.path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.moveItem(at: source, to: destination)
    }
    guard try validate(candidate) else { throw MLXAudioSwiftRuntimeError.invalidModelStore }
    try ModelFiles.publish(candidate, at: published)
    return published
  }

  func validate(_ directory: URL) throws -> Bool {
    let directoryValues = try? directory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard directoryValues?.isDirectory == true, directoryValues?.isSymbolicLink != true else {
      return false
    }
    guard let inventory = FileManager.default.enumerator(atPath: directory.path) else {
      return false
    }
    let expected = Set(RecordEmbeddingModelCatalog.files.map(\.path))
    var actual: Set<String> = []
    for case let path as String in inventory {
      try Task.checkCancellation()
      let file = directory.appendingPathComponent(path)
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isSymbolicLink != true else { return false }
      if values.isDirectory == true {
        guard path == "1_Pooling" else { return false }
      } else {
        guard values.isRegularFile == true, expected.contains(path) else { return false }
        actual.insert(path)
      }
    }
    guard actual == expected else { return false }
    for item in RecordEmbeddingModelCatalog.files {
      try Task.checkCancellation()
      let file = directory.appendingPathComponent(item.path)
      let values = try? file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true,
        values?.fileSize == item.byteCount
      else { return false }
      guard try ModelFiles.sha256(file) == item.sha256 else {
        return false
      }
    }
    return true
  }
}
