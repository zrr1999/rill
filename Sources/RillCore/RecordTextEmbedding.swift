import Foundation

public struct RecordTextEmbedding: Codable, Sendable, Equatable {
  public let vectors: [[Float]]
  public let coverageLimited: Bool

  public init(vectors: [[Float]], coverageLimited: Bool) {
    self.vectors = vectors
    self.coverageLimited = coverageLimited
  }
}

public enum RecordEmbeddingPurpose: String, Codable, Sendable {
  case query
  case document
}

public enum RecordEmbeddingError: Error, Sendable {
  case invalidInput
  case invalidOutput
  case modelUnavailable
  case unavailable
}

public protocol RecordEmbeddingProvider: Sendable {
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws -> RecordTextEmbedding
  func shutdown() async
}
