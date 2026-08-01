import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class SpeechEngineSelectionTests: XCTestCase {
  func testEngineLabelsIdentifyExactLocalBackends() {
    let sherpa = localModel(
      id: "qwen3-asr-0.6b-int8",
      engine: .sherpaOnnx,
      name: "Qwen3-ASR · 0.6B · INT8"
    )
    let mlx = localModel(
      id: "qwen3-asr-1.7b-mlx-8bit",
      engine: .mlxAudioSwift,
      name: "Qwen3-ASR · 1.7B · INT8"
    )

    XCTAssertEqual(
      UIStrings.localSpeechEngine(sherpa.engine, language: .simplifiedChinese),
      "sherpa-onnx 本地"
    )
    XCTAssertEqual(
      UIStrings.localSpeechEngine(mlx.engine, language: .english),
      "MLX Local"
    )
    XCTAssertEqual(sherpa.simplifiedChineseName, "Qwen3-ASR · 0.6B · INT8")
    XCTAssertEqual(mlx.englishName, "Qwen3-ASR · 1.7B · INT8")
  }

  func testSelectingExactLocalEngineUpdatesRouteAndModelTogether() async {
    let sherpa = localModel(
      id: "qwen3-asr-0.6b-int8",
      engine: .sherpaOnnx,
      name: "Qwen3-ASR · 0.6B · INT8"
    )
    let mlx = localModel(
      id: "qwen3-asr-1.7b-mlx-8bit",
      engine: .mlxAudioSwift,
      name: "Qwen3-ASR · 1.7B · INT8"
    )
    let harness = makeHarness(
      trustedLocalSpeechModels: [sherpa, mlx],
      defaultLocalSpeechModelIdentifier: sherpa.id
    )
    XCTAssertTrue(harness.model.setPreferredLocalSpeechModel(mlx.id))

    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.localSpeechModel, mlx.id)
  }

  func testSelectingUnknownLocalEngineLeavesCurrentSelectionUnchanged() {
    let sherpa = localModel(
      id: "qwen3-asr-0.6b-int8",
      engine: .sherpaOnnx,
      name: "Qwen3-ASR · 0.6B · INT8"
    )
    let harness = makeHarness(
      trustedLocalSpeechModels: [sherpa],
      defaultLocalSpeechModelIdentifier: sherpa.id
    )
    XCTAssertFalse(harness.model.setPreferredLocalSpeechModel("unknown-model"))

    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(harness.model.localSpeechModel, sherpa.id)
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
