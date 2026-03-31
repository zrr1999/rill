import XCTest
@testable import VoxTypeCore
@testable import VoxTypeProviders

final class DeepgramRecognizerTests: XCTestCase {
    func testRecognizerRequiresCapturedAudio() async {
        let recognizer = DeepgramRecognizer(configuration: .init(apiKey: "test-key"))
        let request = RecognitionRequest(
            runID: UUID(),
            workflow: makeDeepgramWorkflow(),
            contextSnapshot: .empty
        )

        do {
            _ = try await recognizer.recognize(request)
            XCTFail("Expected missingCapturedAudio error")
        } catch let error as DeepgramRecognizer.RecognizerError {
            XCTAssertEqual(error, .missingCapturedAudio)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecognizerRequiresFileBackedAudio() async throws {
        let recognizer = DeepgramRecognizer(configuration: .init(apiKey: "test-key"))
        let capturedAudio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([0x00, 0x01])
        )
        let request = RecognitionRequest(
            runID: UUID(),
            workflow: makeDeepgramWorkflow(),
            contextSnapshot: .empty,
            capturedAudio: capturedAudio
        )

        do {
            _ = try await recognizer.recognize(request)
            XCTFail("Expected fileBackedAudioRequired error")
        } catch let error as DeepgramRecognizer.RecognizerError {
            XCTAssertEqual(error, .fileBackedAudioRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecognizerRequiresAPIKey() async throws {
        let recognizer = DeepgramRecognizer(configuration: .init(apiKey: nil))
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtype-deepgram-test")
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
            workflow: makeDeepgramWorkflow(),
            contextSnapshot: .empty,
            capturedAudio: capturedAudio
        )

        do {
            _ = try await recognizer.recognize(request)
            XCTFail("Expected missingAPIKey error")
        } catch let error as DeepgramRecognizer.RecognizerError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private func makeDeepgramWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
        name: "Deepgram Test Workflow",
        pipeline: PipelineDeclaration(
            recognizerID: "deepgram.prerecorded",
            outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "icloud", accentColorName: "cyan"),
        metadata: [
            "recognizer.language": "en-US",
            "deepgram.model": "nova-3",
        ]
    )
}
