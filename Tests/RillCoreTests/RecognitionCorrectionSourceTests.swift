import Foundation
import XCTest
@testable import RillCore

final class RecognitionCorrectionSourceTests: XCTestCase {
    func testHistoryFromBeforeTokenUsageStillDecodes() throws {
        let trace = Data(#"{"providerID":"llm.responses","modelID":"model","systemPrompt":"system","workflowPrompt":"workflow","messages":[],"responseText":"answer"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LanguageModelTrace.self, from: trace).tokenUsage)
        let step = Data(#"{"kind":"llmRewrite","result":"completed","outputText":"answer"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkflowTextStep.self, from: step).tokenUsage)
        XCTAssertNil(try JSONDecoder().decode(WorkflowTextStep.self, from: step).durationMilliseconds)
        let receipt = Data(#"{"stepIndex":0,"kind":"recognizeSpeech","result":"completed","duration":"s1To4"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkflowStepReceipt.self, from: receipt).durationMilliseconds)
    }

    func testProcessingStepsRoundTripAndRestrictedPreviewDropsUnrelatedContent() throws {
        let text = String(repeating: "recognized text ", count: 20) + "PRIVATE-TAIL"
        let source = RecognitionCorrectionSource(
            preMappingText: text,
            context: VocabularyRuleContext(bundleIdentifier: "private.app", locale: "zh-CN"),
            languageModelInputTexts: [text],
            languageModelTraces: [LanguageModelTrace(
                providerID: "llm.responses", modelID: "test-model",
                systemPrompt: "private prompt", workflowPrompt: "private instructions",
                messages: [.init(role: .user, content: text)], responseText: text
            )],
            processingSteps: [
                WorkflowTextStep(kind: .recognizeSpeech, outputText: text, durationMilliseconds: 1_234),
                WorkflowTextStep(kind: .applyVocabulary, outputText: text, didChange: false),
                WorkflowTextStep(kind: .llmRewrite, result: .failed,
                                 tokenUsage: .init(inputTokens: 120, outputTokens: 24, totalTokens: 144))
            ]
        )
        let encoded = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(RecognitionCorrectionSource.self, from: encoded), source)
        let preview = try XCTUnwrap(source.restrictedStepPreview)
        XCTAssertEqual(preview.preMappingText, "")
        XCTAssertEqual(preview.context, VocabularyRuleContext())
        XCTAssertNil(preview.languageModelInputTexts)
        XCTAssertNil(preview.languageModelTraces)
        let steps = try XCTUnwrap(preview.processingSteps)
        XCTAssertEqual(steps.map(\.kind), [.recognizeSpeech, .applyVocabulary, .llmRewrite])
        XCTAssertEqual(steps.last?.result, .failed)
        XCTAssertNil(steps.last?.outputText)
        XCTAssertEqual(steps.last?.tokenUsage, source.processingSteps?.last?.tokenUsage)
        XCTAssertEqual(steps.first?.durationMilliseconds, 1_234)
        XCTAssertEqual(steps[1].didChange, false)
        XCTAssertLessThanOrEqual(try XCTUnwrap(steps.first?.outputText).count, 96)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains("PRIVATE-TAIL"))
    }

    func testCorrectionSourceCodableSurfaceContainsOnlyTextAndVocabularyContext() throws {
        let source = RecognitionCorrectionSource(
            preMappingText: "vux type",
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                recordCollectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000042"),
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
