import Foundation
import RillCore

public extension CapturedAudio {
    @discardableResult
    func removeManagedTemporaryFile(
        using fileManager: FileManager = .default
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard
            fileOwnership == .managedTemporary,
            let fileURL,
            Self.isManagedTemporaryFileURL(fileURL, using: fileManager),
            fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return false
        }

        try fileManager.removeItem(at: fileURL)
        return true
    }
}

public extension SpeechAsset {
    @discardableResult
    func removeManagedTemporaryFile(
        using fileManager: FileManager = .default
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard
            ownership == .managedTemporary,
            Self.isManagedTemporaryFileURL(fileURL, using: fileManager),
            fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        return true
    }
}

private enum RecognitionAudioIsolationError: Error, LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? {
    "Speech recognition could not safely prepare the recorded audio."
  }
}

public enum TemporaryAudioFiles {
  /// The provider gets a separate file lifetime so a timeout cannot remove audio it still reads.
  public static func isolate(_ capturedAudio: CapturedAudio) throws -> CapturedAudio {
    guard capturedAudio.fileOwnership == .managedTemporary, let sourceURL = capturedAudio.fileURL else {
      return capturedAudio
    }
    let resourceValues: URLResourceValues
    do {
      resourceValues = try sourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
    } catch {
      throw RecognitionAudioIsolationError.unavailable
    }
    guard resourceValues.isRegularFile == true,
      resourceValues.isSymbolicLink != true
    else {
      throw RecognitionAudioIsolationError.unavailable
    }

    let fileManager = FileManager.default
    var isolatedURL = fileManager.temporaryDirectory
      .appendingPathComponent(
        "\(RecognitionTemporaryAudioNamespace.currentProcessFilenamePrefix)\(UUID().uuidString)"
      )
    if !sourceURL.pathExtension.isEmpty {
      isolatedURL.appendPathExtension(sourceURL.pathExtension)
    }

    do {
      try fileManager.linkItem(at: sourceURL, to: isolatedURL)
    } catch {
      try? fileManager.removeItem(at: isolatedURL)
      do {
        try fileManager.copyItem(at: sourceURL, to: isolatedURL)
      } catch {
        try? fileManager.removeItem(at: isolatedURL)
        throw RecognitionAudioIsolationError.unavailable
      }
    }

    do {
      let isolatedAudio = try CapturedAudio(
        durationSeconds: capturedAudio.durationSeconds,
        format: capturedAudio.format,
        fileURL: isolatedURL,
        inlineData: capturedAudio.inlineData,
        fileOwnership: .managedTemporary,
        metadata: capturedAudio.metadata
      )
      return isolatedAudio
    } catch {
      try? fileManager.removeItem(at: isolatedURL)
      throw RecognitionAudioIsolationError.unavailable
    }
  }
}
