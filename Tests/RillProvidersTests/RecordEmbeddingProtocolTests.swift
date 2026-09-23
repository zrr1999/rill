import XCTest

@testable import RillCore
@testable import RillSpeechContracts

final class RecordEmbeddingProtocolTests: XCTestCase {
  func testEmbeddingFramesRoundTripAndRejectUntrustedModelOrMalformedVector() throws {
    let request = SpeechWorkerRequest(
      requestID: UUID(), generation: 1,
      payload: .embedText(
        .init(modelID: RecordEmbeddingModelCatalog.modelID, text: "中文\nquery", purpose: .query)))
    let line = try SpeechWorkerProtocolCodec.encodeRequestLine(request)
    XCTAssertEqual(try SpeechWorkerProtocolCodec.decodeRequestLine(line.dropLast()), request)
    let response = SpeechWorkerResponse(
      requestID: request.requestID, generation: 1,
      payload: .embeddingCompleted(
        .init(vectors: [[Float](repeating: 0, count: 1_024)], coverageLimited: true)))
    let encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    XCTAssertEqual(try SpeechWorkerProtocolCodec.decodeResponseLine(encoded.dropLast()), response)
    let wrongModel = SpeechWorkerRequest(
      requestID: UUID(), generation: 1,
      payload: .embedText(.init(modelID: "untrusted/model", text: "text", purpose: .document)))
    XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeRequestLine(wrongModel))
    for vectors: [[Float]] in [[], [[1, 2]], [[Float](repeating: .nan, count: 1_024)]] {
      let invalid = SpeechWorkerResponse(
        requestID: request.requestID, generation: 1,
        payload: .embeddingCompleted(.init(vectors: vectors, coverageLimited: false)))
      XCTAssertThrowsError(try SpeechWorkerProtocolCodec.encodeResponseLine(invalid))
    }
  }
}
