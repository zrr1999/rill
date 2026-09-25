import Foundation
import Testing
@testable import RillCore

struct DiagnosticEventNameTests {
  @Test func typedCoordinatesRoundTripThroughExistingStorageSchema() throws {
    for name in DiagnosticEventName.allCases {
      let event = DiagnosticEvent(subsystem: .session, level: .warning, event: name, message: "detail")
      let encoded = try JSONEncoder().encode(event)
      let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      #expect(object["event"] as? String == name.rawValue)
      #expect(object["name"] == nil)
      #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: encoded) == event)
      #expect(DiagnosticEventSanitizer.sanitize(event).name == name)
    }
  }

  @Test func unknownLegacyCoordinateFailsClosedWithoutDroppingTheRow() throws {
    let event = DiagnosticEvent(subsystem: .session, level: .warning,
      event: .sessionFailure, message: "private detail", metadata: ["text": "private transcript"])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    object["event"] = "unregistered.private-content"
    let imported = try JSONDecoder().decode(DiagnosticEvent.self,
      from: JSONSerialization.data(withJSONObject: object))
    let sanitized = DiagnosticEventSanitizer.sanitize(imported)
    #expect(sanitized.name == .diagnosticEventInvalid)
    #expect(sanitized.timestamp == event.timestamp)
    #expect(sanitized.metadata.isEmpty)
    #expect(sanitized.message == DiagnosticEventSanitizer.sanitizedMessage)
  }

  @Test(arguments: ["qwen3-asr-0.6b-mlx-8bit", "qwen3-asr-1.7b-mlx-8bit",
    "qwen3-tts-0.6b-customvoice-mlx-4bit", "qwen3-tts-0.6b-customvoice-mlx-8bit",
    "qwen3-tts-0.6b-customvoice-mlx-bf16"])
  func modelFailureMetadataRetainsOnlyRegisteredIdentity(modelID: String) {
    let event = DiagnosticEvent(subsystem: .providers, level: .error,
      event: .providerSpeechModelDownloadFailed, message: "private path",
      metadata: ["modelID": modelID, "workerIsolation": "subprocess", "error": "private path"])
    #expect(DiagnosticEventSanitizer.sanitize(event).metadata == [
      "modelID": modelID, "workerIsolation": "subprocess"])
    var privateModel = event
    privateModel.metadata["modelID"] = "private-model-path"
    #expect(DiagnosticEventSanitizer.sanitize(privateModel).metadata["modelID"] == nil)
  }
}
