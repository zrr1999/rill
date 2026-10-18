import Foundation
import XCTest

@testable import RillCore

final class WakeWordAndSpeechSynthesisModelTests: XCTestCase {
  func testWakeWordConfigurationNormalizesAndRejectsDuplicates() throws {
    let configuration = WakeWordConfiguration(
      phrases: ["  Hey   Rill  ", "你好 Rill"]
    )
    XCTAssertEqual(
      try configuration.validatedPhrases(),
      ["Hey Rill", "你好 Rill"]
    )

    XCTAssertThrowsError(
      try WakeWordConfiguration(
        phrases: ["Hey Rill", "hey rill"]
      ).validatedPhrases()
    ) { error in
      XCTAssertEqual(
        error as? WakeWordConfiguration.ValidationError,
        .duplicatePhrase
      )
    }
  }

  func testWorkflowSetupRoundTripsWithoutWakeWord() throws {
    let original = WorkflowSetupPhase(speechRoute: .init(recognizerID: "local-speech"))
    let setup = try JSONDecoder().decode(WorkflowSetupPhase.self, from: JSONEncoder().encode(original))
    XCTAssertNil(setup.wakeWord)
    XCTAssertEqual(setup, original)
  }

  func testSpeechRequestDefaultsToAutomaticVivianAndIsBounded() {
    let request = SpeechSynthesisRequest(runID: UUID(), text: "你好")
    XCTAssertEqual(request.provider, .automatic)
    XCTAssertEqual(request.voice, Qwen3TTSVoice.vivian.rawValue)
    XCTAssertTrue(request.isValid)

    XCTAssertFalse(
      SpeechSynthesisRequest(
        runID: UUID(),
        text: String(
          repeating: "x",
          count: SpeechSynthesisRequest.maximumTextScalarCount + 1
        )
      ).isValid
    )
  }
}
