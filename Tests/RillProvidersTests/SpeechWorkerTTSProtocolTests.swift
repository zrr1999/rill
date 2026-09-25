@testable import RillSpeechContracts
@testable import RillSpeech
import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class SpeechWorkerTTSProtocolTests: XCTestCase {
  func testTTSModelCatalogOffersPinnedPrecisionsAndDefaultsToInt8() {
    let descriptor = SpeechSynthesisModelCatalog.qwen3TTS06BCustomVoiceInt8

    XCTAssertEqual(
      SpeechSynthesisModelCatalog.supportedModels.map(\.id),
      [
        .qwen3TTS06BCustomVoiceInt4,
        .qwen3TTS06BCustomVoiceInt8,
        .qwen3TTS06BCustomVoiceBF16,
      ]
    )
    XCTAssertEqual(SpeechSynthesisModelCatalog.defaultModel.id, descriptor.id)
    XCTAssertEqual(
      descriptor.repository,
      "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
    )
    XCTAssertEqual(
      descriptor.revision,
      "049ef77fe8816b536193c0c25f9a214d17921282"
    )
    XCTAssertEqual(
      descriptor.files.reduce(UInt64(0)) { $0 + $1.byteCount },
      1_973_572_801
    )
  }

  func testTTSModelSelectionRejectsUnreviewedIdentifiers() {
    let source = SpeechSynthesisModelSelectionSource()

    XCTAssertEqual(
      source.currentModelIdentifier(),
      SpeechSynthesisModelCatalog.defaultModel.id.rawValue
    )
    XCTAssertTrue(
      source.selectModel(
        SpeechSynthesisModelCatalog.qwen3TTS06BCustomVoiceBF16.id.rawValue
      )
    )
    XCTAssertFalse(source.selectModel("unreviewed"))
    XCTAssertEqual(
      source.currentModelIdentifier(),
      SpeechSynthesisModelCatalog.qwen3TTS06BCustomVoiceBF16.id.rawValue
    )
  }

  func testProtocolVersionAndTTSOperationsRoundTrip() throws {
    XCTAssertEqual(SpeechWorkerProtocol.version, 5)
    let modelID = SpeechSynthesisModelCatalog.qwen3TTS06BCustomVoiceInt8.id.rawValue
    let prepare = SpeechWorkerRequest(
      requestID: UUID(),
      generation: 1,
      ttsModelPreparationPayload: SpeechWorkerModelPreparationPayload(
        modelID: modelID,
        downloadIfNeeded: true
      )
    )
    let synthesis = SpeechWorkerRequest(
      requestID: UUID(),
      generation: 2,
      synthesisPayload: SpeechWorkerSynthesisPayload(
        runID: UUID(),
        modelID: modelID,
        text: "你好 Rill",
        voice: Qwen3TTSVoice.vivian.rawValue,
        language: "zh-CN"
      )
    )
    let release = SpeechWorkerRequest(
      requestID: UUID(),
      generation: 3,
      releaseTTSModelID: modelID
    )

    for request in [prepare, synthesis, release] {
      let encoded = try SpeechWorkerProtocolCodec.encodeRequestLine(request)
      XCTAssertEqual(
        try SpeechWorkerProtocolCodec.decodeRequestLine(encoded.dropLast()),
        request
      )
    }

    let response = SpeechWorkerResponse.synthesized(
      request: synthesis,
      result: SpeechWorkerSynthesisResult(
        audioFilePath: "/tmp/rill-speech-protocol.wav",
        sampleRate: 24_000,
        channelCount: 1,
        durationSeconds: 0.5
      )
    )
    let encodedResponse = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    XCTAssertEqual(
      try SpeechWorkerProtocolCodec.decodeResponseLine(encodedResponse.dropLast()),
      response
    )
  }

  func testSynthesisRequestRejectsUnboundedText() {
    let request = SpeechWorkerRequest(
      requestID: UUID(),
      generation: 1,
      synthesisPayload: SpeechWorkerSynthesisPayload(
        runID: UUID(),
        modelID: SpeechSynthesisModelCatalog.qwen3TTS06BCustomVoiceInt8.id.rawValue,
        text: String(
          repeating: "x",
          count: SpeechSynthesisRequest.maximumTextScalarCount + 1
        ),
        voice: Qwen3TTSVoice.ryan.rawValue,
        language: "en-US"
      )
    )

    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeRequestLine(request)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .invalidRequest)
    }
  }
}
