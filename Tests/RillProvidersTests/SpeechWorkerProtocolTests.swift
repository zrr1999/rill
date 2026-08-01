import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class SpeechWorkerProtocolTests: XCTestCase {
  func testRequestAndResponseRoundTripThroughBoundedJSONLines() throws {
    let request = makeRequest()
    let requestLine = try SpeechWorkerProtocolCodec.encodeRequestLine(request)

    XCTAssertEqual(requestLine.last, 0x0A)
    XCTAssertLessThanOrEqual(
      requestLine.count - 1,
      SpeechWorkerProtocol.maximumRequestByteCount
    )
    XCTAssertEqual(
      try SpeechWorkerProtocolCodec.decodeRequestLine(requestLine.dropLast()),
      request
    )

    let response = SpeechWorkerResponse.success(
      request: request,
      result: SpeechWorkerRecognitionResult(
        rawText: "你好 Rill",
        bestText: "你好 Rill",
        metadata: ["provider.model": request.recognitionPayload!.modelID],
        processingDurationMillis: 42
      )
    )
    let responseLine = try SpeechWorkerProtocolCodec.encodeResponseLine(response)

    XCTAssertEqual(responseLine.last, 0x0A)
    XCTAssertEqual(
      try SpeechWorkerProtocolCodec.decodeResponseLine(responseLine.dropLast()),
      response
    )
  }

  func testRequestRejectsUnboundedOrNonAbsoluteAudioPath() {
    var request = makeRequest()
    request.recognitionPayload?.audioFilePath = "relative.wav"
    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeRequestLine(request)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .invalidRequest)
    }

    request = makeRequest()
    request.recognitionPayload?.audioFilePath =
      "/"
      + String(
        repeating: "x",
        count: SpeechWorkerProtocol.maximumAudioPathByteCount
      )
    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeRequestLine(request)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .invalidRequest)
    }
  }

  func testLongAudioIsAcceptedOnlyForTrustedMLXModels() throws {
    var mlxRequest = makeRequest()
    mlxRequest.recognitionPayload?.modelID = MLXAudioModelID.qwen3ASR17BInt8.rawValue
    mlxRequest.recognitionPayload?.audioDurationSeconds = 3_600
    XCTAssertNoThrow(try SpeechWorkerProtocolCodec.encodeRequestLine(mlxRequest))

    var sherpaRequest = makeRequest()
    sherpaRequest.recognitionPayload?.audioDurationSeconds = 3_600
    XCTAssertThrowsError(
      try SpeechWorkerProtocolCodec.encodeRequestLine(sherpaRequest)
    ) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .invalidRequest)
    }
  }

  func testResponseRejectsTranscriptLargerThanTheFrameBudget() {
    let request = makeRequest()
    let response = SpeechWorkerResponse.success(
      request: request,
      result: SpeechWorkerRecognitionResult(
        rawText: String(
          repeating: "x",
          count: SpeechWorkerProtocol.maximumResponseByteCount
        ),
        bestText: "bounded",
        metadata: [:],
        processingDurationMillis: nil
      )
    )

    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeResponseLine(response)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .frameTooLarge)
    }
  }

  func testLineReaderPreservesFollowingFrameAndRejectsUnterminatedInput() throws {
    let twoFrames = Pipe()
    let reader = SpeechWorkerBoundedLineReader(fileHandle: twoFrames.fileHandleForReading)
    try twoFrames.fileHandleForWriting.write(contentsOf: Data("one\ntwo\n".utf8))

    XCTAssertEqual(
      try reader.readLine(maximumByteCount: 16),
      Data("one".utf8)
    )
    XCTAssertEqual(
      try reader.readLine(maximumByteCount: 16),
      Data("two".utf8)
    )
    try twoFrames.fileHandleForWriting.close()
    XCTAssertNil(try reader.readLine(maximumByteCount: 16))

    let unterminated = Pipe()
    let unterminatedReader = SpeechWorkerBoundedLineReader(
      fileHandle: unterminated.fileHandleForReading
    )
    try unterminated.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
    try unterminated.fileHandleForWriting.close()
    XCTAssertThrowsError(try unterminatedReader.readLine(maximumByteCount: 16)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .unterminatedFrame)
    }
  }

  func testFailureResponseCarriesOnlyFixedCodeAndCoordinates() throws {
    let request = makeRequest()
    let response = SpeechWorkerResponse.failure(request: request, code: .invalidAudio)
    let encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertTrue(text.contains(SpeechWorkerFailureCode.invalidAudio.rawValue))
    XCTAssertFalse(text.contains(request.recognitionPayload!.audioFilePath))
    XCTAssertFalse(text.contains("transcript"))
  }

  func testModelPreparationRoundTripsWithoutAnAudioPayload() throws {
    let request = SpeechWorkerRequest(
      requestID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
      generation: 2,
      modelPreparationPayload: SpeechWorkerModelPreparationPayload(
        modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
        downloadIfNeeded: true
      )
    )
    let encodedRequest = try SpeechWorkerProtocolCodec.encodeRequestLine(request)
    XCTAssertEqual(
      try SpeechWorkerProtocolCodec.decodeRequestLine(encodedRequest.dropLast()),
      request
    )

    let response = SpeechWorkerResponse.prepared(
      request: request,
      modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue
    )
    let encodedResponse = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    XCTAssertEqual(
      try SpeechWorkerProtocolCodec.decodeResponseLine(encodedResponse.dropLast()),
      response
    )
  }

  func testPreparationProgressRoundTripsAndRejectsInvalidCounts() throws {
    let request = SpeechWorkerRequest(
      requestID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
      generation: 3,
      modelPreparationPayload: SpeechWorkerModelPreparationPayload(
        modelID: MLXAudioModelID.qwen3ASR17BInt8.rawValue,
        downloadIfNeeded: true
      )
    )
    var response = SpeechWorkerResponse.progress(
      request: request,
      update: SpeechWorkerProgress(
        phase: .downloading,
        completedUnitCount: 25,
        totalUnitCount: 100
      )
    )
    let encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)

    XCTAssertEqual(
      try SpeechWorkerProtocolCodec.decodeResponseLine(encoded.dropLast()),
      response
    )
    XCTAssertEqual(response.progress?.fractionCompleted, 0.25)

    response.progress?.completedUnitCount = 101
    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeResponseLine(response)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .invalidResponse)
    }
  }

  private func makeRequest() -> SpeechWorkerRequest {
    SpeechWorkerRequest(
      requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      generation: 1,
      payload: SpeechWorkerRecognitionPayload(
        runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        modelID: SherpaOnnxModelCatalog.defaultModelID.rawValue,
        language: "zh-CN",
        keyterms: ["Rill"],
        threadCount: 2,
        audioFilePath: "/tmp/rill-recognition-test.wav",
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
