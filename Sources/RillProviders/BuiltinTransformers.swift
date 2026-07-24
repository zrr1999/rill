import Foundation
import RillCore

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
