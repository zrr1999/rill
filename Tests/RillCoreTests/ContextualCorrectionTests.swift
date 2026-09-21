import Foundation
import Testing
@testable import RillCore

struct ContextualCorrectionTests {
    @Test func onlyTranscriptCleanupWorkflowsCanUseReferences() {
        func workflow(_ steps: [PostProcessStepKind]) -> WorkflowDefinition {
            WorkflowDefinition(name: "Context", pipeline: .init(recognizerID: "fixture",
                postProcessSteps: steps.map { .init(kind: $0, prompt: "Fixture") }, outputActions: []),
                ui: .init(symbolName: "waveform", accentColorName: "blue"))
        }
        #expect(workflow([.normalizeWhitespace, .llmRewrite]).supportsContextualCorrection)
        #expect(!workflow([.llmAnswer, .llmRewrite]).supportsContextualCorrection)
        #expect(!workflow([.snippetReplacement, .llmRewrite]).supportsContextualCorrection)
        #expect(!workflow([.llmRewrite, .llmRewrite]).supportsContextualCorrection)
    }

    @Test func cancellingOneRunDoesNotRevokeOtherRunsAndParentRevocationReachesAllRuns() throws {
        let grant = ContextReferenceAuthorization(providerFingerprint: "fixture")
        let first = ContextReferenceAuthorization(parent: grant)
        let second = ContextReferenceAuthorization(parent: grant)
        first.revoke()
        #expect(!first.isValid)
        #expect(second.isValid)
        #expect(grant.isValid)
        #expect(throws: ContextCorrectionError.authorizationChanged) { try first.whileAuthorized {} }
        grant.revoke()
        #expect(!second.isValid)
        #expect(throws: ContextCorrectionError.authorizationChanged) { try second.whileAuthorized {} }
    }

    @Test func confirmingCandidateActivatesItWithoutRestoringArchivedMemory() {
        let scope = ContextMemoryScope(workflowID: UUID(), applicationBundleID: "test", language: "zh")
        var memory = LongTermMemory(scope: scope, summary: "Rill", corrections: [.init(original: "real", corrected: "Rill")],
            evidenceKind: .userCorrection, sources: [.init(sourceID: UUID(), revision: 1)], state: .candidate)
        #expect(!memory.isRetrievable(in: scope, now: Date()))
        memory.confirm()
        #expect(memory.isRetrievable(in: scope, now: Date()))
        memory.state = .archived
        memory.confirm()
        #expect(!memory.isRetrievable(in: scope, now: Date()))
    }

    @Test func invalidImageAndAuxiliaryResultSizesAreRejected() throws {
        #expect(throws: ContextCorrectionError.invalidReference) {
            try CorrectionReferenceImage(jpeg: Data([0xff, 0xd8]), width: 2_561, height: 1)
        }
        #expect(throws: ContextCorrectionError.invalidReference) {
            try CorrectionMemorySummary(memoryIDs: (0..<6).map { _ in UUID() }, terms: ["Rill"], corrections: [])
        }
        let token = ContextReferenceAuthorization(providerFingerprint: "test")
        token.revoke()
        var executed = false
        #expect(throws: ContextCorrectionError.authorizationChanged) {
            try token.whileAuthorized { executed = true }
        }
        #expect(!executed)
    }
}
