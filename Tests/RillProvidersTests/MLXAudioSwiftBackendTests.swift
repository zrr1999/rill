import Foundation
import XCTest

@testable import RillCore
@testable import RillProviders

final class MLXAudioSwiftBackendTests: XCTestCase {
  func testCatalogRoutesOnlyExactPinnedMLXModelIdentity() throws {
    let modelID = MLXAudioModelID.qwen3ASR06BInt8.rawValue

    XCTAssertEqual(try LocalSpeechModelCatalog.backend(for: modelID), .mlxAudioSwift)
    XCTAssertThrowsError(
      try LocalSpeechModelCatalog.backend(
        for: "sherpa-onnx-qwen3-asr-0.6b-int8-2026-03-25"
      )
    )
    XCTAssertThrowsError(try LocalSpeechModelCatalog.backend(for: "unreviewed-model")) {
      XCTAssertEqual(
        $0 as? LocalSpeechModelSelectionError,
        .unsupportedModelIdentifier("unreviewed-model")
      )
    }

    let compactDescriptor = MLXAudioModelCatalog.descriptor(for: .qwen3ASR06BInt8)
    XCTAssertEqual(compactDescriptor.repository, "mlx-community/Qwen3-ASR-0.6B-8bit")
    XCTAssertEqual(compactDescriptor.revision, "89e96d92ba34aca20b3e29fb10cc284097d1219f")
    XCTAssertEqual(compactDescriptor.approximateDownloadByteCount, 1_010_771_234)
    XCTAssertEqual(compactDescriptor.files.count, 9)
    XCTAssertEqual(
      compactDescriptor.files.reduce(UInt64(0)) { $0 + $1.byteCount },
      compactDescriptor.approximateDownloadByteCount
    )
    XCTAssertTrue(
      compactDescriptor.files.allSatisfy {
        $0.byteCount > 0 && $0.sha256.count == 64
      }
    )

    let largerDescriptor = MLXAudioModelCatalog.descriptor(for: .qwen3ASR17BInt8)
    XCTAssertEqual(largerDescriptor.repository, "mlx-community/Qwen3-ASR-1.7B-8bit")
    XCTAssertEqual(largerDescriptor.revision.count, 40)
    XCTAssertGreaterThan(largerDescriptor.approximateDownloadByteCount, 2_000_000_000)
    XCTAssertEqual(
      MLXAudioModelCatalog.distributable.map(\.id),
      [.qwen3ASR06BInt8, .qwen3ASR17BInt8]
    )
  }

  func testWorkflowOverrideSelectsExactMLXModel() {
    let workflow = WorkflowDefinition(
      name: "MLX override",
      pipeline: PipelineDeclaration(recognizerID: "local-speech", outputActions: []),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "accent"),
      metadata: [
        WorkflowMetadataKey.localSpeechModelOverride:
          MLXAudioModelID.qwen3ASR17BInt8.rawValue
      ]
    )

    XCTAssertEqual(
      LocalSpeechModelCatalog.effectiveModelIdentifier(
        settings: LocalSpeechSettings(
          model: "sherpa-onnx-qwen3-asr-0.6b-int8-2026-03-25"
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
