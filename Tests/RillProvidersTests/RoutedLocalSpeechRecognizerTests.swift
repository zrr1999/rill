import XCTest

@testable import RillCore
@testable import RillProviders

final class RoutedLocalSpeechRecognizerTests: XCTestCase {
  func testRouterSwitchesByCatalogBackendAndReleasesPreviousBackend() async throws {
    let selection = LocalSpeechSelection(
      modelID: SherpaOnnxModelCatalog.defaultModelID.rawValue
    )
    let sherpa = RecordingLocalSpeechBackend(
      backend: .sherpaOnnx,
      resultText: "sherpa"
    )
    let mlx = RecordingLocalSpeechBackend(
      backend: .mlxAudioSwift,
      resultText: "mlx"
    )
    let router = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        LocalSpeechSettings(model: await selection.modelID())
      },
      backends: [sherpa, mlx]
    )

    let first = try await router.recognize(makeRequest())
    await selection.setModelID(MLXAudioModelID.qwen3ASR17BInt8.rawValue)
    let second = try await router.recognize(makeRequest())

    XCTAssertEqual(first.bestText, "sherpa")
    XCTAssertEqual(second.bestText, "mlx")
    let sherpaSnapshot = await sherpa.snapshot()
    let mlxSnapshot = await mlx.snapshot()
    XCTAssertEqual(sherpaSnapshot.recognitions, 1)
    XCTAssertEqual(sherpaSnapshot.releases, 1)
    XCTAssertEqual(mlxSnapshot.recognitions, 1)
    XCTAssertEqual(mlxSnapshot.releases, 0)
  }

  func testRouterReportsARegisteredCatalogBackendThatHasNoImplementation() async {
    let sherpa = RecordingLocalSpeechBackend(
      backend: .sherpaOnnx,
      resultText: "sherpa"
    )
    let router = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        LocalSpeechSettings(model: MLXAudioModelID.qwen3ASR17BInt8.rawValue)
      },
      backends: [sherpa]
    )

    do {
      _ = try await router.recognize(makeRequest())
      XCTFail("Expected the missing backend to be rejected")
    } catch {
      XCTAssertEqual(
        error as? LocalSpeechModelSelectionError,
        .backendUnavailable(.mlxAudioSwift)
      )
    }
  }

  func testRouterLifecycleFansOutAcrossRegisteredBackends() async throws {
    let sherpa = RecordingLocalSpeechBackend(
      backend: .sherpaOnnx,
      resultText: "sherpa"
    )
    let mlx = RecordingLocalSpeechBackend(
      backend: .mlxAudioSwift,
      resultText: "mlx"
    )
    let router = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        LocalSpeechSettings(model: SherpaOnnxModelCatalog.defaultModelID.rawValue)
      },
      backends: [sherpa, mlx]
    )

    try await router.releaseLoadedModel()
    try await router.stopRuntime()

    let sherpaSnapshot = await sherpa.snapshot()
    let mlxSnapshot = await mlx.snapshot()
    XCTAssertEqual(sherpaSnapshot.releases, 1)
    XCTAssertEqual(mlxSnapshot.releases, 1)
    XCTAssertEqual(sherpaSnapshot.stops, 1)
    XCTAssertEqual(mlxSnapshot.stops, 1)
  }

  private func makeRequest() -> RecognitionRequest {
    RecognitionRequest(
      runID: UUID(),
      workflow: WorkflowDefinition(
        name: "Local speech",
        pipeline: PipelineDeclaration(
          recognizerID: "sherpa-onnx.local",
          outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "accent")
      ),
      contextSnapshot: .empty
    )
  }
}

private actor LocalSpeechSelection {
  private var currentModelID: String

  init(modelID: String) {
    self.currentModelID = modelID
  }

  func modelID() -> String {
    currentModelID
  }

  func setModelID(_ modelID: String) {
    currentModelID = modelID
  }
}

private actor RecordingLocalSpeechBackend: LocalSpeechBackendRecognizer {
  struct Snapshot {
    let recognitions: Int
    let releases: Int
    let stops: Int
  }

  nonisolated let id: String
  nonisolated let backend: LocalSpeechModelBackend
  nonisolated let capabilities = SpeechRecognizerCapabilities.none

  private let resultText: String
  private var recognitionCount = 0
  private var releaseCount = 0
  private var stopCount = 0

  init(backend: LocalSpeechModelBackend, resultText: String) {
    self.id = "test.\(backend.rawValue)"
    self.backend = backend
    self.resultText = resultText
  }

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    recognitionCount += 1
    return RecognitionResult(rawText: resultText, bestText: resultText)
  }

  func releaseLoadedModel() async throws {
    releaseCount += 1
  }

  func stopRuntime() async throws {
    stopCount += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(
      recognitions: recognitionCount,
      releases: releaseCount,
      stops: stopCount
    )
  }
}
