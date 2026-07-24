import Darwin
import Foundation

public enum SQLiteStoragePermissionError: Error, LocalizedError, Sendable, Equatable {
  case unsafeParentDirectory
  case unsafeStorageFile
  case permissionUpdateFailed

  public var errorDescription: String? {
    switch self {
    case .unsafeParentDirectory:
      "The local database directory is not a private regular directory."
    case .unsafeStorageFile:
      "A local database file is not a private regular file."
    case .permissionUpdateFailed:
      "Local database permissions could not be restricted to the current user."
    }
  }
}

extension SQLitePersistenceStore {
  /// Restricts the SQLite database and every sidecar that can contain database
  /// pages before any Keychain or migration failure can send the app into its
  /// session-only fallback.
  public static func preparePrivateStorage(
    at databaseURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let parentURL = databaseURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
    } catch {
      throw SQLiteStoragePermissionError.permissionUpdateFailed
    }

    guard try storageItemKind(at: parentURL) == S_IFDIR else {
      throw SQLiteStoragePermissionError.unsafeParentDirectory
    }
    try restrictPermissions(at: parentURL, to: 0o700, missingIsAllowed: false)

    for storageURL in databaseStorageURLs(for: databaseURL) {
      guard let kind = try storageItemKind(at: storageURL) else { continue }
      guard kind == S_IFREG else {
        throw SQLiteStoragePermissionError.unsafeStorageFile
      }
      try restrictPermissions(at: storageURL, to: 0o600, missingIsAllowed: true)
    }
  }

  private static func databaseStorageURLs(for databaseURL: URL) -> [URL] {
    [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
      URL(fileURLWithPath: databaseURL.path + "-journal"),
    ]
  }

  private static func storageItemKind(at url: URL) throws -> mode_t? {
    var metadata = stat()
    let result = url.path.withCString { path in
      lstat(path, &metadata)
    }
    if result == 0 {
      return metadata.st_mode & mode_t(S_IFMT)
    }
    if errno == ENOENT {
      return nil
    }
    throw SQLiteStoragePermissionError.permissionUpdateFailed
  }

  private static func restrictPermissions(
    at url: URL,
    to permissions: mode_t,
    missingIsAllowed: Bool
  ) throws {
    let result = url.path.withCString { path in
      chmod(path, permissions)
    }
    guard result == 0 else {
      if missingIsAllowed, errno == ENOENT {
        return
      }
      throw SQLiteStoragePermissionError.permissionUpdateFailed
    }
  }
}
