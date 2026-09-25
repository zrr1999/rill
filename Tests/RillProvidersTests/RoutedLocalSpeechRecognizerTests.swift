@testable import RillSpeechContracts
@testable import RillSpeech
import XCTest

@testable import RillCore
@testable import RillProviders

final class RoutedLocalSpeechRecognizerTests: XCTestCase {
  func testChangingSelectionDoesNotReselectTheFrozenRequestModel() async throws {
    let selection = LocalSpeechSelection(
      modelID: MLXAudioModelID.qwen3ASR06BInt8.rawValue
    )
    let mlx = RecordingLocalSpeechBackend(
      backend: .mlxAudioSwift,
      resultText: "mlx"
    )
    let router = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        LocalSpeechSettings(model: await selection.modelID(), enabledModelIDs: Set(MLXAudioModelID.allCases.map(\.rawValue)))
      },
      backends: [mlx]
    )

    let first = try await router.recognize(makeRequest())
    await selection.setModelID(MLXAudioModelID.qwen3ASR17BInt8.rawValue)
    let second = try await router.recognize(makeRequest())

    XCTAssertEqual(first.bestText, "mlx")
    XCTAssertEqual(second.bestText, "mlx")
    let mlxSnapshot = await mlx.snapshot()
    XCTAssertEqual(mlxSnapshot.modelIDs, Array(repeating: MLXAudioModelID.qwen3ASR06BInt8.rawValue, count: 2))
    XCTAssertEqual(mlxSnapshot.recognitions, 2)
    XCTAssertEqual(mlxSnapshot.releases, 0)
  }

  func testRouterReportsARegisteredCatalogBackendThatHasNoImplementation() async {
    let router = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        LocalSpeechSettings(model: MLXAudioModelID.qwen3ASR17BInt8.rawValue, enabledModelIDs: Set(MLXAudioModelID.allCases.map(\.rawValue)))
      },
      backends: []
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
    let mlx = RecordingLocalSpeechBackend(
      backend: .mlxAudioSwift,
      resultText: "mlx"
    )
    let router = RoutedLocalSpeechRecognizer(
      settingsProvider: {
        LocalSpeechSettings(model: MLXAudioModelID.qwen3ASR06BInt8.rawValue)
      },
      backends: [mlx]
    )

    try await router.releaseLoadedModel()
    try await router.stopRuntime()

    let mlxSnapshot = await mlx.snapshot()
    XCTAssertEqual(mlxSnapshot.releases, 1)
    XCTAssertEqual(mlxSnapshot.stops, 1)
  }

  private func makeRequest() -> RecognitionRequest {
    RecognitionRequest(
      runID: UUID(),
      contextSnapshot: .empty,
      options: .init(modelID: MLXAudioModelID.qwen3ASR06BInt8.rawValue)
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
    let modelIDs: [String?]
    let recognitions: Int
    let releases: Int
    let stops: Int
  }

  nonisolated let id: String
  nonisolated let backend: LocalSpeechModelBackend
  nonisolated let capabilities = SpeechRecognizerCapabilities.none

  private let resultText: String
  private var modelIDs: [String?] = []
  private var recognitionCount = 0
  private var releaseCount = 0
  private var stopCount = 0

  init(backend: LocalSpeechModelBackend, resultText: String) {
    self.id = "test.\(backend.rawValue)"
    self.backend = backend
    self.resultText = resultText
  }

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    modelIDs.append(request.options.modelID)
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
      modelIDs: modelIDs,
      recognitions: recognitionCount,
      releases: releaseCount,
      stops: stopCount
    )
  }
}
