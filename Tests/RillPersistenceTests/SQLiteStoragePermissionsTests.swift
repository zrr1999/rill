import Darwin
import Foundation
import RillCore
import RillPersistence
import XCTest

final class SQLiteStoragePermissionsTests: XCTestCase {
  func testStoreKeepsNewDatabaseAndWALSidecarsPrivate() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = rootURL.appendingPathComponent("rill.sqlite")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let protector = try AESGCMDataProtector(
      key: Data(repeating: 0x51, count: AESGCMDataProtector.keyByteCount)
    )
    let store = try SQLitePersistenceStore(
      databaseURL: databaseURL,
      localDataProtector: protector
    )
    try await store.setString("private", forKey: .interfaceLanguage)

    XCTAssertEqual(try permissions(at: rootURL), 0o700)
    for url in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      XCTAssertEqual(try permissions(at: url), 0o600)
    }
  }

  func testPreparePrivateStorageRestrictsExistingDatabaseAndSidecars() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = rootURL.appendingPathComponent("rill.sqlite")
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let storageURLs = [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
      URL(fileURLWithPath: databaseURL.path + "-journal"),
    ]
    for url in storageURLs {
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
      XCTAssertEqual(chmod(url.path, 0o644), 0)
    }
    XCTAssertEqual(chmod(rootURL.path, 0o755), 0)

    try SQLitePersistenceStore.preparePrivateStorage(at: databaseURL)

    XCTAssertEqual(try permissions(at: rootURL), 0o700)
    for url in storageURLs {
      XCTAssertEqual(try permissions(at: url), 0o600)
    }
  }

  func testPreparePrivateStorageCreatesPrivateParentWithoutCreatingDatabase() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = rootURL.appendingPathComponent("nested/rill.sqlite")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try SQLitePersistenceStore.preparePrivateStorage(at: databaseURL)

    XCTAssertEqual(try permissions(at: databaseURL.deletingLastPathComponent()), 0o700)
    XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
  }

  func testPreparePrivateStorageRejectsSymlinkDatabaseWithoutChangingTarget() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = rootURL.appendingPathComponent("rill.sqlite")
    let targetURL = rootURL.appendingPathComponent("target.sqlite")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
    XCTAssertEqual(chmod(targetURL.path, 0o644), 0)
    try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(try SQLitePersistenceStore.preparePrivateStorage(at: databaseURL)) {
      XCTAssertEqual($0 as? SQLiteStoragePermissionError, .unsafeStorageFile)
    }
    XCTAssertEqual(try permissions(at: targetURL), 0o644)
  }

  func testPreparePrivateStorageRejectsSymlinkParent() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let targetURL = rootURL.appendingPathComponent("target", isDirectory: true)
    let linkedURL = rootURL.appendingPathComponent("linked", isDirectory: true)
    let databaseURL = linkedURL.appendingPathComponent("rill.sqlite")
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(try SQLitePersistenceStore.preparePrivateStorage(at: databaseURL)) {
      XCTAssertEqual($0 as? SQLiteStoragePermissionError, .unsafeParentDirectory)
    }
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }
}
