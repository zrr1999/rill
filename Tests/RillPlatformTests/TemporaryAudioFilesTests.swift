import Foundation
import RillCore
import XCTest
@testable import RillPlatform

final class TemporaryAudioFilesTests: XCTestCase {
    func testIsolationSurvivesRemovalOfCaptureAndPreservesMetadata() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("rill-isolation-test-\(UUID()).wav")
        try Data([1, 2, 3, 4]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let audio = try capturedAudio(source)
        let isolated = try TemporaryAudioFiles.isolate(audio)
        defer { _ = try? isolated.removeManagedTemporaryFile() }
        XCTAssertNotEqual(isolated.fileURL, audio.fileURL)
        XCTAssertEqual(isolated.metadata, audio.metadata)
        XCTAssertEqual(isolated.durationSeconds, audio.durationSeconds)
        XCTAssertEqual(isolated.format, audio.format)
        _ = try audio.removeManagedTemporaryFile()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(isolated.fileURL)), Data([1, 2, 3, 4]))
    }

    func testIsolationRejectsSymbolicLinkWithoutTouchingCallerFile() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("caller-audio-\(UUID()).wav")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("rill-isolation-link-\(UUID()).wav")
        try Data([1, 2, 3, 4]).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: source)
        }
        XCTAssertThrowsError(try TemporaryAudioFiles.isolate(capturedAudio(link)))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3, 4]))
        let callerManaged = try CapturedAudio(durationSeconds: 1, format: format, fileURL: source)
        XCTAssertEqual(try TemporaryAudioFiles.isolate(callerManaged), callerManaged)
    }

    private let format = AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16)
    private func capturedAudio(_ url: URL) throws -> CapturedAudio {
        try CapturedAudio(durationSeconds: 1, format: format, fileURL: url,
            fileOwnership: .managedTemporary, metadata: ["test": "preserved"])
    }
}
