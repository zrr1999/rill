import CryptoKit
import Darwin
import Foundation

public struct SherpaOnnxModelInstallationProgress: Equatable, Sendable {
  public enum Phase: String, Sendable {
    case checkingCache
    case downloading
    case verifyingArchive
    case inspectingArchive
    case extracting
    case verifyingModel
    case complete
  }

  public let phase: Phase
  public let completedByteCount: UInt64
  public let totalByteCount: UInt64

  public init(phase: Phase, completedByteCount: UInt64, totalByteCount: UInt64) {
    self.phase = phase
    self.completedByteCount = completedByteCount
    self.totalByteCount = totalByteCount
  }
}

public enum SherpaOnnxArchiveSafetyViolation: Equatable, Sendable {
  case absolutePath
  case parentTraversal
  case invalidPath
  case multipleRoots
  case duplicateEntry
  case linkOrSpecialEntry
  case tooManyEntries
}

public enum SherpaOnnxModelInstallationError: Error, LocalizedError, Equatable, Sendable {
  case invalidCatalogDescriptor
  case unsafeDestinationRoot
  case downloadFailed
  case downloadedArchiveIsNotRegularFile
  case downloadedArchiveHasMultipleHardLinks
  case archiveByteCountMismatch(expected: UInt64, actual: UInt64)
  case archiveDigestMismatch
  case archiveInspectionFailed
  case unsafeArchiveEntry(path: String, violation: SherpaOnnxArchiveSafetyViolation)
  case requiredEntryMissing(path: String)
  case requiredEntryTypeMismatch(path: String)
  case extractionFailed
  case extractedTreeInvalid(path: String)
  case receiptInvalid
  case publicationFailed

  public var errorDescription: String? {
    switch self {
    case .invalidCatalogDescriptor:
      return "The sherpa-onnx model catalog entry is invalid."
    case .unsafeDestinationRoot:
      return "The sherpa-onnx model destination is not a private directory."
    case .downloadFailed:
      return "The sherpa-onnx model archive could not be downloaded."
    case .downloadedArchiveIsNotRegularFile:
      return "The downloaded sherpa-onnx archive is not a regular file."
    case .downloadedArchiveHasMultipleHardLinks:
      return "The downloaded sherpa-onnx archive has multiple hard links."
    case .archiveByteCountMismatch(let expected, let actual):
      return "The sherpa-onnx archive size is invalid (expected \(expected), got \(actual))."
    case .archiveDigestMismatch:
      return "The sherpa-onnx archive does not match its release SHA-256."
    case .archiveInspectionFailed:
      return "The sherpa-onnx archive could not be inspected safely."
    case .unsafeArchiveEntry(let path, _):
      return "The sherpa-onnx archive contains an unsafe entry: \(path)."
    case .requiredEntryMissing(let path):
      return "The sherpa-onnx archive is missing required entry \(path)."
    case .requiredEntryTypeMismatch(let path):
      return "The sherpa-onnx archive entry has the wrong type: \(path)."
    case .extractionFailed:
      return "The sherpa-onnx archive could not be extracted safely."
    case .extractedTreeInvalid(let path):
      return "The extracted sherpa-onnx model tree is unsafe at \(path)."
    case .receiptInvalid:
      return "The installed sherpa-onnx model receipt is invalid."
    case .publicationFailed:
      return "The sherpa-onnx model could not be published atomically."
    }
  }
}

struct SherpaOnnxArchiveDownloadRequest: Sendable {
  let sourceURL: URL
  let expectedByteCount: UInt64
}

final class SherpaOnnxDownloadedArchive: @unchecked Sendable {
  let fileURL: URL
  private let lock = NSLock()
  private var cleanup: (@Sendable () -> Void)?

  init(fileURL: URL, cleanup: @escaping @Sendable () -> Void) {
    self.fileURL = fileURL
    self.cleanup = cleanup
  }

  deinit {
    discard()
  }

  func discard() {
    let cleanup = lock.withLock {
      let cleanup = self.cleanup
      self.cleanup = nil
      return cleanup
    }
    cleanup?()
  }
}

protocol SherpaOnnxArchiveDownloading: Sendable {
  func download(
    _ request: SherpaOnnxArchiveDownloadRequest,
    progressCallback: (@Sendable (_ completed: UInt64, _ total: UInt64) -> Void)?
  ) async throws -> SherpaOnnxDownloadedArchive
}

struct SherpaOnnxArchiveEntry: Equatable, Sendable {
  enum EntryType: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case hardLink
    case characterDevice
    case blockDevice
    case fifo
    case socket
    case unknown
  }

  let path: String
  let type: EntryType
}

protocol SherpaOnnxArchiveExtracting: Sendable {
  func inspectArchive(at archiveURL: URL) async throws -> [SherpaOnnxArchiveEntry]

  /// Extracts the contents below `archiveRootDirectoryName` directly into
  /// `destinationURL`; the outer archive directory is intentionally stripped.
  func extractArchive(
    at archiveURL: URL,
    archiveRootDirectoryName: String,
    to destinationURL: URL
  ) async throws
}

public actor SherpaOnnxModelInstaller {
  public nonisolated let destinationRootURL: URL

  // These values are versioned storage-format identifiers, not display
  // branding. Preserve them across the product rename so existing receipts
  // and the reviewed model inventory hashes remain valid.
  private static let receiptFileName = ".voxtype-sherpa-model.json"
  private static let installedFileInventoryHeader =
    "voxtype-sherpa-installed-file-inventory-v1\n"
  private static let maximumArchiveEntryCount = 100_000
  private static let maximumReceiptByteCount = 16 * 1_024 * 1_024

  private let downloader: any SherpaOnnxArchiveDownloading
  private let extractor: any SherpaOnnxArchiveExtracting

  public init(destinationRootURL: URL) {
    self.destinationRootURL = destinationRootURL
    self.downloader = SherpaOnnxURLSessionArchiveDownloader()
    self.extractor = SherpaOnnxTarArchiveExtractor()
  }

  init(
    destinationRootURL: URL,
    downloader: any SherpaOnnxArchiveDownloading,
    extractor: any SherpaOnnxArchiveExtracting
  ) {
    self.destinationRootURL = destinationRootURL
    self.downloader = downloader
    self.extractor = extractor
  }

  public func install(
    _ modelID: SherpaOnnxModelID,
    progressCallback: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)? = nil
  ) async throws -> URL {
    guard let descriptor = SherpaOnnxModelCatalog.distributableDescriptor(for: modelID) else {
      throw SherpaOnnxModelInstallationError.invalidCatalogDescriptor
    }
    return try await install(
      descriptor,
      progressCallback: progressCallback
    )
  }

  func install(
    _ descriptor: SherpaOnnxModelDescriptor,
    progressCallback: (@Sendable (SherpaOnnxModelInstallationProgress) -> Void)? = nil
  ) async throws -> URL {
    guard Self.isValidDescriptor(descriptor) else {
      throw SherpaOnnxModelInstallationError.invalidCatalogDescriptor
    }
    try Task.checkCancellation()
    let total = descriptor.archiveByteCount
    progressCallback?(
      .init(phase: .checkingCache, completedByteCount: 0, totalByteCount: total)
    )

    let root = try Self.openPrivateDestinationRoot(destinationRootURL)
    defer { _ = close(root.descriptor) }
    guard flock(root.descriptor, LOCK_EX) == 0 else {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    defer { _ = flock(root.descriptor, LOCK_UN) }

    try Task.checkCancellation()
    try Self.removeAbandonedEntries(in: root.url)
    let publicationName = Self.publicationName(for: descriptor)
    let publicationURL = root.url.appendingPathComponent(publicationName, isDirectory: true)
    if try Self.validatePublishedModel(at: publicationURL, descriptor: descriptor) {
      progressCallback?(
        .init(phase: .complete, completedByteCount: total, totalByteCount: total)
      )
      return publicationURL
    }
    if Self.pathExists(publicationURL) {
      try Self.quarantineAndRemove(publicationURL, in: root.url)
    }

    let stagingName = ".\(publicationName).\(UUID().uuidString.lowercased()).partial"
    let stagingURL = root.url.appendingPathComponent(stagingName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: stagingURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch {
      throw SherpaOnnxModelInstallationError.publicationFailed
    }
    var removeStaging = true
    defer {
      if removeStaging {
        try? FileManager.default.removeItem(at: stagingURL)
      }
    }

    progressCallback?(
      .init(phase: .downloading, completedByteCount: 0, totalByteCount: total)
    )
    let downloaded: SherpaOnnxDownloadedArchive
    do {
      downloaded = try await downloader.download(
        .init(sourceURL: descriptor.archiveURL, expectedByteCount: total),
        progressCallback: { completed, reportedTotal in
          progressCallback?(
            .init(
              phase: .downloading,
              completedByteCount: min(completed, total),
              totalByteCount: min(reportedTotal, total)
            )
          )
        }
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw SherpaOnnxModelInstallationError.downloadFailed
    }
    defer { downloaded.discard() }

    try Task.checkCancellation()
    progressCallback?(
      .init(phase: .verifyingArchive, completedByteCount: total, totalByteCount: total)
    )
    try Self.verifyArchive(at: downloaded.fileURL, descriptor: descriptor)

    try Task.checkCancellation()
    progressCallback?(
      .init(phase: .inspectingArchive, completedByteCount: total, totalByteCount: total)
    )
    let entries: [SherpaOnnxArchiveEntry]
    do {
      entries = try await extractor.inspectArchive(at: downloaded.fileURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SherpaOnnxModelInstallationError.archiveInspectionFailed
    }
    try Self.validateArchiveEntries(entries, descriptor: descriptor)

    try Task.checkCancellation()
    progressCallback?(
      .init(phase: .extracting, completedByteCount: total, totalByteCount: total)
    )
    do {
      try await extractor.extractArchive(
        at: downloaded.fileURL,
        archiveRootDirectoryName: descriptor.archiveRootDirectoryName,
        to: stagingURL
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SherpaOnnxModelInstallationError.extractionFailed
    }

    try Task.checkCancellation()
    progressCallback?(
      .init(phase: .verifyingModel, completedByteCount: total, totalByteCount: total)
    )
    let inventory = try Self.validateExtractedModel(
      at: stagingURL,
      descriptor: descriptor,
      normalizingPermissions: true
    )
    try Self.writeReceipt(
      SherpaOnnxModelReceipt(descriptor: descriptor, files: inventory),
      to: stagingURL.appendingPathComponent(Self.receiptFileName)
    )
    guard let stagingDescriptor = Self.openDirectory(stagingURL) else {
      throw SherpaOnnxModelInstallationError.publicationFailed
    }
    defer { _ = close(stagingDescriptor) }
    guard fsync(stagingDescriptor) == 0 else {
      throw SherpaOnnxModelInstallationError.publicationFailed
    }

    try Task.checkCancellation()
    let publishResult = stagingName.withCString { sourceName in
      publicationName.withCString { destinationName in
        renameatx_np(
          root.descriptor,
          sourceName,
          root.descriptor,
          destinationName,
          UInt32(RENAME_EXCL)
        )
      }
    }
    if publishResult != 0 {
      guard errno == EEXIST,
        try Self.validatePublishedModel(at: publicationURL, descriptor: descriptor)
      else {
        throw SherpaOnnxModelInstallationError.publicationFailed
      }
    } else {
      removeStaging = false
      guard fsync(root.descriptor) == 0 else {
        throw SherpaOnnxModelInstallationError.publicationFailed
      }
    }
    progressCallback?(
      .init(phase: .complete, completedByteCount: total, totalByteCount: total)
    )
    return publicationURL
  }

  /// Returns a cache entry only after re-hashing every installed regular file.
  public func existingInstalledURL(for modelID: SherpaOnnxModelID) throws -> URL? {
    guard let descriptor = SherpaOnnxModelCatalog.distributableDescriptor(for: modelID) else {
      throw SherpaOnnxModelInstallationError.invalidCatalogDescriptor
    }
    return try existingInstalledURL(for: descriptor)
  }

  /// Descriptor overload used by recognizers that already resolved the fixed catalog entry.
  func existingInstalledURL(
    for descriptor: SherpaOnnxModelDescriptor
  ) throws -> URL? {
    guard Self.isValidDescriptor(descriptor) else {
      throw SherpaOnnxModelInstallationError.invalidCatalogDescriptor
    }
    let root = try Self.openPrivateDestinationRoot(destinationRootURL)
    defer { _ = close(root.descriptor) }
    guard flock(root.descriptor, LOCK_SH) == 0 else {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    defer { _ = flock(root.descriptor, LOCK_UN) }
    let url = root.url.appendingPathComponent(
      Self.publicationName(for: descriptor),
      isDirectory: true
    )
    return try Self.validatePublishedModel(at: url, descriptor: descriptor) ? url : nil
  }

  /// Revalidates an installed cache entry against its release descriptor and receipt.
  public func verifyInstalledModel(_ modelID: SherpaOnnxModelID) throws -> Bool {
    try existingInstalledURL(for: modelID) != nil
  }

  func verifyInstalledModel(_ descriptor: SherpaOnnxModelDescriptor) throws -> Bool {
    try existingInstalledURL(for: descriptor) != nil
  }

  static func validateArchiveEntries(
    _ entries: [SherpaOnnxArchiveEntry],
    descriptor: SherpaOnnxModelDescriptor
  ) throws {
    guard !entries.isEmpty else {
      throw SherpaOnnxModelInstallationError.archiveInspectionFailed
    }
    guard entries.count <= maximumArchiveEntryCount else {
      throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
        path: "<archive>",
        violation: .tooManyEntries
      )
    }
    var seen = Set<String>()
    var observedRoot: String?
    var normalizedEntries: [String: SherpaOnnxArchiveEntry.EntryType] = [:]

    for entry in entries {
      let normalized = try normalizedArchivePath(entry.path)
      guard seen.insert(normalized).inserted else {
        throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
          path: entry.path,
          violation: .duplicateEntry
        )
      }
      guard entry.type == .regularFile || entry.type == .directory else {
        throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
          path: entry.path,
          violation: .linkOrSpecialEntry
        )
      }
      let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
      guard let first = components.first else {
        throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
          path: entry.path,
          violation: .invalidPath
        )
      }
      let root = String(first)
      if let observedRoot, observedRoot != root {
        throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
          path: entry.path,
          violation: .multipleRoots
        )
      }
      observedRoot = root
      guard root == descriptor.archiveRootDirectoryName else {
        throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
          path: entry.path,
          violation: .multipleRoots
        )
      }
      if components.count == 1 {
        guard entry.type == .directory else {
          throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
            path: entry.path,
            violation: .invalidPath
          )
        }
        continue
      }
      let relative = components.dropFirst().joined(separator: "/")
      normalizedEntries[relative] = entry.type
    }

    for required in descriptor.requiredEntries {
      switch required.kind {
      case .regularFile:
        guard let actual = normalizedEntries[required.relativePath] else {
          throw SherpaOnnxModelInstallationError.requiredEntryMissing(
            path: required.relativePath
          )
        }
        guard actual == .regularFile else {
          throw SherpaOnnxModelInstallationError.requiredEntryTypeMismatch(
            path: required.relativePath
          )
        }
      case .directory:
        if let actual = normalizedEntries[required.relativePath] {
          guard actual == .directory else {
            throw SherpaOnnxModelInstallationError.requiredEntryTypeMismatch(
              path: required.relativePath
            )
          }
        } else {
          let prefix = required.relativePath + "/"
          guard normalizedEntries.keys.contains(where: { $0.hasPrefix(prefix) }) else {
            throw SherpaOnnxModelInstallationError.requiredEntryMissing(
              path: required.relativePath
            )
          }
        }
      }
    }
  }

  private static func normalizedArchivePath(_ path: String) throws -> String {
    guard !path.isEmpty, path.utf8.count <= 4_096 else {
      throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
        path: path,
        violation: .invalidPath
      )
    }
    guard !path.hasPrefix("/") else {
      throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
        path: path,
        violation: .absolutePath
      )
    }
    guard
      !path.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || $0.value == 0x7F
      })
    else {
      throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
        path: path,
        violation: .invalidPath
      )
    }
    let withoutTrailingSlash = path.hasSuffix("/") ? String(path.dropLast()) : path
    let components = withoutTrailingSlash.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." })
    else {
      throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
        path: path,
        violation: .invalidPath
      )
    }
    guard !components.contains("..") else {
      throw SherpaOnnxModelInstallationError.unsafeArchiveEntry(
        path: path,
        violation: .parentTraversal
      )
    }
    return components.joined(separator: "/")
  }

  private static func isValidDescriptor(_ descriptor: SherpaOnnxModelDescriptor) -> Bool {
    guard descriptor.archiveByteCount > 0,
      descriptor.archiveByteCount <= UInt64(Int64.max),
      descriptor.archiveSHA256.count == 64,
      descriptor.archiveSHA256.unicodeScalars.allSatisfy({
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
      }),
      descriptor.installedFileInventorySHA256.count == 64,
      descriptor.installedFileInventorySHA256.unicodeScalars.allSatisfy({
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
      }),
      isSafeRelativePath(descriptor.archiveRootDirectoryName, permitsSubdirectories: false),
      !descriptor.requiredEntries.isEmpty,
      Set(descriptor.requiredEntries.map(\.relativePath)).count
        == descriptor.requiredEntries.count,
      descriptor.requiredEntries.allSatisfy({
        isSafeRelativePath($0.relativePath, permitsSubdirectories: true)
      }),
      let components = URLComponents(
        url: descriptor.archiveURL,
        resolvingAgainstBaseURL: false
      ),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "github.com",
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.port == nil || components.port == 443,
      components.path.hasPrefix("/k2-fsa/sherpa-onnx/releases/download/asr-models/")
    else {
      return false
    }
    return true
  }

  private static func isSafeRelativePath(
    _ path: String,
    permitsSubdirectories: Bool
  ) -> Bool {
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.hasSuffix("/"),
      !path.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || $0.value == 0x7F
      })
    else {
      return false
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard permitsSubdirectories || components.count == 1 else { return false }
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private static func publicationName(for descriptor: SherpaOnnxModelDescriptor) -> String {
    "model-\(descriptor.id.rawValue)-\(descriptor.archiveSHA256.prefix(16))"
  }

  private static func openPrivateDestinationRoot(_ requestedURL: URL) throws -> (
    url: URL, descriptor: Int32
  ) {
    let url = requestedURL.standardizedFileURL
    guard url.isFileURL else {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    var status = stat()
    guard lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      chmod(url.path, 0o700) == 0
    else {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    return (url, descriptor)
  }

  private static func openDirectory(_ url: URL) -> Int32? {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    return descriptor >= 0 ? descriptor : nil
  }

  private static func removeAbandonedEntries(in rootURL: URL) throws {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: []
      )
    } catch {
      throw SherpaOnnxModelInstallationError.unsafeDestinationRoot
    }
    for entry in entries {
      let name = entry.lastPathComponent
      if name.hasPrefix(".") && (name.hasSuffix(".partial") || name.hasPrefix(".quarantine.")) {
        try? FileManager.default.removeItem(at: entry)
      }
    }
  }

  private static func quarantineAndRemove(_ url: URL, in rootURL: URL) throws {
    let quarantine = rootURL.appendingPathComponent(
      ".quarantine.\(UUID().uuidString.lowercased())"
    )
    do {
      try FileManager.default.moveItem(at: url, to: quarantine)
      try FileManager.default.removeItem(at: quarantine)
    } catch {
      throw SherpaOnnxModelInstallationError.publicationFailed
    }
  }

  private static func pathExists(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
  }

  private static func verifyArchive(
    at archiveURL: URL,
    descriptor: SherpaOnnxModelDescriptor
  ) throws {
    let metadata = try stableSHA256(of: archiveURL, synchronize: false)
    guard metadata.isRegularFile else {
      throw SherpaOnnxModelInstallationError.downloadedArchiveIsNotRegularFile
    }
    guard metadata.linkCount == 1 else {
      throw SherpaOnnxModelInstallationError.downloadedArchiveHasMultipleHardLinks
    }
    guard metadata.byteCount == descriptor.archiveByteCount else {
      throw SherpaOnnxModelInstallationError.archiveByteCountMismatch(
        expected: descriptor.archiveByteCount,
        actual: metadata.byteCount
      )
    }
    guard metadata.sha256 == descriptor.archiveSHA256 else {
      throw SherpaOnnxModelInstallationError.archiveDigestMismatch
    }
  }

  private static func validateExtractedModel(
    at rootURL: URL,
    descriptor: SherpaOnnxModelDescriptor,
    normalizingPermissions: Bool
  ) throws -> [SherpaOnnxModelReceipt.FileRecord] {
    var rootStatus = stat()
    guard lstat(rootURL.path, &rootStatus) == 0,
      rootStatus.st_mode & S_IFMT == S_IFDIR
    else {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: "<root>")
    }
    if normalizingPermissions, chmod(rootURL.path, 0o700) != 0 {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: "<root>")
    }

    let manager = FileManager.default
    // FileManager canonicalizes `/var` to `/private/var` for enumerated URLs on
    // macOS. Use realpath so the containment root has the same representation.
    guard let canonicalRoot = realpath(rootURL.path, nil) else {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: "<root>")
    }
    defer { free(canonicalRoot) }
    let enumerationRootURL = URL(fileURLWithPath: String(cString: canonicalRoot), isDirectory: true)
    guard
      let enumerator = manager.enumerator(
        at: enumerationRootURL,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in false }
      )
    else {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: "<root>")
    }
    let rootPrefix =
      enumerationRootURL.path.hasSuffix("/")
      ? enumerationRootURL.path : enumerationRootURL.path + "/"
    var records: [SherpaOnnxModelReceipt.FileRecord] = []
    var entryCount = 0
    while let entry = enumerator.nextObject() as? URL {
      try Task.checkCancellation()
      entryCount += 1
      guard entryCount <= maximumArchiveEntryCount,
        entry.path.hasPrefix(rootPrefix)
      else {
        throw SherpaOnnxModelInstallationError.extractedTreeInvalid(
          path: "<tree>"
        )
      }
      let relativePath = String(entry.path.dropFirst(rootPrefix.count))
      guard isSafeRelativePath(relativePath, permitsSubdirectories: true) else {
        throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: relativePath)
      }
      var status = stat()
      guard lstat(entry.path, &status) == 0 else {
        throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: relativePath)
      }
      switch status.st_mode & S_IFMT {
      case S_IFDIR:
        if normalizingPermissions, chmod(entry.path, 0o700) != 0 {
          throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: relativePath)
        }
      case S_IFREG:
        guard status.st_nlink == 1 else {
          throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: relativePath)
        }
        if relativePath == receiptFileName { continue }
        if normalizingPermissions, chmod(entry.path, 0o600) != 0 {
          throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: relativePath)
        }
        let digest = try stableSHA256(of: entry, synchronize: normalizingPermissions)
        records.append(
          .init(
            relativePath: relativePath,
            byteCount: digest.byteCount,
            sha256: digest.sha256
          )
        )
      default:
        throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: relativePath)
      }
    }
    records.sort {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
    guard !records.isEmpty else {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: "<tree>")
    }
    try validateRequiredEntries(at: rootURL, descriptor: descriptor)
    guard
      canonicalInstalledFileInventorySHA256(records)
        == descriptor.installedFileInventorySHA256
    else {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: "<inventory>")
    }
    return records
  }

  /// The v1 canonical byte sequence starts with `installedFileInventoryHeader`.
  /// Each following line is sorted by UTF-8 path bytes and contains the UTF-8
  /// path length, path, decimal byte count, and lowercase content SHA-256,
  /// separated by tabs and terminated by a newline. Validated model paths cannot
  /// contain control characters, so the representation is unambiguous.
  private static func canonicalInstalledFileInventorySHA256(
    _ records: [SherpaOnnxModelReceipt.FileRecord]
  ) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(installedFileInventoryHeader.utf8))
    for record in records {
      let pathByteCount = record.relativePath.utf8.count
      hasher.update(
        data: Data(
          "\(pathByteCount)\t\(record.relativePath)\t\(record.byteCount)\t\(record.sha256)\n".utf8
        )
      )
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func validateRequiredEntries(
    at rootURL: URL,
    descriptor: SherpaOnnxModelDescriptor
  ) throws {
    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    for required in descriptor.requiredEntries {
      let url = rootURL.appendingPathComponent(required.relativePath)
      guard url.standardizedFileURL.path.hasPrefix(rootPrefix) else {
        throw SherpaOnnxModelInstallationError.requiredEntryMissing(
          path: required.relativePath
        )
      }
      var status = stat()
      guard lstat(url.path, &status) == 0 else {
        throw SherpaOnnxModelInstallationError.requiredEntryMissing(
          path: required.relativePath
        )
      }
      switch required.kind {
      case .regularFile:
        guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
          throw SherpaOnnxModelInstallationError.requiredEntryTypeMismatch(
            path: required.relativePath
          )
        }
      case .directory:
        guard status.st_mode & S_IFMT == S_IFDIR else {
          throw SherpaOnnxModelInstallationError.requiredEntryTypeMismatch(
            path: required.relativePath
          )
        }
      }
    }
  }

  private static func validatePublishedModel(
    at modelURL: URL,
    descriptor: SherpaOnnxModelDescriptor
  ) throws -> Bool {
    var rootStatus = stat()
    guard lstat(modelURL.path, &rootStatus) == 0 else { return false }
    guard rootStatus.st_mode & S_IFMT == S_IFDIR else { return false }
    let receiptURL = modelURL.appendingPathComponent(receiptFileName)
    let receiptData: Data
    do {
      receiptData = try readRegularFile(
        at: receiptURL,
        maximumByteCount: maximumReceiptByteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return false
    }
    let receipt: SherpaOnnxModelReceipt
    do {
      receipt = try JSONDecoder().decode(SherpaOnnxModelReceipt.self, from: receiptData)
    } catch {
      return false
    }
    guard receipt.matches(descriptor) else { return false }
    let current: [SherpaOnnxModelReceipt.FileRecord]
    do {
      current = try validateExtractedModel(
        at: modelURL,
        descriptor: descriptor,
        normalizingPermissions: false
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return false
    }
    return current == receipt.files
  }

  private static func writeReceipt(_ receipt: SherpaOnnxModelReceipt, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(receipt)
    } catch {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    guard data.count <= maximumReceiptByteCount else {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    let descriptor = open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    defer { _ = close(descriptor) }
    do {
      try data.withUnsafeBytes { rawBuffer in
        guard var cursor = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        while remaining > 0 {
          let count = Darwin.write(descriptor, cursor, remaining)
          guard count > 0 else {
            throw SherpaOnnxModelInstallationError.receiptInvalid
          }
          cursor = cursor.advanced(by: count)
          remaining -= count
        }
      }
    } catch {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    guard fsync(descriptor) == 0 else {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
  }

  private struct StableDigest {
    let isRegularFile: Bool
    let linkCount: UInt64
    let byteCount: UInt64
    let sha256: String
  }

  private static func stableSHA256(of url: URL, synchronize: Bool) throws -> StableDigest {
    var beforePath = stat()
    guard lstat(url.path, &beforePath) == 0 else {
      throw SherpaOnnxModelInstallationError.downloadedArchiveIsNotRegularFile
    }
    guard beforePath.st_mode & S_IFMT == S_IFREG else {
      return .init(
        isRegularFile: false,
        linkCount: UInt64(beforePath.st_nlink),
        byteCount: 0,
        sha256: ""
      )
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw SherpaOnnxModelInstallationError.downloadedArchiveIsNotRegularFile
    }
    defer { _ = close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_dev == beforePath.st_dev,
      before.st_ino == beforePath.st_ino,
      before.st_size >= 0
    else {
      throw SherpaOnnxModelInstallationError.downloadedArchiveIsNotRegularFile
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      try Task.checkCancellation()
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw SherpaOnnxModelInstallationError.archiveDigestMismatch
      }
      hasher.update(data: Data(buffer[0..<count]))
    }
    if synchronize, fsync(descriptor) != 0 {
      throw SherpaOnnxModelInstallationError.extractedTreeInvalid(path: url.lastPathComponent)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_nlink == after.st_nlink,
      after.st_nlink == 1
    else {
      throw SherpaOnnxModelInstallationError.archiveDigestMismatch
    }
    return .init(
      isRegularFile: true,
      linkCount: UInt64(after.st_nlink),
      byteCount: UInt64(after.st_size),
      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }

  private static func readRegularFile(at url: URL, maximumByteCount: Int) throws -> Data {
    var status = stat()
    guard lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1,
      status.st_size >= 0,
      status.st_size <= maximumByteCount
    else {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    defer { _ = close(descriptor) }
    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      try Task.checkCancellation()
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw SherpaOnnxModelInstallationError.receiptInvalid
      }
      guard data.count + count <= maximumByteCount else {
        throw SherpaOnnxModelInstallationError.receiptInvalid
      }
      data.append(contentsOf: buffer[0..<count])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      after.st_dev == status.st_dev,
      after.st_ino == status.st_ino,
      after.st_size == status.st_size,
      after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
      after.st_nlink == 1
    else {
      throw SherpaOnnxModelInstallationError.receiptInvalid
    }
    return data
  }
}

private struct SherpaOnnxModelReceipt: Codable, Equatable, Sendable {
  struct FileRecord: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
  }

  static let currentSchemaVersion = 2

  let schemaVersion: Int
  let modelID: String
  let architecture: String
  let archiveURL: String
  let archiveByteCount: UInt64
  let archiveSHA256: String
  let archiveRootDirectoryName: String
  let installedFileInventorySHA256: String
  let files: [FileRecord]

  init(descriptor: SherpaOnnxModelDescriptor, files: [FileRecord]) {
    schemaVersion = Self.currentSchemaVersion
    modelID = descriptor.id.rawValue
    architecture = descriptor.architecture.rawValue
    archiveURL = descriptor.archiveURL.absoluteString
    archiveByteCount = descriptor.archiveByteCount
    archiveSHA256 = descriptor.archiveSHA256
    archiveRootDirectoryName = descriptor.archiveRootDirectoryName
    installedFileInventorySHA256 = descriptor.installedFileInventorySHA256
    self.files = files
  }

  func matches(_ descriptor: SherpaOnnxModelDescriptor) -> Bool {
    schemaVersion == Self.currentSchemaVersion
      && modelID == descriptor.id.rawValue
      && architecture == descriptor.architecture.rawValue
      && archiveURL == descriptor.archiveURL.absoluteString
      && archiveByteCount == descriptor.archiveByteCount
      && archiveSHA256 == descriptor.archiveSHA256
      && archiveRootDirectoryName == descriptor.archiveRootDirectoryName
      && installedFileInventorySHA256 == descriptor.installedFileInventorySHA256
      && !files.isEmpty
      && files
        == files.sorted(by: {
          $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        })
      && Set(files.map(\.relativePath)).count == files.count
      && files.allSatisfy {
        !$0.relativePath.isEmpty
          && $0.sha256.count == 64
          && $0.sha256.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
              || (scalar.value >= 97 && scalar.value <= 102)
          }
      }
  }
}

private struct SherpaOnnxURLSessionArchiveDownloader: SherpaOnnxArchiveDownloading, Sendable {
  private static let allowedSourceHosts: Set<String> = ["github.com"]
  private static let allowedRedirectHosts: Set<String> = [
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
  ]

  func download(
    _ request: SherpaOnnxArchiveDownloadRequest,
    progressCallback: (@Sendable (UInt64, UInt64) -> Void)?
  ) async throws -> SherpaOnnxDownloadedArchive {
    try Task.checkCancellation()
    guard Self.isAllowedSourceURL(request.sourceURL), request.expectedByteCount > 0 else {
      throw SherpaOnnxModelInstallationError.downloadFailed
    }
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-sherpa-download-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch {
      throw SherpaOnnxModelInstallationError.downloadFailed
    }
    let destination = temporaryRoot.appendingPathComponent("model.tar.bz2")
    var keepTemporaryRoot = false
    defer {
      if !keepTemporaryRoot {
        try? FileManager.default.removeItem(at: temporaryRoot)
      }
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 3_600
    var urlRequest = URLRequest(url: request.sourceURL)
    urlRequest.httpMethod = "GET"
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    let operation = SherpaOnnxDownloadOperation(
      configuration: configuration,
      originalURL: request.sourceURL,
      destinationURL: destination,
      expectedByteCount: request.expectedByteCount,
      allowedRedirectHosts: Self.allowedRedirectHosts,
      progressCallback: progressCallback
    )
    try await operation.run(request: urlRequest)
    keepTemporaryRoot = true
    return SherpaOnnxDownloadedArchive(fileURL: destination) {
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
  }

  private static func isAllowedSourceURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      allowedSourceHosts.contains(host),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.port == nil || components.port == 443,
      components.path.hasPrefix("/k2-fsa/sherpa-onnx/releases/download/asr-models/")
    else {
      return false
    }
    return true
  }

  fileprivate static func isAllowedRedirectURL(
    _ url: URL,
    originalURL: URL,
    allowedHosts: Set<String>
  ) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      allowedHosts.contains(host),
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.port == nil || components.port == 443
    else {
      return false
    }
    if host == originalURL.host?.lowercased() {
      return components.path.hasPrefix("/k2-fsa/sherpa-onnx/releases/download/asr-models/")
    }
    return !components.path.isEmpty && components.path != "/"
  }
}

private final class SherpaOnnxDownloadOperation:
  NSObject,
  URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let configuration: URLSessionConfiguration
  private let originalURL: URL
  private let destinationURL: URL
  private let expectedByteCount: UInt64
  private let allowedRedirectHosts: Set<String>
  private let progressCallback: (@Sendable (UInt64, UInt64) -> Void)?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var terminalError: Error?
  private var destinationWasStored = false
  private var cancellationRequested = false
  private var redirectCount = 0

  init(
    configuration: URLSessionConfiguration,
    originalURL: URL,
    destinationURL: URL,
    expectedByteCount: UInt64,
    allowedRedirectHosts: Set<String>,
    progressCallback: (@Sendable (UInt64, UInt64) -> Void)?
  ) {
    self.configuration = configuration
    self.originalURL = originalURL
    self.destinationURL = destinationURL
    self.expectedByteCount = expectedByteCount
    self.allowedRedirectHosts = allowedRedirectHosts
    self.progressCallback = progressCallback
  }

  func run(request: URLRequest) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.downloadTask(with: request)
        let shouldCancel = lock.withLock { () -> Bool in
          self.continuation = continuation
          self.session = session
          self.task = task
          return cancellationRequested
        }
        task.resume()
        if shouldCancel { task.cancel() }
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func cancel() {
    let task = lock.withLock { () -> URLSessionDownloadTask? in
      cancellationRequested = true
      return self.task
    }
    task?.cancel()
  }

  private func recordTerminalError(_ error: Error) {
    lock.withLock {
      if terminalError == nil { terminalError = error }
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    let state = lock.withLock {
      let continuation = self.continuation
      let session = self.session
      self.continuation = nil
      self.session = nil
      self.task = nil
      return (continuation, session)
    }
    guard let continuation = state.0 else { return }
    if case .failure = result {
      try? FileManager.default.removeItem(at: destinationURL)
    }
    continuation.resume(with: result)
    state.1?.finishTasksAndInvalidate()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let accepted: URLRequest? = lock.withLock {
      redirectCount += 1
      guard redirectCount <= 8,
        let url = request.url,
        SherpaOnnxURLSessionArchiveDownloader.isAllowedRedirectURL(
          url,
          originalURL: originalURL,
          allowedHosts: allowedRedirectHosts
        )
      else {
        if terminalError == nil {
          terminalError = SherpaOnnxModelInstallationError.downloadFailed
        }
        return nil
      }
      var sanitized = request
      sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
      sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
      return sanitized
    }
    completionHandler(accepted)
    if accepted == nil { task.cancel() }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten >= 0 else { return }
    let completed = UInt64(totalBytesWritten)
    if completed > expectedByteCount
      || (totalBytesExpectedToWrite > 0
        && UInt64(totalBytesExpectedToWrite) > expectedByteCount)
    {
      recordTerminalError(SherpaOnnxModelInstallationError.downloadFailed)
      downloadTask.cancel()
      return
    }
    progressCallback?(
      completed,
      totalBytesExpectedToWrite > 0 ? UInt64(totalBytesExpectedToWrite) : expectedByteCount
    )
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let shouldContinue = lock.withLock { !cancellationRequested && terminalError == nil }
    guard shouldContinue,
      let response = downloadTask.response as? HTTPURLResponse,
      response.statusCode == 200,
      let finalURL = response.url,
      SherpaOnnxURLSessionArchiveDownloader.isAllowedRedirectURL(
        finalURL,
        originalURL: originalURL,
        allowedHosts: allowedRedirectHosts
      )
    else {
      recordTerminalError(SherpaOnnxModelInstallationError.downloadFailed)
      return
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
      guard let size = attributes[.size] as? NSNumber,
        size.uint64Value <= expectedByteCount
      else {
        throw SherpaOnnxModelInstallationError.downloadFailed
      }
      try FileManager.default.moveItem(at: location, to: destinationURL)
      guard chmod(destinationURL.path, 0o600) == 0 else {
        throw SherpaOnnxModelInstallationError.downloadFailed
      }
      lock.withLock { destinationWasStored = true }
    } catch {
      recordTerminalError(SherpaOnnxModelInstallationError.downloadFailed)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let result: Result<Void, Error> = lock.withLock {
      if cancellationRequested { return .failure(CancellationError()) }
      if let terminalError { return .failure(terminalError) }
      if error != nil || !destinationWasStored {
        return .failure(SherpaOnnxModelInstallationError.downloadFailed)
      }
      return .success(())
    }
    finish(result)
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    guard error != nil else { return }
    finish(.failure(SherpaOnnxModelInstallationError.downloadFailed))
  }
}

struct SherpaOnnxTarArchiveExtractor: SherpaOnnxArchiveExtracting, Sendable {
  func inspectArchive(at archiveURL: URL) async throws -> [SherpaOnnxArchiveEntry] {
    try Task.checkCancellation()
    let namesResult = try await Self.runTar(["-tjf", archiveURL.path])
    let verboseResult = try await Self.runTar(["-tvjf", archiveURL.path])
    try Task.checkCancellation()
    let names = Self.lines(namesResult)
    let verbose = Self.lines(verboseResult)
    guard !names.isEmpty, names.count == verbose.count else {
      throw SherpaOnnxModelInstallationError.archiveInspectionFailed
    }
    return try zip(names, verbose).map { name, detail in
      guard let marker = detail.utf8.first else {
        throw SherpaOnnxModelInstallationError.archiveInspectionFailed
      }
      let type: SherpaOnnxArchiveEntry.EntryType
      switch marker {
      case Character("-").asciiValue!:
        type = .regularFile
      case Character("d").asciiValue!:
        type = .directory
      case Character("l").asciiValue!:
        type = .symbolicLink
      case Character("h").asciiValue!:
        type = .hardLink
      case Character("c").asciiValue!:
        type = .characterDevice
      case Character("b").asciiValue!:
        type = .blockDevice
      case Character("p").asciiValue!:
        type = .fifo
      case Character("s").asciiValue!:
        type = .socket
      default:
        type = .unknown
      }
      return SherpaOnnxArchiveEntry(path: name, type: type)
    }
  }

  func extractArchive(
    at archiveURL: URL,
    archiveRootDirectoryName: String,
    to destinationURL: URL
  ) async throws {
    try Task.checkCancellation()
    _ = try await Self.runTar([
      "-xjf", archiveURL.path,
      "-C", destinationURL.path,
      "--strip-components", "1",
      "--no-same-owner",
      "--no-same-permissions",
    ])
    try Task.checkCancellation()
  }

  private static func runTar(_ arguments: [String]) async throws -> Data {
    let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-sherpa-tar-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: outputRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: outputRoot) }
    let stdoutURL = outputRoot.appendingPathComponent("stdout")
    let stderrURL = outputRoot.appendingPathComponent("stderr")
    guard
      FileManager.default.createFile(
        atPath: stdoutURL.path,
        contents: nil,
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
      ),
      FileManager.default.createFile(
        atPath: stderrURL.path,
        contents: nil,
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
      )
    else {
      throw SherpaOnnxModelInstallationError.archiveInspectionFailed
    }
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try await SherpaOnnxTarProcessExecution(process: process).run()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SherpaOnnxModelInstallationError.archiveInspectionFailed
    }
    try stdout.synchronize()
    let attributes = try FileManager.default.attributesOfItem(atPath: stdoutURL.path)
    guard let byteCount = attributes[.size] as? NSNumber,
      byteCount.uint64Value <= 32 * 1_024 * 1_024
    else {
      throw SherpaOnnxModelInstallationError.archiveInspectionFailed
    }
    return try Data(contentsOf: stdoutURL, options: [.mappedIfSafe])
  }

  private static func lines(_ data: Data) -> [String] {
    guard let value = String(data: data, encoding: .utf8) else { return [] }
    return value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }
}

/// Owns one `/usr/bin/tar` child so task cancellation stops both the Swift task
/// and the external decompressor. A delayed SIGKILL prevents an unresponsive
/// child from keeping model installation alive indefinitely after cancellation.
final class SherpaOnnxTarProcessExecution: @unchecked Sendable {
  private struct Completion: Sendable {
    let reason: Process.TerminationReason
    let status: Int32
  }

  private let process: Process
  private let lock = NSLock()
  private var cancellationRequested = false
  private var completion: Completion?
  private var continuation: CheckedContinuation<Completion, Never>?
  private var escalationTask: Task<Void, Never>?

  init(process: Process) {
    self.process = process
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      process.terminationHandler = { [weak self] process in
        self?.didTerminate(
          Completion(reason: process.terminationReason, status: process.terminationStatus)
        )
      }

      let cancelledBeforeLaunch = lock.withLock { cancellationRequested }
      guard !cancelledBeforeLaunch else {
        process.terminationHandler = nil
        throw CancellationError()
      }

      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        throw error
      }

      if lock.withLock({ cancellationRequested }) {
        terminateAndEscalateIfNeeded()
      }

      let completion = await waitForCompletion()
      process.terminationHandler = nil
      escalationTask?.cancel()
      escalationTask = nil
      if lock.withLock({ cancellationRequested }) {
        throw CancellationError()
      }
      guard completion.reason == .exit, completion.status == 0 else {
        throw SherpaOnnxModelInstallationError.archiveInspectionFailed
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func cancel() {
    let shouldTerminate = lock.withLock { () -> Bool in
      cancellationRequested = true
      return completion == nil && process.isRunning
    }
    if shouldTerminate {
      terminateAndEscalateIfNeeded()
    }
  }

  private func terminateAndEscalateIfNeeded() {
    if process.isRunning {
      process.terminate()
    }
    let task = Task.detached(priority: .utility) { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      self?.forceTerminateIfNeeded()
    }
    let shouldKeep = lock.withLock { () -> Bool in
      guard completion == nil, escalationTask == nil else { return false }
      escalationTask = task
      return true
    }
    if !shouldKeep {
      task.cancel()
    }
  }

  private func forceTerminateIfNeeded() {
    let processIdentifier = lock.withLock { () -> pid_t? in
      guard completion == nil, process.isRunning else { return nil }
      return process.processIdentifier
    }
    if let processIdentifier {
      _ = Darwin.kill(processIdentifier, SIGKILL)
    }
  }

  private func didTerminate(_ completion: Completion) {
    let continuation = lock.withLock { () -> CheckedContinuation<Completion, Never>? in
      guard self.completion == nil else { return nil }
      self.completion = completion
      escalationTask?.cancel()
      escalationTask = nil
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(returning: completion)
  }

  private func waitForCompletion() async -> Completion {
    await withCheckedContinuation { continuation in
      let completed = lock.withLock { () -> Completion? in
        if let completion { return completion }
        self.continuation = continuation
        return nil
      }
      if let completed {
        continuation.resume(returning: completed)
      }
    }
  }
}
