import AppKit
import Foundation
import RillCore
import RillPlatform
import Testing
@testable import RillProviders

/// Explicit opt-in: sends only this fixed synthetic corpus, never a captured screen or real history.
struct ContextualCorrectionEvaluationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private struct Sample: Decodable {
        let id: String
        let category: String
        let transcript: String
        let screenText: String
        let expected: String
        let memoryTerms: [String]
        let corrections: [ConfirmedMemoryCorrection]
    }
    private struct Observation: Encodable {
        let id: String
        let category: String
        let mode: String
        let output: String
        let expected: String
        let exactContentMatch: Bool
        let elapsedMilliseconds: Double
        let fellBack: Bool
    }

    @Test func corpusContainsFortyBoundedCases() throws {
        let cases = try loadCases()
        #expect(cases.count == 40)
        #expect(Set(cases.map(\.id)).count == 40)
        #expect(cases.allSatisfy { $0.screenText.utf8.count < 1_000 && $0.transcript.utf8.count < 1_000 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_CONTEXT_LIVE_EVALUATION"] == "1"))
    @MainActor func compareLiveDeepSeekTextAndReferenceCorrection() async throws {
        let settings = try await evaluationSettings()
        let token = ContextReferenceAuthorization(providerFingerprint: ContextProviderIdentity.fingerprint(settings))
        let transformer = OpenAITextRewriteTransformer(settingsProvider: { settings })
        let workflow = WorkflowDefinition(name: "Context evaluation", pipeline: PipelineDeclaration(recognizerID: "fixture", outputActions: []),
                                          ui: .init(symbolName: "waveform", accentColorName: "blue"))
        let step = PostProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt)
        var observations: [Observation] = []
        let cases = try loadCases()
        for sample in cases {
            let image = try referenceImage(text: sample.screenText)
            for referenceMode in [false, true] {
                var context = TransformContext(runID: UUID(), workflow: workflow, contextSnapshot: .empty,
                    recognitionResult: .init(rawText: sample.transcript, bestText: sample.transcript))
                if referenceMode {
                    let memory = sample.memoryTerms.isEmpty && sample.corrections.isEmpty ? nil : try CorrectionMemorySummary(
                        memoryIDs: [UUID()], terms: sample.memoryTerms, corrections: sample.corrections)
                    context.correctionRequest = .init(transcript: sample.transcript, referenceImage: image,
                        imageSummary: .init(terms: [], observations: [sample.screenText]), memorySummary: memory, authorization: token)
                }
                let start = ContinuousClock.now
                var output = ""
                var fellBack = false
                if !sample.transcript.isEmpty {
                    do { output = try await transformer.transform(text: sample.transcript, step: step, context: context) }
                    catch let error as any SpeechTextFallbackEligibleError where error.allowsSpeechTextFallback {
                        output = sample.transcript
                        fellBack = true
                    }
                }
                let elapsed = start.duration(to: .now).components
                observations.append(.init(id: sample.id, category: sample.category,
                    mode: referenceMode ? "references" : "text", output: output, expected: sample.expected,
                    exactContentMatch: normalized(output) == normalized(sample.expected),
                    elapsedMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15, fellBack: fellBack))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let report = Self.root.appendingPathComponent(".artifacts/contextual-memory-20260920/live-evaluation.json")
                try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(observations).write(to: report, options: .atomic)
            }
        }
        #expect(observations.count == 80)
    }

    private func loadCases() throws -> [Sample] {
        try JSONDecoder().decode([Sample].self, from: Data(contentsOf: Self.root.appendingPathComponent("Tests/Fixtures/ContextCorrection/cases.json")))
    }
    private func normalized(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0) }.map(String.init).joined().lowercased()
    }
    @MainActor private func referenceImage(text: String) throws -> CorrectionReferenceImage {
        let image = NSImage(size: NSSize(width: 1_280, height: 720))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1_280, height: 720).fill()
        (text as NSString).draw(in: NSRect(x: 60, y: 250, width: 1_160, height: 400),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
        return try CorrectionReferenceImage(jpeg: jpeg,
                                            width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }
    private func evaluationSettings() async throws -> OpenAISettings {
        if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty {
            return OpenAISettings(apiKey: key, baseURL: LLMTextProcessing.deepSeekBaseURL, model: LLMTextProcessing.deepSeekModel)
        }
        throw OpenAITextRewriteError.credentialUnavailable
    }
}
