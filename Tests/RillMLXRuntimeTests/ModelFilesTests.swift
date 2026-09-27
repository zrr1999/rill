import Foundation
import XCTest

@testable import RillMLXRuntime

final class ModelFilesTests: XCTestCase {
  private func directory(_ parent: URL, _ name: String, text: String) throws -> URL {
    let directory = parent.appendingPathComponent(name, isDirectory: true)
    try ModelFiles.preparePrivateDirectory(directory)
    try Data(text.utf8).write(to: directory.appendingPathComponent("weights"))
    return directory
  }

  func testPublicationReplacesCompleteDirectoryWithoutLeavingOldFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try directory(root, "model", text: "old")
    try Data().write(to: old.appendingPathComponent("retired"))
    let candidate = try directory(root, "candidate", text: "new")
    try ModelFiles.publish(candidate, at: old)
    XCTAssertEqual(
      try String(contentsOf: old.appendingPathComponent("weights"), encoding: .utf8), "new")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: old.appendingPathComponent("retired").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
  }

  func testInvalidCandidateAndSymlinkCannotReplaceExistingModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try directory(root, "model", text: "old")
    let missing = root.appendingPathComponent("missing")
    XCTAssertThrowsError(try ModelFiles.publish(missing, at: old))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
    XCTAssertThrowsError(try ModelFiles.publish(link, at: old))
    let candidate = try directory(root, "candidate", text: "new")
    XCTAssertThrowsError(try ModelFiles.publish(candidate, at: link))
    XCTAssertEqual(
      try String(contentsOf: old.appendingPathComponent("weights"), encoding: .utf8), "old")
    XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
  }

  func testCancellationBeforePublicationPreservesOldModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try directory(root, "model", text: "old")
    let candidate = try directory(root, "candidate", text: "new")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try ModelFiles.publish(candidate, at: old)
    }
    do {
      try await task.value
      XCTFail("A cancelled publication must not replace the installed model")
    } catch is CancellationError {}
    XCTAssertEqual(
      try String(contentsOf: old.appendingPathComponent("weights"), encoding: .utf8), "old")
  }

  func testFirstPublicationAndStreamingDigest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let candidate = try directory(root, "candidate", text: "abc")
    let published = root.appendingPathComponent("model")
    try ModelFiles.publish(candidate, at: published)
    XCTAssertEqual(
      try ModelFiles.sha256(published.appendingPathComponent("weights")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }
  func testDownloadLeaseRejectsConcurrentWriterAndReleasesAtScopeExit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try ModelFiles.preparePrivateDirectory(root)
    do {
      let lease = try ModelDownloadLease(directory: root, identity: "same-model")
      defer { withExtendedLifetime(lease) {} }
      XCTAssertThrowsError(try ModelDownloadLease(directory: root, identity: "same-model"))
      let other = try ModelDownloadLease(directory: root, identity: "other-model")
      withExtendedLifetime(other) {}
    }
    let retry = try ModelDownloadLease(directory: root, identity: "same-model")
    withExtendedLifetime(retry) {}
  }

}
