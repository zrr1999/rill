import Foundation
import XCTest
@testable import RillCore

final class RecognitionCorrectionSourceTests: XCTestCase {
    func testCorrectionSourceCodableSurfaceContainsOnlyTextAndVocabularyContext() throws {
        let source = RecognitionCorrectionSource(
            preMappingText: "vux type",
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                clipboardGroupID: UUID(uuidString: "00000000-0000-0000-0000-000000000042"),
                locale: "zh-CN"
            )
        )

        let data = try JSONEncoder().encode(source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["preMappingText", "context"])
        XCTAssertEqual(try JSONDecoder().decode(RecognitionCorrectionSource.self, from: data), source)
    }

    func testWorkflowRunSummaryCorrectionSourceIsOptional() {
        let source = RecognitionCorrectionSource(
            preMappingText: "recognized",
            context: VocabularyRuleContext(locale: "en-US")
        )
        let workflow = WorkflowPresentation(fallbackName: "Dictation")

        let summaryWithoutSource = WorkflowRunSummary(
            runID: UUID(),
            workflowID: UUID(),
            workflow: workflow,
            trigger: .manual,
            finalText: "delivered"
        )
        let summaryWithSource = WorkflowRunSummary(
            runID: UUID(),
            workflowID: UUID(),
            workflow: workflow,
            trigger: .manual,
            finalText: "delivered",
            correctionSource: source
        )

        XCTAssertNil(summaryWithoutSource.correctionSource)
        XCTAssertEqual(summaryWithSource.correctionSource, source)
    }

    func testLanguageModelTraceUsesClosedCredentialFreeSchema() throws {
        let source = RecognitionCorrectionSource(
            preMappingText: "question",
            context: VocabularyRuleContext(),
            languageModelTraces: [
                LanguageModelTrace(
                    providerID: "openai.responses",
                    modelID: "model",
                    systemPrompt: "system",
                    workflowPrompt: "workflow",
                    messages: [.init(role: .user, content: "question")],
                    responseText: "answer"
                ),
            ]
        )

        let data = try JSONEncoder().encode(source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let traces = try XCTUnwrap(object["languageModelTraces"] as? [[String: Any]])
        let trace = try XCTUnwrap(traces.first)

        XCTAssertEqual(
            Set(trace.keys),
            [
                "providerID", "modelID", "systemPrompt", "workflowPrompt", "messages",
                "responseText",
            ]
        )
        XCTAssertNil(trace["apiKey"])
        XCTAssertNil(trace["baseURL"])
        XCTAssertNil(trace["headers"])
        XCTAssertEqual(try JSONDecoder().decode(RecognitionCorrectionSource.self, from: data), source)
    }
}
