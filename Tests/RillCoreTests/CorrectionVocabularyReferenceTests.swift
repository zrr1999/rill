import Foundation
import Testing
@testable import RillCore

struct CorrectionVocabularyReferenceTests {
    @Test func completeCandidatesSurviveTheRecognitionCapAndScopeFiltering() throws {
        var rules = (0..<75).map { VocabularyRule(kind: .hotword, pattern: "Term\($0)", replacement: "", priority: 100 - $0) }
        rules += [
            .init(kind: .hotword, enabled: false, pattern: "Disabled", replacement: ""),
            .init(kind: .hotword, pattern: "OtherApp", replacement: "", scope: .init(bundleIdentifier: "other.app")),
            .init(kind: .hotword, pattern: "Term0", replacement: ""),
            .init(kind: .hotword, pattern: "invalid\nterm", replacement: ""),
            .init(pattern: "Replacement", replacement: "NotAHotword")
        ]
        let resolution = VocabularyRecognitionHintResolver().resolve(rules: rules, context: .init(bundleIdentifier: "editor.app"))
        let reference = try CorrectionVocabularyReference(terms: resolution.allCandidates.map(\.term))
        #expect(resolution.candidates.count == 50)
        #expect(resolution.hints.keyterms.count == 50)
        #expect(reference.terms == (0..<75).map { "Term\($0)" })
        #expect(reference.receipt.eligibleCount == 75)
    }

    @Test func byteBudgetCountsJSONEscapingAndSkipsWholeOversizedTerms() throws {
        let full = try CorrectionVocabularyReference(terms: [String(repeating: "x", count: 11_986), "overflow"])
        #expect(full.encodedByteCount == 12_000)
        #expect(try JSONEncoder().encode(full).count == 12_000)
        #expect(full.receipt.omittedCount == 1)
        let escaped = String(repeating: "\"/\\", count: 2_100)
        let reference = try CorrectionVocabularyReference(terms: [escaped, "Rill", "中文", "Rill", "\n"])
        #expect(reference.terms == ["Rill", "中文"])
        #expect(reference.receipt.eligibleCount == 3)
        #expect(reference.receipt.omittedCount == 1)
        #expect(try JSONEncoder().encode(reference).count == reference.encodedByteCount)
        #expect(reference.encodedByteCount < CorrectionVocabularyReference.maximumEncodedBytes)
    }

    @Test func oldSettingsAndHistoryRemainReadableAndReferencesStayOutOfReceipts() throws {
        let old = Data(#"{"screenContextEnabled":true,"memoryEnabled":false,"authorizedWorkflowIDs":[],"providerFingerprint":"original"}"#.utf8)
        let settings = try JSONDecoder().decode(ContextFeatureSettings.self, from: old)
        #expect(!settings.vocabularyCorrectionEnabled)
        #expect(settings.screenContextEnabled)
        #expect(settings.providerFingerprint == "original")
        let oldReceipt = Data(#"{"image":"disabled","imageSummary":"disabled","memorySummary":"disabled","memoryIDs":[]}"#.utf8)
        #expect(try JSONDecoder().decode(CorrectionReferenceReceipt.self, from: oldReceipt).vocabulary == nil)
        let reference = try CorrectionVocabularyReference(terms: ["private-project"])
        let receipt = CorrectionReferenceReceipt(vocabulary: reference.receipt)
        let encoded = try JSONEncoder().encode(receipt)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-project"))
        #expect(try JSONDecoder().decode(CorrectionReferenceReceipt.self, from: encoded) == receipt)
        #expect(ContextualCorrectionRequest(transcript: "正文", vocabularyReference: reference).hasCorrectionReferences)
        #expect(!ContextualCorrectionRequest(transcript: "正文", vocabularyReference: try .init(terms: [])).hasCorrectionReferences)
    }

    @Test func onlyTheUnmodifiedBuiltinCleanupContractIsEligible() throws {
        var workflow = WorkflowDefinition(id: try #require(UUID(uuidString: "D3E19A88-F9FB-4AB3-8444-CDBF7E215A88")), name: "Renamed Cleanup",
            pipeline: .init(recognizerID: "test", postProcessSteps: [.init(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt)], outputActions: []),
            ui: .init(symbolName: "waveform", accentColorName: "blue"),
            metadata: [WorkflowMetadataKey.catalog: "builtin", WorkflowMetadataKey.builtinKind: "push-to-talk.polish"])
        #expect(workflow.supportsVocabularyCorrection)
        workflow.metadata[WorkflowMetadataKey.catalog] = "custom"
        #expect(!workflow.supportsVocabularyCorrection)
        workflow.metadata[WorkflowMetadataKey.catalog] = "builtin"
        workflow.plan.process.steps = [.init(kind: .recognizeSpeech), .init(kind: .llmRewrite, prompt: "Translate to English")]
        #expect(!workflow.supportsVocabularyCorrection)
    }
}
