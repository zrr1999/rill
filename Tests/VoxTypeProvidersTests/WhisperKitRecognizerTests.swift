import XCTest
@testable import VoxTypeCore
@testable import VoxTypeProviders

final class WhisperKitRecognizerTests: XCTestCase {
    func testRecognizerRequiresCapturedAudio() async {
        let recognizer = WhisperKitRecognizer()
        let request = RecognitionRequest(
            runID: UUID(),
            workflow: makeWorkflow(),
            contextSnapshot: .empty
        )

        do {
            _ = try await recognizer.recognize(request)
            XCTFail("Expected missingCapturedAudio error")
        } catch let error as WhisperKitRecognizer.RecognizerError {
            XCTAssertEqual(error, .missingCapturedAudio)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecognizerRequiresFileBackedAudio() async throws {
        let recognizer = WhisperKitRecognizer()
        let capturedAudio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([0x00, 0x01])
        )
        let request = RecognitionRequest(
            runID: UUID(),
            workflow: makeWorkflow(),
            contextSnapshot: .empty,
            capturedAudio: capturedAudio
        )

        do {
            _ = try await recognizer.recognize(request)
            XCTFail("Expected fileBackedAudioRequired error")
        } catch let error as WhisperKitRecognizer.RecognizerError {
            XCTAssertEqual(error, .fileBackedAudioRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    #if !canImport(WhisperKit)
    func testRecognizerReportsUnavailableWhenWhisperKitIsNotLinked() async throws {
        let recognizer = WhisperKitRecognizer()
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtype-whisperkit-test")
            .appendingPathExtension("wav")
        try Data().write(to: temporaryFile)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        let capturedAudio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: temporaryFile
        )
        let request = RecognitionRequest(
            runID: UUID(),
            workflow: makeWorkflow(),
            contextSnapshot: .empty,
            capturedAudio: capturedAudio
        )

        do {
            _ = try await recognizer.recognize(request)
            XCTFail("Expected integrationUnavailable error")
        } catch let error as WhisperKitRecognizer.RecognizerError {
            XCTAssertEqual(error, .integrationUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPrepareModelReportsUnavailableWhenWhisperKitIsNotLinked() async {
        let recognizer = WhisperKitRecognizer()

        do {
            try await recognizer.prepareModel()
            XCTFail("Expected integrationUnavailable error")
        } catch let error as WhisperKitRecognizer.RecognizerError {
            XCTAssertEqual(error, .integrationUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    #endif
}

private func makeWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
        name: "WhisperKit Test Workflow",
        pipeline: PipelineDeclaration(
            recognizerID: "whisperkit.local",
            outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal"),
        metadata: ["recognizer.language": "en"]
    )
}
