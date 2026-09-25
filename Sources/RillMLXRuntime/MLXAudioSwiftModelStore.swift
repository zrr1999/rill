import Foundation
import RillSpeechContracts

private struct MLXAudioSwiftModelReceipt: Codable, Equatable {
  let schemaVersion: Int
  let modelID: String
  let repository: String
  let revision: String
  let files: [MLXAudioModelFile]
}

struct MLXAudioSwiftModelStore: Sendable {
  static let receiptFileName = ".rill-mlx-audio-swift-model.json"
  static let generatedFileNames = ["tokenizer.json"]

  let modelRootURL: URL
  let hubCacheRootURL: URL

  init(
    modelRootURL: URL = Self.defaultModelRootURL(),
    hubCacheRootURL: URL = Self.defaultHubCacheRootURL()
  ) {
    self.modelRootURL = modelRootURL
    self.hubCacheRootURL = hubCacheRootURL
  }

  func modelDirectory(
    descriptor: MLXAudioModelDescriptor,
    downloadIfNeeded: Bool,
    progress: @escaping @Sendable (SpeechWorkerProgress) -> Void = { _ in }
  ) async throws -> URL {
    // Keep a Rill-owned, exact-revision publication directory. The
    // mlx-audio-swift 0.1.3 loader consumes it directly without re-resolving the
    // repository name or contacting a moving branch.
    let publicationParentURL =
      modelRootURL.appendingPathComponent("mlx-audio", isDirectory: true)
    let publicationURL = publicationParentURL.appendingPathComponent(
      descriptor.repository.replacingOccurrences(of: "/", with: "_"),
      isDirectory: true
    )
    if !FileManager.default.fileExists(atPath: publicationParentURL.path) {
      guard downloadIfNeeded else {
        throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
      }
    }
    try ModelFiles.preparePrivateDirectory(publicationParentURL)
    let lease = try ModelDownloadLease(
      directory: publicationParentURL, identity: descriptor.id.rawValue)
    defer { withExtendedLifetime(lease) {} }
    if FileManager.default.fileExists(atPath: publicationParentURL.path) {
      try ModelFiles.preparePrivateDirectory(publicationParentURL)
      try Self.removeAbandonedEntries(
        in: publicationParentURL,
        for: descriptor.id
      )
    }
    if ModelFiles.isRegularDirectory(publicationURL) {
      try Self.removeGeneratedFiles(at: publicationURL)
      if try Self.validatePublishedModel(at: publicationURL, descriptor: descriptor) {
        return publicationURL
      }
      if try Self.repairReceiptForAuthenticatedFiles(
        at: publicationURL,
        descriptor: descriptor
      ) {
        return publicationURL
      }
    }
    guard downloadIfNeeded else {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    try ModelFiles.preparePrivateDirectory(modelRootURL)
    try ModelFiles.preparePrivateDirectory(publicationParentURL)
    try ModelFiles.preparePrivateDirectory(hubCacheRootURL)
    let stagingURL = publicationParentURL.appendingPathComponent(
      ".\(descriptor.id.rawValue).\(UUID().uuidString.lowercased()).partial",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }

    progress(
      .init(
        phase: .downloading, completedUnitCount: 0,
        totalUnitCount: Int64(descriptor.approximateDownloadByteCount)))
    do {
      try await ModelFiles.download(
        repository: descriptor.repository, revision: descriptor.revision,
        files: descriptor.files.map(\.path), to: stagingURL, cache: hubCacheRootURL,
        progress: progress)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw MLXAudioSwiftRuntimeError.modelUnavailable(descriptor.id.rawValue)
    }

    try Self.receiptData(for: descriptor).write(
      to: stagingURL.appendingPathComponent(Self.receiptFileName),
      options: .atomic
    )
    guard try Self.validatePublishedModel(at: stagingURL, descriptor: descriptor) else {
      throw MLXAudioSwiftRuntimeError.invalidModelStore
    }

    try ModelFiles.publish(stagingURL, at: publicationURL)
    return publicationURL
  }

  static func removeAbandonedEntries(
    in publicationParentURL: URL,
    for modelID: MLXAudioModelID
  ) throws {
    let prefixes = [
      ".\(modelID.rawValue)."
    ]
    let suffixes = [".partial", ".replaced"]
    let entries = try FileManager.default.contentsOfDirectory(
      at: publicationParentURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard prefixes.contains(where: name.hasPrefix),
        suffixes.contains(where: name.hasSuffix)
      else {
        continue
      }
      try FileManager.default.removeItem(at: entry)
    }
  }

  static func validatePublishedModel(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor,
    verifyDigests: Bool = true
  ) throws -> Bool {
    guard ModelFiles.isRegularDirectory(directory) else {
      return false
    }
    let receiptURL = directory.appendingPathComponent(receiptFileName)
    let receiptValues = try? receiptURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard receiptValues?.isRegularFile == true,
      receiptValues?.isSymbolicLink != true,
      let receiptSize = receiptValues?.fileSize,
      receiptSize > 0,
      receiptSize <= 32 * 1_024
    else {
      return false
    }
    guard
      let receipt = try? JSONDecoder().decode(
        MLXAudioSwiftModelReceipt.self,
        from: Data(contentsOf: receiptURL)
      ), receipt == Self.receipt(for: descriptor)
    else {
      return false
    }
    return try validateFileInventory(
      at: directory,
      descriptor: descriptor,
      verifyDigests: verifyDigests
    )
  }

  static func receiptData(
    for descriptor: MLXAudioModelDescriptor
  ) throws -> Data {
    try JSONEncoder().encode(receipt(for: descriptor))
  }

  static func repairReceiptForAuthenticatedFiles(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor
  ) throws -> Bool {
    guard
      try validateFileInventory(
        at: directory,
        descriptor: descriptor,
        verifyDigests: true
      )
    else {
      return false
    }
    try receiptData(for: descriptor).write(
      to: directory.appendingPathComponent(receiptFileName),
      options: .atomic
    )
    return try validatePublishedModel(
      at: directory,
      descriptor: descriptor,
      verifyDigests: false
    )
  }

  static func removeGeneratedFiles(at directory: URL) throws {
    guard ModelFiles.isRegularDirectory(directory) else { return }
    let generatedNames = Set(generatedFileNames)
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries where generatedNames.contains(entry.lastPathComponent) {
      let values = try entry.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true || values.isSymbolicLink == true else {
        continue
      }
      try FileManager.default.removeItem(at: entry)
    }
  }

  private static func receipt(
    for descriptor: MLXAudioModelDescriptor
  ) -> MLXAudioSwiftModelReceipt {
    MLXAudioSwiftModelReceipt(
      schemaVersion: 2,
      modelID: descriptor.id.rawValue,
      repository: descriptor.repository,
      revision: descriptor.revision,
      files: descriptor.files
    )
  }

  private static func validateFileInventory(
    at directory: URL,
    descriptor: MLXAudioModelDescriptor,
    verifyDigests: Bool
  ) throws -> Bool {
    guard ModelFiles.isRegularDirectory(directory) else { return false }
    let fileNames = descriptor.files.map(\.path)
    guard
      !fileNames.isEmpty,
      Set(fileNames).count == fileNames.count,
      fileNames.allSatisfy({
        !$0.isEmpty
          && !$0.contains("/")
          && !$0.contains("\\")
          && $0 != receiptFileName
          && !generatedFileNames.contains($0)
      })
    else {
      return false
    }

    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )
    let expectedNames = Set(fileNames + [receiptFileName])
    guard entries.count == expectedNames.count,
      Set(entries.map(\.lastPathComponent)) == expectedNames
    else {
      return false
    }

    for file in descriptor.files {
      let fileURL = directory.appendingPathComponent(file.path)
      let values = try fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize >= 0,
        UInt64(fileSize) == file.byteCount
      else {
        return false
      }
      if verifyDigests,
        try ModelFiles.sha256(fileURL) != file.sha256.lowercased()
      {
        return false
      }
    }

    let receiptValues = try directory.appendingPathComponent(receiptFileName)
      .resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
    return receiptValues.isRegularFile == true
      && receiptValues.isSymbolicLink != true
      && (receiptValues.fileSize ?? 0) > 0
      && (receiptValues.fileSize ?? 0) <= 32 * 1_024
  }

  private static func defaultModelRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let applicationSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )
    return
      applicationSupport
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("mlx-audio-swift", isDirectory: true)
  }

  private static func defaultHubCacheRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let caches =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Caches",
        isDirectory: true
      )
    return
      caches
      .appendingPathComponent("Rill", isDirectory: true)
      .appendingPathComponent("huggingface", isDirectory: true)
      .appendingPathComponent("hub", isDirectory: true)
  }
}
