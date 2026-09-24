import Foundation

/// A decision before rewriting; a skipped rewrite must not produce an LLM trace.
public protocol TextPolishingGate: Sendable {
  func shouldSkip(text: String, step: PostProcessStep, context: TransformContext) async throws -> Bool
}
