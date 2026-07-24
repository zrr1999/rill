import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class MLXAudioSwiftBackendTests: XCTestCase {
  func testCatalogRoutesOnlyExactPinnedMLXModelIdentity() throws {
    let modelID = MLXAudioModelID.qwen3ASR17BInt8.rawValue

    XCTAssertEqual(try LocalSpeechModelCatalog.backend(for: modelID), .mlxAudioSwift)
    XCTAssertEqual(
      try LocalSpeechModelCatalog.backend(
        for: SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
      ),
      .sherpaOnnx
    )
    XCTAssertThrowsError(try LocalSpeechModelCatalog.backend(for: "unreviewed-model")) {
      XCTAssertEqual(
        $0 as? LocalSpeechModelSelectionError,
        .unsupportedModelIdentifier("unreviewed-model")
      )
    }

    let descriptor = MLXAudioModelCatalog.descriptor(for: .qwen3ASR17BInt8)
    XCTAssertEqual(descriptor.repository, "mlx-community/Qwen3-ASR-1.7B-8bit")
    XCTAssertEqual(descriptor.revision.count, 40)
    XCTAssertGreaterThan(descriptor.approximateDownloadByteCount, 2_000_000_000)
  }

  func testWorkflowOverrideSelectsExactMLXModel() {
    let workflow = WorkflowDefinition(
      name: "MLX override",
      pipeline: PipelineDeclaration(recognizerID: "sherpa-onnx.local", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "accent"),
      metadata: [
        WorkflowMetadataKey.localSpeechModelOverride:
          MLXAudioModelID.qwen3ASR17BInt8.rawValue
      ]
    )

    XCTAssertEqual(
      LocalSpeechModelCatalog.effectiveModelIdentifier(
        settings: LocalSpeechSettings(
          model: SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
        ),
        workflow: workflow
      ),
      MLXAudioModelID.qwen3ASR17BInt8.rawValue
    )
  }

  func testNativeSwiftBackendAdvertisesQwenContextKeyterms() {
    let supervisor = SpeechWorkerSupervisor(
      configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
    )
    let recognizer = MLXAudioSwiftWorkerRecognizer(
      supervisor: supervisor,
      settingsProvider: {
        LocalSpeechSettings(model: MLXAudioModelID.qwen3ASR17BInt8.rawValue)
      }
    )

    XCTAssertEqual(recognizer.backend, .mlxAudioSwift)
    XCTAssertTrue(recognizer.capabilities.supports(.keyterm))
  }
}
