import Darwin
import Foundation
import RillCore

/// Removes abandoned temporary artifacts created by Rill without exposing their paths.
public struct RillTemporaryFileJanitor: Sendable {
  public static let defaultMinimumAge: TimeInterval = 24 * 60 * 60

  public enum ArtifactKind: String, Sendable, Equatable, CaseIterable {
    case shortcutText = "shortcut-text"
    case audioCapture = "audio-capture"
    case recoveryAudio = "recovery-audio"
    case recognitionWork = "recognition-work"
    case liveCapture = "live-capture"
    case deepgramLiveCapture = "deepgram-live-capture"
  }

  public enum FailureOperation: String, Sendable, Equatable {
    case inspectTemporaryDirectory = "inspect-temporary-directory"
    case enumerateTemporaryDirectory = "enumerate-temporary-directory"
    case inspectArtifact = "inspect-artifact"
    case removeArtifact = "remove-artifact"
  }

  public struct ArtifactCounts: Sendable, Equatable {
    public private(set) var shortcutText = 0
    public private(set) var audioCapture = 0
    public private(set) var recoveryAudio = 0
    public private(set) var recognitionWork = 0
    public private(set) var liveCapture = 0
    public private(set) var deepgramLiveCapture = 0

    public var total: Int {
      shortcutText + audioCapture + recoveryAudio + recognitionWork + liveCapture
        + deepgramLiveCapture
    }

    public subscript(kind: ArtifactKind) -> Int {
      switch kind {
      case .shortcutText:
        shortcutText
      case .audioCapture:
        audioCapture
      case .recoveryAudio:
        recoveryAudio
      case .recognitionWork:
        recognitionWork
      case .liveCapture:
        liveCapture
      case .deepgramLiveCapture:
        deepgramLiveCapture
      }
    }

    fileprivate mutating func increment(_ kind: ArtifactKind) {
      switch kind {
      case .shortcutText:
        shortcutText += 1
      case .audioCapture:
        audioCapture += 1
      case .recoveryAudio:
        recoveryAudio += 1
      case .recognitionWork:
        recognitionWork += 1
      case .liveCapture:
        liveCapture += 1
      case .deepgramLiveCapture:
        deepgramLiveCapture += 1
      }
    }
  }

  /// A count-only failure summary. It intentionally contains no URL or underlying error text.
  public struct FailureSummary: Sendable, Equatable {
    public let operation: FailureOperation
    public let artifactKind: ArtifactKind?
    public let count: Int

    fileprivate init(
      operation: FailureOperation,
      artifactKind: ArtifactKind?,
      count: Int
    ) {
      self.operation = operation
      self.artifactKind = artifactKind
      self.count = count
    }
  }

  public struct Report: Sendable, Equatable {
    public let removed: ArtifactCounts
    public let failures: [FailureSummary]

    public var removedCount: Int {
      removed.total
    }

    public var failureCount: Int {
      failures.reduce(0) { $0 + $1.count }
    }

    fileprivate init(removed: ArtifactCounts, failures: [FailureSummary]) {
      self.removed = removed
      self.failures = failures
    }
  }

  private let temporaryDirectory: URL
  private let fileSystem: any RillTemporaryFileJanitorFileSystem

  public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
    self.init(
      temporaryDirectory: temporaryDirectory,
      fileSystem: FoundationTemporaryFileJanitorFileSystem()
    )
  }

  init(
    temporaryDirectory: URL,
    fileSystem: any RillTemporaryFileJanitorFileSystem
  ) {
    self.temporaryDirectory = temporaryDirectory.standardizedFileURL
    self.fileSystem = fileSystem
  }

  /// Retains regular artifacts for 24 hours and removes recovery plaintext immediately.
  ///
  /// Recognition work can still belong to a non-cooperative recognizer, so only
  /// the startup-specific sweep may remove it without consulting a live owner.
  public func cleanupOrphans(now: Date = Date()) -> Report {
    cleanupOrphans(
      regularArtifactsOlderThan: now.addingTimeInterval(-Self.defaultMinimumAge),
      recoveryArtifactsOlderThan: now,
      recognitionArtifactsOlderThan: nil
    )
  }

  /// Removes crash leftovers while preserving the current process namespace.
  func cleanupStartupOrphans(now: Date = Date()) -> Report {
    cleanupOrphans(
      regularArtifactsOlderThan: now.addingTimeInterval(-Self.defaultMinimumAge),
      recoveryArtifactsOlderThan: now,
      recognitionArtifactsOlderThan: now
    )
  }

  /// Removes matching regular, non-symbolic-link artifacts modified strictly before `cutoff`.
  public func cleanupOrphans(olderThan cutoff: Date) -> Report {
    cleanupOrphans(
      regularArtifactsOlderThan: cutoff,
      recoveryArtifactsOlderThan: cutoff,
      recognitionArtifactsOlderThan: nil
    )
  }

  /// Removes every regular recovery plaintext artifact immediately. This is
  /// used for opt-out and explicit clear operations; unrelated Rill
  /// temporary files, including live recognition work, remain untouched.
  public func cleanupRecoveryArtifacts() -> Report {
    cleanupOrphans(
      regularArtifactsOlderThan: nil,
      recoveryArtifactsOlderThan: .distantFuture,
      recognitionArtifactsOlderThan: nil
    )
  }

  private func cleanupOrphans(
    regularArtifactsOlderThan regularCutoff: Date?,
    recoveryArtifactsOlderThan recoveryCutoff: Date?,
    recognitionArtifactsOlderThan recognitionCutoff: Date?
  ) -> Report {
    var accumulator = CleanupAccumulator()

    do {
      guard try fileSystem.isDirectoryWithoutFollowingSymbolicLinks(at: temporaryDirectory) else {
        accumulator.recordFailure(operation: .inspectTemporaryDirectory, artifactKind: nil)
        return accumulator.report
      }
    } catch {
      accumulator.recordFailure(operation: .inspectTemporaryDirectory, artifactKind: nil)
      return accumulator.report
    }

    let entries: [URL]
    do {
      entries = try fileSystem.contentsOfDirectory(at: temporaryDirectory)
    } catch {
      accumulator.recordFailure(operation: .enumerateTemporaryDirectory, artifactKind: nil)
      return accumulator.report
    }

    for entry in entries {
      guard let artifactKind = Self.artifactKind(for: entry.lastPathComponent) else {
        continue
      }
      if artifactKind == .recognitionWork,
        entry.lastPathComponent.hasPrefix(
          RecognitionTemporaryAudioNamespace.currentProcessFilenamePrefix
        )
      {
        continue
      }

      let metadata: TemporaryFileJanitorMetadata
      do {
        metadata = try fileSystem.metadata(at: entry)
      } catch {
        accumulator.recordFailure(operation: .inspectArtifact, artifactKind: artifactKind)
        continue
      }

      guard metadata.isRegularFile, !metadata.isSymbolicLink else {
        continue
      }
      guard let modificationDate = metadata.modificationDate else {
        accumulator.recordFailure(operation: .inspectArtifact, artifactKind: artifactKind)
        continue
      }
      let cutoff =
        switch artifactKind {
        case .recoveryAudio:
          recoveryCutoff
        case .recognitionWork:
          recognitionCutoff
        default:
          regularCutoff
        }
      guard let cutoff else { continue }
      guard modificationDate < cutoff else {
        continue
      }

      do {
        try fileSystem.removeItem(at: entry)
        accumulator.removed.increment(artifactKind)
      } catch {
        accumulator.recordFailure(operation: .removeArtifact, artifactKind: artifactKind)
      }
    }

    return accumulator.report
  }

  private static func artifactKind(for filename: String) -> ArtifactKind? {
    if hasPayload(filename, prefix: "rill-shortcut-", suffix: ".txt") {
      return .shortcutText
    }
    if hasPayload(filename, prefix: "rill-deepgram-live-", suffix: ".wav") {
      return .deepgramLiveCapture
    }
    if hasPayload(filename, prefix: "rill-recovery-", suffix: ".wav") {
      return .recoveryAudio
    }
    if hasPrefixedPayload(
      filename,
      prefix: RecognitionTemporaryAudioNamespace.filenamePrefix
    ) {
      return .recognitionWork
    }
    if hasPayload(filename, prefix: "rill-live-", suffix: ".wav") {
      return .liveCapture
    }
    if hasPayload(filename, prefix: "rill-", suffix: ".wav") {
      return .audioCapture
    }
    return nil
  }

  private static func hasPayload(_ filename: String, prefix: String, suffix: String) -> Bool {
    filename.hasPrefix(prefix)
      && filename.hasSuffix(suffix)
      && filename.count > prefix.count + suffix.count
  }

  private static func hasPrefixedPayload(_ filename: String, prefix: String) -> Bool {
    filename.hasPrefix(prefix) && filename.count > prefix.count
  }
}

private struct CleanupAccumulator {
  var removed = RillTemporaryFileJanitor.ArtifactCounts()
  private var failures: [RillTemporaryFileJanitor.FailureSummary] = []

  var report: RillTemporaryFileJanitor.Report {
    .init(removed: removed, failures: failures.sorted(by: Self.failureOrder))
  }

  mutating func recordFailure(
    operation: RillTemporaryFileJanitor.FailureOperation,
    artifactKind: RillTemporaryFileJanitor.ArtifactKind?
  ) {
    if let index = failures.firstIndex(where: {
      $0.operation == operation && $0.artifactKind == artifactKind
    }) {
      let failure = failures[index]
      failures[index] = .init(
        operation: operation,
        artifactKind: artifactKind,
        count: failure.count + 1
      )
    } else {
      failures.append(.init(operation: operation, artifactKind: artifactKind, count: 1))
    }
  }

  private static func failureOrder(
    _ lhs: RillTemporaryFileJanitor.FailureSummary,
    _ rhs: RillTemporaryFileJanitor.FailureSummary
  ) -> Bool {
    if lhs.operation.rawValue != rhs.operation.rawValue {
      return lhs.operation.rawValue < rhs.operation.rawValue
    }
    return (lhs.artifactKind?.rawValue ?? "") < (rhs.artifactKind?.rawValue ?? "")
  }
}

struct TemporaryFileJanitorMetadata: Sendable {
  let isRegularFile: Bool
  let isSymbolicLink: Bool
  let modificationDate: Date?
}

protocol RillTemporaryFileJanitorFileSystem: Sendable {
  func isDirectoryWithoutFollowingSymbolicLinks(at url: URL) throws -> Bool
  func contentsOfDirectory(at url: URL) throws -> [URL]
  func metadata(at url: URL) throws -> TemporaryFileJanitorMetadata
  func removeItem(at url: URL) throws
}

struct FoundationTemporaryFileJanitorFileSystem: RillTemporaryFileJanitorFileSystem {
  private static let artifactResourceKeys: Set<URLResourceKey> = [
    .contentModificationDateKey,
    .isRegularFileKey,
    .isSymbolicLinkKey,
  ]

  func isDirectoryWithoutFollowingSymbolicLinks(at url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  func contentsOfDirectory(at url: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: Array(Self.artifactResourceKeys),
      options: []
    )
  }

  func metadata(at url: URL) throws -> TemporaryFileJanitorMetadata {
    let values = try url.resourceValues(forKeys: Self.artifactResourceKeys)
    return TemporaryFileJanitorMetadata(
      isRegularFile: values.isRegularFile == true,
      isSymbolicLink: values.isSymbolicLink == true,
      modificationDate: values.contentModificationDate
    )
  }

  func removeItem(at url: URL) throws {
    // `unlink` never recursively removes a directory and does not follow a final symlink.
    // This keeps a metadata-check-to-delete race from turning into recursive deletion.
    guard Darwin.unlink(url.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
