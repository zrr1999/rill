import Foundation
import VoxTypeCore

public struct SnippetReplacementTransformer: TextTransformer {
    public let id = "transformer.snippet"
    public let supportedKinds: [PostProcessStepKind] = [.snippetReplacement]

    public init() {}

    public func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        text
            .replacingOccurrences(of: "my email", with: "founder@example.com")
            .replacingOccurrences(of: "our repo", with: "VoxType")
    }
}

public struct DemoLLMTransformer: TextTransformer {
    public let id = "transformer.demo-llm"
    public let supportedKinds: [PostProcessStepKind] = [.llmRewrite]

    public init() {}

    public func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        let prompt = step.prompt ?? ""
        if prompt.isEmpty {
            return text
        }
        return "[LLM rewrite] \(text.capitalized)"
    }
}

public struct WhitespaceNormalizerTransformer: TextTransformer {
    public let id = "transformer.normalize"
    public let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace]

    public init() {}

    public func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
