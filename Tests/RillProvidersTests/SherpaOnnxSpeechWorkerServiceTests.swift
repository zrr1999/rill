import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class SherpaOnnxSpeechWorkerServiceTests: XCTestCase {
  func testServiceRejectsSymlinkedManagedAudioBeforeRecognition() async throws {
    let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-worker-target-\(UUID().uuidString).wav"
    )
    let symlinkURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-worker-symlink-\(UUID().uuidString).wav"
    )
    defer {
      try? FileManager.default.removeItem(at: symlinkURL)
      try? FileManager.default.removeItem(at: targetURL)
    }
    XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: Data([0])))
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
    let request = makeRequest(audioFilePath: symlinkURL.path)

    let response = await SherpaOnnxSpeechWorkerService().handle(request)

    XCTAssertEqual(response.status, .failure)
    XCTAssertEqual(response.failure, .invalidAudio)
    XCTAssertNil(response.result)
  }

  func testServiceRejectsRegularFileOutsideManagedTemporaryNamespace() async {
    let request = makeRequest(audioFilePath: "/etc/hosts")

    let response = await SherpaOnnxSpeechWorkerService().handle(request)

    XCTAssertEqual(response.status, .failure)
    XCTAssertEqual(response.failure, .invalidAudio)
  }

  func testServiceRejectsNonDistributableModelWithoutReturningInputDetails() async throws {
    var request = makeRequest(audioFilePath: "/tmp/rill-private-transcript.wav")
    request.recognitionPayload?.modelID = SherpaOnnxModelID.senseVoiceSmallInt8.rawValue

    let response = await SherpaOnnxSpeechWorkerService().handle(request)
    let encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertEqual(response.failure, .unsupportedModel)
    XCTAssertFalse(text.contains(request.recognitionPayload!.audioFilePath))
    XCTAssertFalse(text.contains(request.recognitionPayload!.modelID))
  }

  private func makeRequest(audioFilePath: String) -> SpeechWorkerRequest {
    SpeechWorkerRequest(
      requestID: UUID(),
      generation: 1,
      payload: SpeechWorkerRecognitionPayload(
        runID: UUID(),
        modelID: SherpaOnnxModelCatalog.defaultModelID.rawValue,
        language: "zh-CN",
        keyterms: ["Rill"],
        threadCount: 2,
        audioFilePath: audioFilePath,
        audioDurationSeconds: 1,
        audioFormat: AudioFormat(
          sampleRateHz: 16_000,
          channelCount: 1,
          encoding: .float32
        )
      )
    )
  }
}
