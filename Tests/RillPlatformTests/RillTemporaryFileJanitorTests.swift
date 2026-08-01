import Foundation
import XCTest

@testable import RillCore
@testable import RillPlatform

final class RillTemporaryFileJanitorTests: XCTestCase {
  private let cutoff = Date(timeIntervalSince1970: 1_700_000_000)

  func testCleanupRemovesOldArtifactsAndReportsSpecificKinds() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifacts: [(String, RillTemporaryFileJanitor.ArtifactKind)] = [
      ("rill-shortcut-input.txt", .shortcutText),
      ("rill-recording.wav", .audioCapture),
      ("rill-recognition-operation.caf", .recognitionWork),
      ("rill-live-session.wav", .liveCapture),
      ("rill-deepgram-live-session.wav", .retiredCloudCapture),
    ]
    for (name, _) in artifacts {
      try createFile(
        named: name,
        in: directory,
        modifiedAt: cutoff.addingTimeInterval(
          -RillTemporaryFileJanitor.defaultMinimumAge - 1
        )
      )
    }

    let report = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupStartupOrphans(now: cutoff)

    XCTAssertEqual(report.removedCount, 5)
    XCTAssertEqual(report.failureCount, 0)
    for (name, kind) in artifacts {
      XCTAssertEqual(report.removed[kind], 1)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
  }

  func testDefaultRetentionKeepsNewFilesAndRemovesFilesOlderThan24Hours() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = cutoff.addingTimeInterval(RillTemporaryFileJanitor.defaultMinimumAge)
    let oldURL = try createFile(
      named: "rill-old.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-RillTemporaryFileJanitor.defaultMinimumAge - 1)
    )
    let newURL = try createFile(
      named: "rill-new.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-RillTemporaryFileJanitor.defaultMinimumAge + 1)
    )
    let boundaryURL = try createFile(
      named: "rill-boundary.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-RillTemporaryFileJanitor.defaultMinimumAge)
    )

    let report = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupOrphans(now: now)

    XCTAssertEqual(report.removed.audioCapture, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: boundaryURL.path))
  }

  func testStartupRemovesRecoveryAndRecognitionWorkWhileExplicitCleanupIsRecoveryOnly() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = cutoff
    let recoveryURL = try createFile(
      named: "rill-recovery-interrupted.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-1)
    )
    let recentCaptureURL = try createFile(
      named: "rill-recent.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-1)
    )
    let recognitionWorkURL = try createFile(
      named: "rill-recognition-interrupted.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-1)
    )

    let startupReport = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupStartupOrphans(now: now)

    XCTAssertEqual(startupReport.removed.recoveryAudio, 1)
    XCTAssertEqual(startupReport.removed.recognitionWork, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: recognitionWorkURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recentCaptureURL.path))

    let secondRecoveryURL = try createFile(
      named: "rill-recovery-clear.wav",
      in: directory,
      modifiedAt: Date()
    )
    let activeRecognitionWorkURL = try createFile(
      named: "\(RecognitionTemporaryAudioNamespace.currentProcessFilenamePrefix)active.wav",
      in: directory,
      modifiedAt: now.addingTimeInterval(-1)
    )
    let concurrentStartupReport = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupStartupOrphans(now: now)
    XCTAssertEqual(concurrentStartupReport.removed.recognitionWork, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecognitionWorkURL.path))

    let clearReport = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupRecoveryArtifacts()
    XCTAssertEqual(clearReport.removed.recoveryAudio, 1)
    XCTAssertEqual(clearReport.removed.recognitionWork, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondRecoveryURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecognitionWorkURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recentCaptureURL.path))

    let genericReport = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupOrphans(now: Date.distantFuture)
    XCTAssertEqual(genericReport.removed.recognitionWork, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecognitionWorkURL.path))
  }

  func testCleanupPreservesUnknownAndIncompleteNames() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preservedNames = [
      "unrelated.wav",
      "rill-audio.mp3",
      "rill-.wav",
      "rill-shortcut-.txt",
      "rill-shortcut-input.log",
      "rill-live-",
      "rill-deepgram-live-",
      "rill-recognition-",
      "Rill-recording.wav",
    ]
    for name in preservedNames {
      try createFile(named: name, in: directory, modifiedAt: cutoff.addingTimeInterval(-1))
    }

    let report = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupOrphans(olderThan: cutoff)

    XCTAssertEqual(report.removedCount, 0)
    XCTAssertEqual(report.failureCount, 0)
    for name in preservedNames {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
  }

  func testCleanupPreservesMatchingSymbolicLinksAndDirectories() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let targetURL = try createFile(
      named: "symbolic-link-target.txt",
      in: directory,
      modifiedAt: cutoff.addingTimeInterval(-1)
    )
    let linkURL = directory.appendingPathComponent("rill-linked.wav")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    let matchingDirectory = directory.appendingPathComponent(
      "rill-live-directory", isDirectory: true)
    try FileManager.default.createDirectory(
      at: matchingDirectory, withIntermediateDirectories: false)
    let nestedArtifact = try createFile(
      named: "rill-nested.wav",
      in: matchingDirectory,
      modifiedAt: cutoff.addingTimeInterval(-1)
    )
    try FileManager.default.setAttributes(
      [.modificationDate: cutoff.addingTimeInterval(-1)],
      ofItemAtPath: matchingDirectory.path
    )

    let report = RillTemporaryFileJanitor(temporaryDirectory: directory)
      .cleanupOrphans(olderThan: cutoff)

    XCTAssertEqual(report.removedCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
    XCTAssertEqual(try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: matchingDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nestedArtifact.path))
  }

  func testCleanupContinuesAfterOneRemovalFailsAndReturnsSafeSummary() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blockedName = "rill-blocked.wav"
    let blockedURL = try createFile(
      named: blockedName,
      in: directory,
      modifiedAt: cutoff.addingTimeInterval(-1)
    )
    let removableURL = try createFile(
      named: "rill-removable.wav",
      in: directory,
      modifiedAt: cutoff.addingTimeInterval(-1)
    )
    let fileSystem = SelectiveRemovalFailureFileSystem(blockedName: blockedName)
    let janitor = RillTemporaryFileJanitor(
      temporaryDirectory: directory,
      fileSystem: fileSystem
    )

    let report = janitor.cleanupOrphans(olderThan: cutoff)

    XCTAssertEqual(report.removed.audioCapture, 1)
    XCTAssertEqual(report.failureCount, 1)
    XCTAssertEqual(report.failures.count, 1)
    XCTAssertEqual(report.failures[0].operation, .removeArtifact)
    XCTAssertEqual(report.failures[0].artifactKind, .audioCapture)
    XCTAssertEqual(report.failures[0].count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: blockedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: removableURL.path))
  }

  func testCleanupDoesNotFollowASymbolicLinkPassedAsTemporaryDirectory() throws {
    let directory = try makeTemporaryDirectory()
    let parent = directory.deletingLastPathComponent()
    let linkURL = parent.appendingPathComponent("rill-janitor-link-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: linkURL)
      try? FileManager.default.removeItem(at: directory)
    }
    let artifactURL = try createFile(
      named: "rill-old.wav",
      in: directory,
      modifiedAt: cutoff.addingTimeInterval(-1)
    )
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: directory)

    let report = RillTemporaryFileJanitor(temporaryDirectory: linkURL)
      .cleanupOrphans(olderThan: cutoff)

    XCTAssertEqual(report.removedCount, 0)
    XCTAssertEqual(report.failureCount, 1)
    XCTAssertEqual(report.failures.first?.operation, .inspectTemporaryDirectory)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
  }

  func testRemovalRaceCannotRecursivelyDeleteAReplacementDirectory() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let replacementDirectory = directory.appendingPathComponent(
      "rill-raced.wav",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: replacementDirectory,
      withIntermediateDirectories: false
    )
    let nestedArtifact = try createFile(
      named: "nested-user-file.txt",
      in: replacementDirectory,
      modifiedAt: cutoff.addingTimeInterval(-1)
    )
    let fileSystem = ReplacementDirectoryRaceFileSystem(
      racedName: replacementDirectory.lastPathComponent,
      modificationDate: cutoff.addingTimeInterval(-1)
    )

    let report = RillTemporaryFileJanitor(
      temporaryDirectory: directory,
      fileSystem: fileSystem
    ).cleanupOrphans(olderThan: cutoff)

    XCTAssertEqual(report.removedCount, 0)
    XCTAssertEqual(report.failureCount, 1)
    XCTAssertEqual(report.failures.first?.operation, .removeArtifact)
    XCTAssertTrue(FileManager.default.fileExists(atPath: replacementDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nestedArtifact.path))
  }

  @discardableResult
  private func createFile(named name: String, in directory: URL, modifiedAt date: Date) throws
    -> URL
  {
    let url = directory.appendingPathComponent(name)
    try Data("temporary".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-janitor-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }
}

private struct SelectiveRemovalFailureFileSystem: RillTemporaryFileJanitorFileSystem {
  let blockedName: String
  private let base = FoundationTemporaryFileJanitorFileSystem()

  func isDirectoryWithoutFollowingSymbolicLinks(at url: URL) throws -> Bool {
    try base.isDirectoryWithoutFollowingSymbolicLinks(at: url)
  }

  func contentsOfDirectory(at url: URL) throws -> [URL] {
    try base.contentsOfDirectory(at: url)
  }

  func metadata(at url: URL) throws -> TemporaryFileJanitorMetadata {
    try base.metadata(at: url)
  }

  func removeItem(at url: URL) throws {
    guard url.lastPathComponent != blockedName else {
      throw SelectiveRemovalError.requested
    }
    try base.removeItem(at: url)
  }
}

private struct ReplacementDirectoryRaceFileSystem: RillTemporaryFileJanitorFileSystem {
  let racedName: String
  let modificationDate: Date
  private let base = FoundationTemporaryFileJanitorFileSystem()

  func isDirectoryWithoutFollowingSymbolicLinks(at url: URL) throws -> Bool {
    try base.isDirectoryWithoutFollowingSymbolicLinks(at: url)
  }

  func contentsOfDirectory(at url: URL) throws -> [URL] {
    try base.contentsOfDirectory(at: url)
  }

  func metadata(at url: URL) throws -> TemporaryFileJanitorMetadata {
    guard url.lastPathComponent == racedName else {
      return try base.metadata(at: url)
    }
    // Simulate a regular file being replaced by a directory after inspection.
    return TemporaryFileJanitorMetadata(
      isRegularFile: true,
      isSymbolicLink: false,
      modificationDate: modificationDate
    )
  }

  func removeItem(at url: URL) throws {
    try base.removeItem(at: url)
  }
}

private enum SelectiveRemovalError: Error {
  case requested
}
