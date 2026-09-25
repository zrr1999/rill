import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class SpeechEngineSelectionTests: XCTestCase {
  func testEngineLabelsIdentifyExactLocalBackends() {
    let retired = localModel(
      id: "retired-local-model",
      engine: .sherpaOnnx,
      name: "Qwen3-ASR · 0.6B · INT8"
    )
    let mlx = localModel(
      id: "qwen3-asr-1.7b-mlx-8bit",
      engine: .mlxAudioSwift,
      name: "Qwen3-ASR · 1.7B · INT8"
    )

    XCTAssertEqual(
      L10n.localSpeechEngine(retired.engine, language: .simplifiedChinese),
      "旧版本地"
    )
    XCTAssertEqual(
      L10n.localSpeechEngine(mlx.engine, language: .english),
      "MLX Local"
    )
    XCTAssertEqual(retired.simplifiedChineseName, "Qwen3-ASR · 0.6B · INT8")
    XCTAssertEqual(mlx.englishName, "Qwen3-ASR · 1.7B · INT8")
  }

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

    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.localSpeechModel, mlx.id)
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

    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.localSpeechModel, compact.id)
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
