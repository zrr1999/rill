@preconcurrency import AVFoundation
import Foundation
import XCTest

@testable import RillPlatform

final class LocalSpeechIncrementalWaveWriterTests: XCTestCase {
  func testProductCaptureCeilingIncludesBoundedStartupTolerance() {
    XCTAssertEqual(LocalSpeechIncrementalWaveWriter.maximumRequestedDurationSeconds, 120)
    XCTAssertEqual(LocalSpeechIncrementalWaveWriter.maximumStartupGraceSeconds, 3.1)
    XCTAssertEqual(LocalSpeechIncrementalWaveWriter.maximumSupportedDurationSeconds, 123.1)
    XCTAssertEqual(LocalSpeechIncrementalWaveWriter.maximumSupportedFrameCount, 1_969_600)
  }

  func testIncrementalWriterProducesPrivateCompleteMultiChunkWaveFile() throws {
    let outputURL = makeWriterTestURL()
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let expectedSamples: [Float] = [0.1, -0.2, 0.3, 0.4, -0.5]
    let writer = try LocalSpeechIncrementalWaveWriter(
      fileURL: outputURL,
      maximumFrameCount: expectedSamples.count
    )

    try writer.append(Array(expectedSamples.prefix(2)))
    try writer.append(Array(expectedSamples.dropFirst(2)))
    let artifact = try writer.finalize()

    XCTAssertEqual(artifact.fileURL, outputURL)
    XCTAssertEqual(artifact.frameCount, expectedSamples.count)
    XCTAssertEqual(try filePermissions(at: outputURL), 0o600)
    let actualSamples = try readWaveSamples(from: outputURL)
    XCTAssertEqual(actualSamples.count, expectedSamples.count)
    for (actual, expected) in zip(actualSamples, expectedSamples) {
      XCTAssertEqual(actual, expected, accuracy: 0.0001)
    }
  }

  func testFrameCeilingAcceptsExactBoundaryAndRejectsOneFrameOverWithoutPartialWrite()
    throws
  {
    let outputURL = makeWriterTestURL()
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let writer = try LocalSpeechIncrementalWaveWriter(
      fileURL: outputURL,
      maximumFrameCount: 4
    )

    try writer.append([0.1, 0.2, 0.3, 0.4])
    XCTAssertThrowsError(try writer.append([0.5])) { error in
      XCTAssertEqual(
        error as? LocalSpeechIncrementalWaveWriterError,
        .frameLimitExceeded
      )
    }
    let artifact = try writer.finalize()

    XCTAssertEqual(artifact.frameCount, 4)
    XCTAssertEqual(try readWaveSamples(from: outputURL).count, 4)
  }

  func testRemovingFrameCeilingAllowsTheCurrentWriterToContinue() throws {
    let outputURL = makeWriterTestURL()
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let writer = try LocalSpeechIncrementalWaveWriter(
      fileURL: outputURL,
      maximumFrameCount: 4
    )

    try writer.append([0.1, 0.2, 0.3, 0.4])
    writer.removeFrameLimit()
    try writer.append([0.5, 0.6])
    let artifact = try writer.finalize()

    XCTAssertEqual(artifact.frameCount, 6)
    XCTAssertEqual(try readWaveSamples(from: outputURL).count, 6)
  }

  func testNegativeFrameCeilingFailsClosedWithoutCreatingAFile() {
    let outputURL = makeWriterTestURL()

    XCTAssertThrowsError(
      try LocalSpeechIncrementalWaveWriter(
        fileURL: outputURL,
        maximumFrameCount: -1
      )
    ) { error in
      XCTAssertEqual(
        error as? LocalSpeechIncrementalWaveWriterError,
        .invalidFrameLimit
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
  }

  private func makeWriterTestURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-local-writer-\(UUID().uuidString)")
      .appendingPathExtension("wav")
  }

  private func filePermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
  }

  private func readWaveSamples(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
    )
    try file.read(into: buffer)
    let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }
}
