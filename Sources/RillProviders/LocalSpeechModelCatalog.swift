import Foundation
import RillCore

public enum LocalSpeechModelBackend: String, CaseIterable, Sendable, Equatable {
  case sherpaOnnx = "sherpa-onnx"
  case mlxAudioSwift = "mlx-audio-swift"
}

public enum LocalSpeechModelSelectionError: Error, LocalizedError, Sendable, Equatable {
  case unsupportedModelIdentifier(String)
  case backendUnavailable(LocalSpeechModelBackend)

  public var errorDescription: String? {
    switch self {
    case .unsupportedModelIdentifier(let identifier):
      "The local speech model is not supported: \(identifier)."
    case .backendUnavailable(let backend):
      "The local speech backend is unavailable: \(backend.rawValue)."
    }
  }
}

public enum MLXAudioModelID: String, CaseIterable, Codable, Sendable {
  case qwen3ASR17BInt8 = "qwen3-asr-1.7b-mlx-8bit"
}

public struct MLXAudioModelDescriptor: Equatable, Sendable {
  public let id: MLXAudioModelID
  public let repository: String
  public let revision: String
  public let approximateDownloadByteCount: UInt64
}

public enum MLXAudioModelCatalog {
  public static let qwen3ASR17BInt8 = MLXAudioModelDescriptor(
    id: .qwen3ASR17BInt8,
    repository: "mlx-community/Qwen3-ASR-1.7B-8bit",
    revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    approximateDownloadByteCount: 2_460_000_000
  )

  public static let distributable = [qwen3ASR17BInt8]

  public static let distributableModelIdentifiers = Set(
    distributable.map { $0.id.rawValue }
  )

  public static func descriptor(for id: MLXAudioModelID) -> MLXAudioModelDescriptor {
    switch id {
    case .qwen3ASR17BInt8:
      qwen3ASR17BInt8
    }
  }
}

public enum LocalSpeechModelCatalog {
  public static let defaultModelIdentifier = SherpaOnnxModelCatalog.defaultModelID.rawValue

  public static let distributableModelIdentifiers =
    SherpaOnnxModelCatalog.distributableModelIdentifiers
    .union(MLXAudioModelCatalog.distributableModelIdentifiers)

  public static func backend(
    for modelIdentifier: String
  ) throws -> LocalSpeechModelBackend {
    if SherpaOnnxModelCatalog.distributableModelIdentifiers.contains(modelIdentifier) {
      return .sherpaOnnx
    }
    if MLXAudioModelCatalog.distributableModelIdentifiers.contains(modelIdentifier) {
      return .mlxAudioSwift
    }
    throw LocalSpeechModelSelectionError.unsupportedModelIdentifier(modelIdentifier)
  }

  public static func effectiveModelIdentifier(
    settings: LocalSpeechSettings,
    workflow: WorkflowDefinition? = nil
  ) -> String {
    if let workflow,
      let override =
        (workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]
        ?? workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride])?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return override
    }
    let configured = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
    return configured.isEmpty ? defaultModelIdentifier : configured
  }
}
