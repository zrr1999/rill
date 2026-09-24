@testable import RillSpeechContracts
@testable import RillSpeech
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

  func testUnaryOperationsUseTheUnifiedV5FrameWithoutNullablePayloadFields() throws {
    let request = makeRequest()
    let encodedRequest = try SpeechWorkerProtocolCodec.encodeRequestLine(request)
    let requestObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedRequest.dropLast()) as? [String: Any]
    )

    XCTAssertEqual(requestObject["protocolVersion"] as? Int, 5)
    XCTAssertEqual(requestObject["kind"] as? String, SpeechWorkerFrameKind.command.rawValue)
    XCTAssertEqual(requestObject["sequence"] as? Int, 0)
    XCTAssertNotNil(requestObject["sessionID"])
    XCTAssertNotNil(requestObject["body"])
    XCTAssertNil(requestObject["operation"])
    XCTAssertNil(requestObject["recognitionPayload"])
    XCTAssertNil(requestObject["modelPreparationPayload"])
    XCTAssertNil(requestObject["synthesisPayload"])

    let response = SpeechWorkerResponse.success(
      request: request,
      result: SpeechWorkerRecognitionResult(
        rawText: "Rill",
        bestText: "Rill",
        metadata: [:],
        processingDurationMillis: 1
      )
    )
    let encodedResponse = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    let responseObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedResponse.dropLast()) as? [String: Any]
    )

    XCTAssertEqual(responseObject["kind"] as? String, SpeechWorkerFrameKind.event.rawValue)
    XCTAssertNotNil(responseObject["body"])
    XCTAssertNil(responseObject["result"])
    XCTAssertNil(responseObject["progress"])
    XCTAssertNil(responseObject["failure"])
  }

  func testUnaryV4FrameIsRejectedWithoutCompatibilityNegotiation() throws {
    let encoded = try SpeechWorkerProtocolCodec.encodeRequestLine(makeRequest())
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded.dropLast()) as? [String: Any]
    )
    object["protocolVersion"] = 4
    let legacy = try JSONSerialization.data(withJSONObject: object)

    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.decodeRequestLine(legacy)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .unsupportedVersion)
    }
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
    sherpaRequest.recognitionPayload?.modelID =
      "sherpa-onnx-qwen3-asr-0.6b-int8-2026-03-25"
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

  func testV5StreamingStartAndEveryEventKindRoundTrip() throws {
    let requestID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let sessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let start = SpeechWorkerFrame(
      requestID: requestID,
      generation: 4,
      sessionID: sessionID,
      sequence: 0,
      body: .command(
        .start(
          SpeechWorkerStreamStart(
            modelID: MLXAudioModelID.qwen3ASR06BInt8.rawValue,
            language: "zh-CN",
            keyterms: ["Rill"],
            mode: .vadAndTranscription,
            profile: .realtime,
            priority: .interactive
          )
        )
      )
    )
    let commandLine = try SpeechWorkerFrameCodec.encodeCommandLine(start)
    XCTAssertEqual(
      try SpeechWorkerFrameCodec.decodeCommandLine(commandLine.dropLast()),
      start
    )

    let events: [SpeechWorkerStreamEvent] = [
      .accepted(queuePosition: 0),
      .started(modelID: MLXAudioModelID.qwen3ASR06BInt8.rawValue),
      .vadActivity(.init(probability: 0.75, isSpeech: true, sampleOffset: 512)),
      .speechStarted(sampleOffset: 512),
      .speechEnded(sampleOffset: 1_024),
      .transcriptUpdate(.init(confirmed: "你好", provisional: " Rill")),
      .stats(
        .init(
          encodedWindowCount: 2,
          totalAudioSeconds: 0.2,
          tokensPerSecond: 20,
          realTimeFactor: 0.4,
          peakMemoryBytes: 1_024
        )
      ),
      .completed(previewText: "你好 Rill"),
      .failure(.streamingFailed),
    ]
    for (index, event) in events.enumerated() {
      let frame = SpeechWorkerFrame(
        requestID: requestID,
        generation: 4,
        sessionID: sessionID,
        sequence: UInt64(index),
        body: .event(event)
      )
      let line = try SpeechWorkerFrameCodec.encodeEventLine(frame)
      XCTAssertEqual(
        try SpeechWorkerFrameCodec.decodeEventLine(line.dropLast()),
        frame
      )
    }
  }

  func testV5AudioFramesAcceptOneHundredAndTwoHundredMillisecondsOnlyWithinBound() throws {
    for sampleCount in [
      SpeechWorkerStreamingProtocol.preferredSamplesPerFrame,
      SpeechWorkerStreamingProtocol.maximumSamplesPerFrame,
    ] {
      let chunk = SpeechWorkerAudioChunk(
        samples: (0..<sampleCount).map { Float($0) / Float(sampleCount) }
      )
      XCTAssertEqual(try chunk.decodedSamples().count, sampleCount)
      XCTAssertNoThrow(
        try SpeechWorkerFrameCodec.encodeCommandLine(
          streamingCommand(.appendAudio(chunk), sequence: 1)
        )
      )
    }

    XCTAssertThrowsError(
      try SpeechWorkerFrameCodec.encodeCommandLine(
        streamingCommand(
          .appendAudio(
            SpeechWorkerAudioChunk(
              samples: Array(
                repeating: 0,
                count: SpeechWorkerStreamingProtocol.maximumSamplesPerFrame + 1
              )
            )
          ),
          sequence: 1
        )
      )
    ) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .invalidFrame)
    }
  }

  func testV5RejectsNonFinitePCMWrongDirectionAndOversizedTranscript() {
    XCTAssertThrowsError(
      try SpeechWorkerFrameCodec.encodeCommandLine(
        streamingCommand(
          .appendAudio(SpeechWorkerAudioChunk(samples: [.nan])),
          sequence: 1
        )
      )
    )
    XCTAssertThrowsError(
      try SpeechWorkerFrameCodec.encodeEventLine(
        streamingCommand(.finish, sequence: 1)
      )
    )
    let oversized = String(
      repeating: "x",
      count: SpeechWorkerStreamingProtocol.maximumTranscriptByteCount + 1
    )
    XCTAssertThrowsError(
      try SpeechWorkerFrameCodec.encodeEventLine(
        streamingEvent(.completed(previewText: oversized))
      )
    ) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .frameTooLarge)
    }
  }

  func testV5RejectsLegacyVersionAndInvalidStartFormat() {
    var frame = streamingCommand(
      .start(
        SpeechWorkerStreamStart(
          modelID: MLXAudioModelID.qwen3ASR06BInt8.rawValue,
          language: nil,
          keyterms: [],
          mode: .vadOnly,
          profile: .agent,
          priority: .voiceActivity,
          audioFormat: AudioFormat(
            sampleRateHz: 48_000,
            channelCount: 1,
            encoding: .float32
          )
        )
      ),
      sequence: 0
    )
    XCTAssertThrowsError(try SpeechWorkerFrameCodec.encodeCommandLine(frame))
    frame.protocolVersion = 4
    XCTAssertThrowsError(try SpeechWorkerFrameCodec.encodeCommandLine(frame)) { error in
      XCTAssertEqual(error as? SpeechWorkerProtocolError, .unsupportedVersion)
    }
  }

  func testV5CancelRequestControlIsStronglyBoundToTargetRequest() throws {
    let targetRequestID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    let control = SpeechWorkerFrame(
      requestID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
      generation: 6,
      sessionID: targetRequestID,
      sequence: 0,
      body: .command(.cancelRequest(targetRequestID))
    )

    let line = try SpeechWorkerFrameCodec.encodeCommandLine(control)
    XCTAssertEqual(try SpeechWorkerFrameCodec.decodeCommandLine(line.dropLast()), control)

    var wrongSession = control
    wrongSession.sessionID = UUID()
    XCTAssertThrowsError(try SpeechWorkerFrameCodec.encodeCommandLine(wrongSession))
    var wrongSequence = control
    wrongSequence.sequence = 1
    XCTAssertThrowsError(try SpeechWorkerFrameCodec.encodeCommandLine(wrongSequence))
  }

  private func makeRequest() -> SpeechWorkerRequest {
    SpeechWorkerRequest(
      requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      generation: 1,
      payload: SpeechWorkerRecognitionPayload(
        runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        modelID: MLXAudioModelID.qwen3ASR06BInt8.rawValue,
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

  private func streamingCommand(
    _ command: SpeechWorkerStreamCommand,
    sequence: UInt64
  ) -> SpeechWorkerFrame {
    SpeechWorkerFrame(
      requestID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
      generation: 5,
      sessionID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
      sequence: sequence,
      body: .command(command)
    )
  }

  private func streamingEvent(_ event: SpeechWorkerStreamEvent) -> SpeechWorkerFrame {
    SpeechWorkerFrame(
      requestID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
      generation: 5,
      sessionID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
      sequence: 0,
      body: .event(event)
    )
  }
}
