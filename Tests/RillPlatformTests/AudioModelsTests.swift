import Foundation
import XCTest
@testable import RillCore
@testable import RillPlatform

final class AudioModelsTests: XCTestCase {
    func testCaptureRequestEqualityIncludesLifetimeIdentity() {
        let runID = UUID()
        let lifetime = AudioCaptureLifetime(runID: runID)
        let workflow = WorkflowDefinition(
            name: "Audio equality",
            pipeline: PipelineDeclaration(recognizerID: "local", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let request = AudioCaptureRequest(
            runID: runID,
            workflow: workflow,
            audioLifetime: lifetime
        )
        let sameAuthorization = AudioCaptureRequest(
            runID: runID,
            workflow: workflow,
            audioLifetime: lifetime
        )
        let distinctAuthorization = AudioCaptureRequest(
            runID: runID,
            workflow: workflow,
            audioLifetime: AudioCaptureLifetime(runID: runID)
        )

        XCTAssertEqual(request, sameAuthorization)
        XCTAssertNotEqual(request, distinctAuthorization)
    }

    func testCapturedAudioRejectsMissingPayload() {
        XCTAssertThrowsError(
            try CapturedAudio(
                durationSeconds: 1.2,
                format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16)
            )
        ) { error in
            XCTAssertEqual(error as? CapturedAudio.ValidationError, .missingPayload)
        }
    }

    func testCapturedAudioAllowsInlinePayload() throws {
        let audio = try CapturedAudio(
            durationSeconds: 1.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([0x00, 0x01, 0x02])
        )

        XCTAssertEqual(audio.inlineData, Data([0x00, 0x01, 0x02]))
        XCTAssertNil(audio.fileURL)
        XCTAssertEqual(audio.fileOwnership, .callerManaged)
    }

    func testManagedTemporaryFileCanBeRemoved() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-audio-model-" + UUID().uuidString + ".wav")
        try Data([0x00]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let audio = try CapturedAudio(
            durationSeconds: 1.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )

        XCTAssertTrue(try audio.removeManagedTemporaryFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(try audio.removeManagedTemporaryFile(), "Cleanup must be idempotent.")
    }

    func testCallerManagedFileIsNeverRemoved() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-caller-audio-" + UUID().uuidString + ".wav")
        try Data([0x00]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let audio = try CapturedAudio(
            durationSeconds: 1.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL
        )

        XCTAssertFalse(try audio.removeManagedTemporaryFile())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testManagedTemporaryOwnershipRejectsFilesOutsideRillNamespace() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("third-party-audio-" + UUID().uuidString + ".wav")

        XCTAssertThrowsError(
            try CapturedAudio(
                durationSeconds: 1.2,
                format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
                fileURL: fileURL,
                fileOwnership: .managedTemporary
            )
        ) { error in
            XCTAssertEqual(
                error as? CapturedAudio.ValidationError,
                .invalidManagedTemporaryFileURL
            )
        }
    }

    func testManagedTemporaryCleanupNeverRemovesDirectory() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-audio-directory-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let audio = try CapturedAudio(
            durationSeconds: 1.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: directoryURL,
            fileOwnership: .managedTemporary
        )

        XCTAssertFalse(try audio.removeManagedTemporaryFile())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testLegacyPayloadDefaultsToCallerManagedOwnership() throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-legacy-audio.wav")
        let original = try CapturedAudio(
            durationSeconds: 1.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: legacyURL,
            fileOwnership: .managedTemporary
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fileOwnership")
        let legacyPayload = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CapturedAudio.self, from: legacyPayload)

        XCTAssertEqual(decoded.fileOwnership, .callerManaged)
    }
}
