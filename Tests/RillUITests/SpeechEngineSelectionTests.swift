import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class SpeechEngineSelectionTests: XCTestCase {

  func testSelectingExactLocalEngineUpdatesRouteAndModelTogether() async {
    let compact = localModel(
      id: "qwen3-asr-0.6b-mlx-8bit",
      engine: .mlxAudioSwift,
      name: "Qwen3-ASR · 0.6B · INT8"
    )
    let mlx = localModel(
      id: "qwen3-asr-1.7b-mlx-8bit",
      engine: .mlxAudioSwift,
      name: "Qwen3-ASR · 1.7B · INT8"
    )
    let harness = makeHarness(
      trustedLocalSpeechModels: [compact, mlx],
      defaultLocalSpeechModelIdentifier: compact.id
    )
    XCTAssertTrue(harness.model.setPreferredLocalSpeechModel(mlx.id))

    XCTAssertEqual(harness.model.settings.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.settings.localSpeechModel, mlx.id)
  }

  func testSelectingUnknownLocalEngineLeavesCurrentSelectionUnchanged() {
    let compact = localModel(
      id: "qwen3-asr-0.6b-mlx-8bit",
      engine: .mlxAudioSwift,
      name: "Qwen3-ASR · 0.6B · INT8"
    )
    let harness = makeHarness(
      trustedLocalSpeechModels: [compact],
      defaultLocalSpeechModelIdentifier: compact.id
    )
    XCTAssertFalse(harness.model.setPreferredLocalSpeechModel("unknown-model"))

    XCTAssertEqual(harness.model.settings.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.settings.localSpeechModel, compact.id)
  }

  private func localModel(
    id: String,
    engine: LocalSpeechEngine,
    name: String
  ) -> LocalSpeechModelDescriptor {
    LocalSpeechModelDescriptor(
      id: id,
      engine: engine,
      englishName: name,
      simplifiedChineseName: name
    )
  }
}
