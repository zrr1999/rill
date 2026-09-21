import Foundation
import RillCore
import Testing
@testable import RillProviders

struct ContextCorrectionProviderTests {
    @Test(arguments: [false, true])
    func mergeRetainsExistingTermsButRejectsInventedTerms(invented: Bool) async throws {
        let scope = ContextMemoryScope(workflowID: UUID(), applicationBundleID: nil, language: nil)
        let prior = LongTermMemory(scope: scope, summary: "Alpha", terms: ["Alpha"],
            evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        let source = MemorySource(version: .init(sourceID: UUID(), revision: 1), scope: scope,
                                  transcript: "Beta", timestamp: Date())
        let client = SummaryClientProbe(output: """
            {"memories":[{"sourceIDs":["\(source.version.sourceID)"],"evidenceKind":"userStatement",
            "summary":"Alpha and Beta","terms":["Alpha","Beta"\(invented ? ",\"Invented\"" : "")],
            "corrections":[],"mergeInto":"\(prior.id)","replacesMemoryID":null}]}
            """)
        let settings = OpenAISettings(apiKey: "test", baseURL: LLMTextProcessing.deepSeekBaseURL, model: LLMTextProcessing.deepSeekModel)
        let authorization = ContextReferenceAuthorization(providerFingerprint: ContextProviderIdentity.fingerprint(settings))
        let provider = ContextCorrectionProvider(settingsProvider: { settings }, authorization: authorization, clientFactory: { client })
        let batch = MemoryConsolidationBatch(historyGeneration: .initial, authorizationID: authorization.id,
            memoryRevision: 1, sources: [source], relatedMemories: [prior])
        if invented {
            await #expect(throws: ContextCorrectionError.invalidReference) { _ = try await provider.consolidate(batch) }
        } else {
            let merged = try #require(try await provider.consolidate(batch).memories.first)
            #expect(merged.id == prior.id)
            #expect(merged.terms == ["Alpha", "Beta"])
            #expect(Set(merged.sources) == Set(prior.sources + [source.version]))
        }
    }

    @Test func memorySummaryRejectsInventedEvidenceAndUnconfirmedCorrections() async throws {
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Private broad summary must not enter live extraction", terms: ["Rill"],
            corrections: [.init(original: "real", corrected: "Rill")], evidenceKind: .userStatement,
            sources: [.init(sourceID: UUID(), revision: 1)], confirmed: false)
        let client = SummaryClientProbe(output: """
            {"memoryIDs":["\(memory.id)"],"terms":["Invented"],"corrections":[]}
            """)
        let settings = OpenAISettings(apiKey: "test", baseURL: LLMTextProcessing.deepSeekBaseURL, model: LLMTextProcessing.deepSeekModel)
        let provider = ContextCorrectionProvider(settingsProvider: { settings },
            authorization: .init(providerFingerprint: ContextProviderIdentity.fingerprint(settings)), clientFactory: { client })
        await #expect(throws: ContextCorrectionError.invalidReference) { _ = try await provider.summarizeMemories([memory]) }
        let request = try #require(await client.request)
        #expect(!request.input.contains(memory.summary))
        #expect(!request.input.contains("real"))
        #expect(request.jsonOutput)
        #expect(request.timeoutInterval == 10)
        #expect(!request.store)
    }

    @Test func malformedOrOversizedScreenSummaryIsOmittedAsInvalid() async throws {
        let client = SummaryClientProbe(output: """
            {"terms":["\(String(repeating: "x", count: 513))"],"observations":[]}
            """)
        let settings = OpenAISettings(apiKey: "test", baseURL: LLMTextProcessing.deepSeekBaseURL, model: LLMTextProcessing.deepSeekModel)
        let provider = ContextCorrectionProvider(settingsProvider: { settings },
            authorization: .init(providerFingerprint: ContextProviderIdentity.fingerprint(settings)), clientFactory: { client })
        let image = try CorrectionReferenceImage(jpeg: Data([0xff, 0xd8]), width: 1, height: 1)
        await #expect(throws: ContextCorrectionError.invalidReference) { _ = try await provider.summarizeImage(image) }
    }
}

private actor SummaryClientProbe: OpenAIResponsesServing {
    let output: String
    private(set) var request: OpenAIResponsesRequest?
    init(output: String) { self.output = output }
    func createResponse(request: OpenAIResponsesRequest, apiKey: String) async throws -> OpenAIResponsesResult {
        self.request = request
        return .init(status: .completed, outputText: output, containsRefusal: false, httpStatusCode: 200)
    }
}
