import AppKit
import Foundation
import Testing

@testable import RillApp

@MainActor struct BufferFilePromiseTests {
  @Test func imagePromiseProducesValidPNGAndRejectsCorruptData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rill-png-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let tiff = try #require(bitmap.tiffRepresentation)
    for (index, bytes) in [tiff, Data([1, 2, 3])].enumerated() {
      let writer = BufferFilePromiseWriter(source: .image(bytes), feedback: { _ in })
      let destination = root.appendingPathComponent("\(index).png")
      let error: Error? = await withCheckedContinuation { continuation in
        writer.filePromiseProvider(writer.provider(), writePromiseTo: destination) {
          continuation.resume(returning: $0)
        }
      }
      if index == 0 {
        #expect(error == nil)
        #expect(
          try Data(contentsOf: destination).prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
      } else {
        #expect(error != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
      }
    }
  }

  @Test func promisesCopyFilesAndNeverOverwriteOrMoveSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-promise-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("source.txt")
    let destination = root.appendingPathComponent("copy.txt")
    try Data("中文🙂".utf8).write(to: original)
    let writer = BufferFilePromiseWriter(source: .file(original), feedback: { _ in })
    let provider = writer.provider()
    let clipboardCount = NSPasteboard.general.changeCount
    let error: Error? = await withCheckedContinuation { continuation in
      writer.filePromiseProvider(provider, writePromiseTo: destination) {
        continuation.resume(returning: $0)
      }
    }
    #expect(error == nil)
    #expect(try Data(contentsOf: original) == Data(contentsOf: destination))
    let duplicate: Error? = await withCheckedContinuation { continuation in
      writer.filePromiseProvider(provider, writePromiseTo: destination) {
        continuation.resume(returning: $0)
      }
    }
    #expect(duplicate != nil)
    #expect(try Data(contentsOf: original) == Data(contentsOf: destination))
    #expect(NSPasteboard.general.changeCount == clipboardCount)
  }

  @Test func missingFileAndFailedImageDestinationReportFailure() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for source in [BufferFilePromiseWriter.Source.file(missing), .image(Data([1, 2, 3]))] {
      let writer = BufferFilePromiseWriter(source: source, feedback: { _ in })
      let provider = writer.provider()
      let error: Error? = await withCheckedContinuation { continuation in
        writer.filePromiseProvider(
          provider, writePromiseTo: missing.appendingPathComponent("missing/file")
        ) {
          continuation.resume(returning: $0)
        }
      }
      #expect(error != nil)
    }
  }
}
