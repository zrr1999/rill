import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import RillCore
import Tokenizers

/// Worker-owned model. No download or network access occurs in this engine.
public actor Qwen3RecordEmbedder {
  private let directory: URL
  private var container: EmbedderModelContainer?

  public init(directory: URL) { self.directory = directory }

  public func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws
    -> RecordTextEmbedding
  {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 48 * 1_024
    else { throw RecordEmbeddingError.invalidInput }
    try Task.checkCancellation()
    if container == nil {
      container = try await EmbedderModelFactory.shared.loadContainer(
        from: directory, using: #huggingFaceTokenizerLoader())
    }
    guard let container else { throw RecordEmbeddingError.invalidOutput }
    return try await container.perform { context in
      try Task.checkCancellation()
      let input =
        purpose == .query
        ? "Instruct: Retrieve clipboard entries matching the user's intent and exact identifiers.\nQuery:"
          + text
        : text
      let tokens = context.tokenizer.encode(text: input, addSpecialTokens: true)
      guard !tokens.isEmpty else { throw RecordEmbeddingError.invalidInput }
      let coverageLimited: Bool
      let windows: [[Int]]
      if purpose == .query {
        guard tokens.count <= 256 else { throw RecordEmbeddingError.invalidInput }
        coverageLimited = false
        windows = [tokens]
      } else {
        var starts = Array(stride(from: 0, to: tokens.count, by: 192))
        coverageLimited = starts.count > 16
        if coverageLimited { starts = Array(starts.prefix(15)) + [starts[starts.count - 1]] }
        windows = starts.map { Array(tokens[$0..<min($0 + 248, tokens.count)]) }
      }
      var vectors: [[Float]] = []
      for offset in stride(from: 0, to: windows.count, by: 4) {
        try Task.checkCancellation()
        let batch = Array(windows[offset..<min(offset + 4, windows.count)])
        let width = (batch.map(\.count).max() ?? 1) + 1
        let padding = context.tokenizer.eosTokenId ?? 0
        let ids = stacked(
          batch.map { MLXArray($0 + Array(repeating: padding, count: width - $0.count)) })
        let masks = stacked(
          batch.map {
            MLXArray(
              Array(repeating: Int32(1), count: $0.count)
                + Array(repeating: Int32(0), count: width - $0.count))
          })
        let output = context.model(ids, positionIds: nil, tokenTypeIds: nil, attentionMask: masks)
        // Qwen retrieval uses the last non-padding token and normalized vectors.
        let pooled = context.pooling(output, mask: masks, normalize: true, applyLayerNorm: false)
          .asType(.float32)
        pooled.eval()
        guard pooled.shape == [batch.count, 1_024] else { throw RecordEmbeddingError.invalidOutput }
        for row in 0..<batch.count {
          let vector = pooled[row].asArray(Float.self)
          guard vector.allSatisfy(\.isFinite) else { throw RecordEmbeddingError.invalidOutput }
          vectors.append(vector)
        }
      }
      try Task.checkCancellation()
      return RecordTextEmbedding(vectors: vectors, coverageLimited: coverageLimited)
    }
  }

  public func release() {
    container = nil
    Memory.clearCache()
  }
}
