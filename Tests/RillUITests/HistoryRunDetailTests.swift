import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import Testing
@testable import RillUI

@MainActor
struct HistoryRunDetailTests {
    @Test func summarySeparatesAudioFromProcessingAndIncludesFailedCalls() throws {
        let receipt = try makeReceipt(steps: [
            .init(stepIndex: 0, kind: .recognizeSpeech, result: .completed, duration: .s1To4, durationMilliseconds: 1_234),
            .init(stepIndex: 1, kind: .llmRewrite, result: .completed, duration: .s1To4, durationMilliseconds: 2_500),
            .init(stepIndex: 2, kind: .llmRewrite, result: .failed, duration: .s1To4, durationMilliseconds: 1_000)
        ])
        let items = HistoryRunTiming.items(for: .init(id: receipt.id, record: nil, receipt: receipt))
        #expect(items.map(\.milliseconds) == [12_500, 1_234, 3_500])
        #expect(items.map(\.kind) == [nil, .recognizeSpeech, .llmRewrite])
        #expect(items.last?.result == .failed)
    }

    @Test func missingMeasurementsAreNotReconstructedFromBucketsOrPartialSums() throws {
        let receipt = try makeReceipt(steps: [
            .init(stepIndex: 0, kind: .recognizeSpeech, result: .completed, duration: .s1To4),
            .init(stepIndex: 1, kind: .llmRewrite, result: .completed, duration: .s1To4, durationMilliseconds: 2_500),
            .init(stepIndex: 2, kind: .llmRewrite, result: .completed, duration: .s1To4)
        ])
        let items = HistoryRunTiming.items(for: .init(id: receipt.id, record: nil, receipt: receipt))
        #expect(items.map(\.milliseconds) == [12_500, nil, nil])
        #expect(L10n.historyMeasuredDuration(nil, language: .simplifiedChinese) == "未记录")
        #expect(!items.contains { $0.kind == .llmAnswer })
    }

    @Test func diagnosticsQueryFindsTheExactRunBeyondGlobalRecentEvents() async throws {
        let runID = UUID()
        let ownEvent = DiagnosticEvent(timestamp: .distantPast, runID: runID,
                                      subsystem: .session, level: .error, event: "session.failure",
                                      message: "PRIVATE provider body", metadata: ["apiKey": "PRIVATE-key"])
        let unrelated = (0..<60).map { _ in
            DiagnosticEvent(runID: UUID(), subsystem: .session, level: .info,
                            event: "session.stage", message: "unrelated")
        }
        let harness = makeHarness(diagnosticRepository: InMemoryDiagnosticRepository(events: [ownEvent] + unrelated))
        await harness.model.waitForInitialVoiceConfiguration()
        await harness.model.waitForHistoryProjectionLoads()
        let events = try await harness.model.diagnostics(for: runID)
        #expect(events.count == 1)
        #expect(events.first?.runID == runID)
        #expect(events.first?.event == "session.failure")
        #expect(!events[0].message.contains("PRIVATE"))
        #expect(events[0].metadata["apiKey"] == nil)
        #expect(harness.model.selectedSidebarSection != .diagnostics)
        await harness.model.stopSettingsReadTasksForApplicationShutdown()
    }

    private func makeReceipt(steps: [WorkflowStepReceipt]) throws -> WorkflowRunReceipt {
        try WorkflowRunReceipt(runID: UUID(), workflowID: nil, trigger: .hotkey,
                               timestamp: Date(), duration: .s1To4, termination: .completed,
                               stepDetails: steps, recordingDurationMilliseconds: 12_500)
    }
}
