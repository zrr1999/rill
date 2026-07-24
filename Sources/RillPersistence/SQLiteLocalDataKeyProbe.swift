import Darwin
import Foundation
import SQLite3
import RillCore

public enum SQLiteLocalDataKeyProbeResult: Sendable, Equatable {
  case unbound
  case boundAndValid
}

public enum SQLiteLocalDataKeyProbeError: Error, LocalizedError, Sendable, Equatable {
  case databaseUnavailable
  case validationFailed

  public var errorDescription: String? {
    switch self {
    case .databaseUnavailable:
      return "The local database could not be inspected safely."
    case .validationFailed:
      return "The local database key binding could not be validated."
    }
  }
}

/// Validates an existing local-data key without opening the live SQLite files.
///
/// SQLite read-only WAL connections can still update WAL-index reader state. The
/// probe therefore reads a stable filesystem clone and never migrates, checkpoints,
/// vacuums, or executes a write PRAGMA against the live database.
public enum SQLiteLocalDataKeyProbe {
  private static let protectedSchemaVersion = 4
  private static let authenticatedFloorSchemaVersion = 11
  private static let maximumMarkerEnvelopeByteCount = 4_096
  private static let markerPlaintext = Data("Rill local data key verification v1".utf8)
  private static let markerContext = LocalDataProtectionContext(
    namespace: "local_data_protection",
    recordID: "1",
    field: "key_verification"
  )

  public static func probe(
    databaseURL: URL,
    localDataProtector: any LocalDataProtector
  ) throws -> SQLiteLocalDataKeyProbeResult {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: databaseURL.path) else {
      guard !SQLiteReadOnlySnapshot.hasOrphanedSidecars(for: databaseURL) else {
        throw SQLiteLocalDataKeyProbeError.validationFailed
      }
      return .unbound
    }

    let snapshot: SQLiteReadOnlySnapshot
    do {
      snapshot = try SQLiteReadOnlySnapshot(databaseURL: databaseURL)
    } catch {
      throw SQLiteLocalDataKeyProbeError.databaseUnavailable
    }
    defer { snapshot.remove() }

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard
      sqlite3_open_v2(snapshot.databaseURL.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      throw SQLiteLocalDataKeyProbeError.databaseUnavailable
    }
    defer { sqlite3_close(database) }

    do {
      let version = try schemaVersion(on: database)
      let hasMarker = try tableExists("local_data_protection", on: database)
      let hasFloor = try tableExists(
        SQLiteAuthenticatedSchemaFloor.tableName,
        on: database
      )

      guard version < authenticatedFloorSchemaVersion || hasFloor else {
        throw SQLiteLocalDataKeyProbeError.validationFailed
      }
      guard version < protectedSchemaVersion || hasMarker else {
        throw SQLiteLocalDataKeyProbeError.validationFailed
      }
      guard hasMarker || hasFloor else { return .unbound }
      guard hasMarker else {
        throw SQLiteLocalDataKeyProbeError.validationFailed
      }

      if hasFloor {
        guard
          try SQLiteAuthenticatedSchemaFloor.readAndValidate(
            on: database,
            localDataProtector: localDataProtector
          ) != nil
        else {
          throw SQLiteLocalDataKeyProbeError.validationFailed
        }
      }
      try validateMarker(
        on: database,
        localDataProtector: localDataProtector
      )
      return .boundAndValid
    } catch let error as SQLiteLocalDataKeyProbeError {
      throw error
    } catch {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
  }

  private static func schemaVersion(on database: OpaquePointer?) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
      let version = Int(exactly: sqlite3_column_int64(statement, 0)),
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
    return version
  }

  private static func tableExists(
    _ tableName: String,
    on database: OpaquePointer?
  ) throws -> Bool {
    let supportedNames = Set([
      "local_data_protection",
      SQLiteAuthenticatedSchemaFloor.tableName,
    ])
    guard supportedNames.contains(tableName) else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT 1 FROM main.sqlite_schema WHERE type = 'table' AND name = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard
      tableName.withCString({
        sqlite3_bind_text(statement, 1, $0, -1, transient)
      }) == SQLITE_OK
    else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return false
    case SQLITE_ROW:
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLiteLocalDataKeyProbeError.validationFailed
      }
      return true
    default:
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
  }

  private static func validateMarker(
    on database: OpaquePointer?,
    localDataProtector: any LocalDataProtector
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT id, key_verification
        FROM main.local_data_protection
        ORDER BY id ASC;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
      sqlite3_column_int64(statement, 0) == 1,
      sqlite3_column_type(statement, 1) == SQLITE_TEXT,
      sqlite3_column_bytes(statement, 1) > 0,
      sqlite3_column_bytes(statement, 1) <= maximumMarkerEnvelopeByteCount,
      let envelope = textColumn(statement, index: 1),
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }

    let plaintext = try localDataProtector.open(
      envelope,
      context: markerContext
    )
    guard plaintext == markerPlaintext else {
      throw SQLiteLocalDataKeyProbeError.validationFailed
    }
  }

  private static func textColumn(
    _ statement: OpaquePointer?,
    index: Int32
  ) -> String? {
    let byteCount = Int(sqlite3_column_bytes(statement, index))
    guard byteCount >= 0,
      let bytes = sqlite3_column_text(statement, index)
    else { return nil }
    return String(
      data: Data(bytes: bytes, count: byteCount),
      encoding: .utf8
    )
  }
}

private final class SQLiteReadOnlySnapshot {
  private static let sidecarSuffixes = ["", "-wal", "-shm", "-journal"]

  let databaseURL: URL
  private let directoryURL: URL

  init(databaseURL sourceDatabaseURL: URL) throws {
    let fileManager = FileManager.default
    directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
      "rill-key-probe-\(UUID().uuidString)",
      isDirectory: true
    )
    databaseURL = directoryURL.appendingPathComponent(
      sourceDatabaseURL.lastPathComponent,
      isDirectory: false
    )
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )

    do {
      let before = try Self.sourceState(for: sourceDatabaseURL)
      guard before[""] != nil else {
        throw SQLiteLocalDataKeyProbeError.databaseUnavailable
      }
      for suffix in Self.sidecarSuffixes where before[suffix] != nil {
        let sourceURL = Self.url(for: sourceDatabaseURL, suffix: suffix)
        let destinationURL = Self.url(for: databaseURL, suffix: suffix)
        try Self.cloneOrCopy(from: sourceURL, to: destinationURL)
      }
      guard try Self.sourceState(for: sourceDatabaseURL) == before else {
        throw SQLiteLocalDataKeyProbeError.databaseUnavailable
      }
    } catch {
      try? fileManager.removeItem(at: directoryURL)
      throw error
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  static func hasOrphanedSidecars(for databaseURL: URL) -> Bool {
    sidecarSuffixes.dropFirst().contains { suffix in
      FileManager.default.fileExists(
        atPath: url(for: databaseURL, suffix: suffix).path
      )
    }
  }

  private static func sourceState(
    for databaseURL: URL
  ) throws -> [String: SourceFileIdentity] {
    var result: [String: SourceFileIdentity] = [:]
    for suffix in sidecarSuffixes {
      let fileURL = url(for: databaseURL, suffix: suffix)
      var information = stat()
      if lstat(fileURL.path, &information) == 0 {
        guard information.st_mode & S_IFMT == S_IFREG else {
          throw SQLiteLocalDataKeyProbeError.databaseUnavailable
        }
        result[suffix] = SourceFileIdentity(information)
      } else if errno != ENOENT {
        throw SQLiteLocalDataKeyProbeError.databaseUnavailable
      }
    }
    return result
  }

  private static func cloneOrCopy(from sourceURL: URL, to destinationURL: URL) throws {
    if clonefile(sourceURL.path, destinationURL.path, 0) == 0 { return }
    try? FileManager.default.removeItem(at: destinationURL)
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
  }

  private static func url(for databaseURL: URL, suffix: String) -> URL {
    URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false)
  }
}

private struct SourceFileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let mode: UInt16
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let changeSeconds: Int64
  let changeNanoseconds: Int64

  init(_ information: stat) {
    device = UInt64(information.st_dev)
    inode = UInt64(information.st_ino)
    size = information.st_size
    mode = information.st_mode
    modificationSeconds = Int64(information.st_mtimespec.tv_sec)
    modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
    changeSeconds = Int64(information.st_ctimespec.tv_sec)
    changeNanoseconds = Int64(information.st_ctimespec.tv_nsec)
  }
}
