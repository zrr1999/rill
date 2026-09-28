import Foundation
import RillCore
import Testing
@testable import RillProviders

/// Opt-in provider evaluation using fixed synthetic text, without screen or history access.
struct TextRewriteEvaluationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Sample: Decodable {
        let id: String
        let transcript: String
        let expected: String
    }

    private struct Observation: Encodable {
        let sampleID: String
        let contextual: Bool
        let repetition: Int
        let output: String?
        let matchesExpectedContent: Bool
        let elapsedMilliseconds: Double
        let failed: Bool
    }

    private struct Report: Encodable {
        let model: String
        let startedAt: Date
        let observations: [Observation]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_REWRITE_LIVE_EVALUATION"] == "1"))
    func cleanupPreservesUtterancesInsteadOfAnsweringThem() async throws {
        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(environment["OPENAI_API_KEY"])
        let baseURL = try #require(environment["OPENAI_BASE_URL"])
        let model = try #require(environment["OPENAI_MODEL"])
        let settings = OpenAISettings(apiKey: apiKey, baseURL: baseURL, model: model)
        let transformer = OpenAITextRewriteTransformer(settingsProvider: { settings })
        let startedAt = Date()
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf:
            Self.root.appendingPathComponent("Tests/Fixtures/TextRewrite/cases.json")))
        try #require(!samples.isEmpty)
        let workflow = WorkflowDefinition(name: "Cleanup evaluation",
            pipeline: PipelineDeclaration(recognizerID: "fixture", outputActions: []),
            ui: .init(symbolName: "waveform", accentColorName: "blue"))
        let step = PostProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt)
        var observations: [Observation] = []
        let report = Self.root.appendingPathComponent(".artifacts/text-rewrite/live-evaluation.json")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)

        for repetition in 1...3 {
            for sample in samples {
                for contextual in [false, true] {
                    var context = TransformContext(runID: UUID(), workflow: workflow, contextSnapshot: .empty,
                        recognitionResult: .init(rawText: sample.transcript, bestText: sample.transcript))
                    if contextual {
                        context.correctionRequest = .init(transcript: sample.transcript,
                            imageSummary: .init(terms: ["Rill"], observations: []),
                            authorization: .init(providerFingerprint: ContextProviderIdentity.fingerprint(settings)))
                    }
                    let start = ContinuousClock.now
                    var output: String?
                    do {
                        output = try await transformer.transform(text: sample.transcript, step: step, context: context)
                    } catch is CancellationError {
                        await transformer.shutdown()
                        throw CancellationError()
                    } catch {
                        // A provider failure must not pass by substituting the expected transcript.
                        output = nil
                    }
                    let elapsed = start.duration(to: .now).components
                    let matched = output.map { normalized($0) == normalized(sample.expected) } ?? false
                    observations.append(.init(sampleID: sample.id, contextual: contextual, repetition: repetition,
                        output: output, matchesExpectedContent: matched,
                        elapsedMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                        failed: output == nil))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(Report(model: model, startedAt: startedAt, observations: observations))
                        .write(to: report, options: .atomic)
                    #expect(matched, "Cleanup changed the content or failed: \(sample.id), contextual=\(contextual), repetition=\(repetition)")
                }
            }
        }
        await transformer.shutdown()
    }

    private func normalized(_ text: String) -> String {
        text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
        }.map(String.init).joined()
    }
}
