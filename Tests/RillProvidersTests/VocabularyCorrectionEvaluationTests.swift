import Foundation
import Testing
import RillCore
@testable import RillProviders

struct VocabularyCorrectionEvaluationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Sample: Decodable {
        let id: String
        let category: String
        let transcript: String
        let expected: String
        let terms: [String]
        let asrEvidence: ASREvidence?
    }

    /// The provider's final accepted terms, accompanied by its actual usage counters.
    private struct ASREvidence: Decodable {
        let terms: [String]
        let usedCount: Int
        let omittedCount: Int
        let provenance: String

        var isComplete: Bool {
            !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && usedCount == terms.count && omittedCount == 0
        }
    }

    private struct Observation: Encodable {
        let id: String
        let category: String
        let repetition: Int
        let mode: String
        let output: String
        let expected: String
        let exactMatch: Bool
        let elapsedMilliseconds: Double
        let fallback: Bool
        let attemptedRequest: Bool
        let tokenUsage: LanguageModelTokenUsage?
        let reference: VocabularyReferenceReceipt?
    }

    private struct Metrics: Encodable {
        let mode: String
        let requests: Int
        let exactMatches: Int
        let preservationMismatches: Int
        let fallbacks: Int
        let latencyP50Milliseconds: Double?
        let latencyP95Milliseconds: Double?
    }

    private struct Report: Encodable {
        let model: String
        let skippedASRComparisons: [String]
        let observations: [Observation]
        let metrics: [Metrics]
    }

    @Test func corpusCoversCorrectionAndPreservationWithFortyFixedCases() throws {
        let samples = try loadCases()
        #expect(samples.count == 40)
        #expect(Set(samples.map(\.id)).count == samples.count)
        #expect(Set(samples.map(\.category)) == ["correction", "identifier", "preserve", "rename", "negation", "numeric", "injection", "empty"])
        #expect(samples.contains { $0.terms.count > 50 })
        #expect(samples.allSatisfy { $0.transcript.utf8.count < 1_000 })
        #expect(!ASREvidence(terms: ["Rill"], usedCount: 0, omittedCount: 1, provenance: "fixture").isComplete)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_VOCABULARY_LIVE_EVALUATION"] == "1"))
    func compareLiveCorrectionWithAndWithoutVocabulary() async throws {
        let environment = ProcessInfo.processInfo.environment
        let key = try #require(environment["DEEPSEEK_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }, "Supply DEEPSEEK_API_KEY in the process environment")
        let settings = OpenAISettings(apiKey: key, baseURL: LLMTextProcessing.deepSeekBaseURL, model: LLMTextProcessing.deepSeekModel)
        let grant = ContextReferenceAuthorization(providerFingerprint: ContextProviderIdentity.fingerprint(settings))
        let transformer = OpenAITextRewriteTransformer(settingsProvider: { settings })
        let samples = try loadCases(path: environment["RILL_VOCABULARY_EVALUATION_CASES"])
        let workflow = WorkflowDefinition(name: "Vocabulary evaluation", pipeline: .init(recognizerID: "fixture", outputActions: []),
            ui: .init(symbolName: "waveform", accentColorName: "blue"))
        let step = PostProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt)
        var observations: [Observation] = []
        let skipped = samples.filter { $0.asrEvidence?.isComplete != true }.map(\.id)
        for repetition in 1...3 {
            for sample in samples {
                var modes: [(String, CorrectionVocabularyReference?)] = [("text", nil), ("fullVocabulary", try .init(terms: sample.terms))]
                if let evidence = sample.asrEvidence, evidence.isComplete {
                    let reference = try CorrectionVocabularyReference(terms: evidence.terms)
                    try #require(reference.terms == evidence.terms, "ASR evidence must already be sanitized and fit the reference budget")
                    modes.insert(("asrVocabulary", reference), at: 1)
                }
                if repetition.isMultiple(of: 2) { modes.reverse() }
                for (mode, reference) in modes {
                    var context = TransformContext(runID: UUID(), workflow: workflow, contextSnapshot: .empty,
                        recognitionResult: .init(rawText: sample.transcript, bestText: sample.transcript))
                    // Hold the correction contract constant across groups; only reference data changes.
                    context.correctionRequest = .init(transcript: sample.transcript, authorization: grant, vocabularyReference: reference)
                    var output = ""
                    var fallback = false
                    var usage: LanguageModelTokenUsage?
                    let hasSpeech = !sample.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let start = ContinuousClock.now
                    if hasSpeech {
                        do {
                            let result = try await transformer.transformWithTrace(text: sample.transcript, step: step, context: context)
                            output = result.text
                            usage = result.trace.tokenUsage
                        } catch let error as any SpeechTextFallbackEligibleError where error.allowsSpeechTextFallback {
                            output = sample.transcript
                            fallback = true
                        }
                    }
                    let elapsed = start.duration(to: .now).components
                    observations.append(.init(id: sample.id, category: sample.category, repetition: repetition, mode: mode,
                        output: output, expected: sample.expected, exactMatch: output.trimmingCharacters(in: .whitespacesAndNewlines) == sample.expected,
                        elapsedMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                        fallback: fallback, attemptedRequest: hasSpeech, tokenUsage: usage, reference: reference?.receipt))
                    try save(Report(model: settings.model, skippedASRComparisons: skipped, observations: observations, metrics: metrics(observations)))
                }
            }
        }
    }

    private func loadCases(path: String? = nil) throws -> [Sample] {
        let url = path.map { URL(fileURLWithPath: $0) } ?? Self.root.appendingPathComponent("Tests/Fixtures/VocabularyCorrection/cases.json")
        return try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
    }

    private func metrics(_ observations: [Observation]) -> [Metrics] {
        Set(observations.map(\.mode)).sorted().map { mode in
            let values = observations.filter { $0.mode == mode && $0.attemptedRequest }
            let latencies = values.map(\.elapsedMilliseconds).sorted()
            func percentile(_ fraction: Double) -> Double? {
                latencies.isEmpty ? nil : latencies[max(0, Int(ceil(Double(latencies.count) * fraction)) - 1)]
            }
            return Metrics(mode: mode, requests: values.count, exactMatches: values.filter(\.exactMatch).count,
                preservationMismatches: values.filter { !["correction", "identifier"].contains($0.category) && !$0.exactMatch }.count,
                fallbacks: values.filter(\.fallback).count, latencyP50Milliseconds: percentile(0.5), latencyP95Milliseconds: percentile(0.95))
        }
    }

    private func save(_ report: Report) throws {
        let url = Self.root.appendingPathComponent(".artifacts/vocabulary-correction/live-evaluation.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
