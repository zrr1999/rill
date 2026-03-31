import Foundation
import XCTest
@testable import VoxTypeCore
@testable import VoxTypeRuntime

final class InMemoryRepositoryTests: XCTestCase {
    func testHistoryRepositoryFiltersByWorkflowAndLimit() async throws {
        let workflowID = UUID()
        let otherWorkflowID = UUID()
        let repository = InMemoryHistoryRepository(
            records: [
                HistoryRecord(
                    runID: UUID(),
                    workflowID: workflowID,
                    workflow: WorkflowPresentation(fallbackName: "Primary"),
                    finalText: "first",
                    timestamp: Date(timeIntervalSince1970: 10),
                    outcome: .completed
                ),
                HistoryRecord(
                    runID: UUID(),
                    workflowID: workflowID,
                    workflow: WorkflowPresentation(fallbackName: "Primary"),
                    finalText: "second",
                    timestamp: Date(timeIntervalSince1970: 20),
                    outcome: .completed
                ),
                HistoryRecord(
                    runID: UUID(),
                    workflowID: otherWorkflowID,
                    workflow: WorkflowPresentation(fallbackName: "Other"),
                    finalText: "other",
                    timestamp: Date(timeIntervalSince1970: 30),
                    outcome: .failed
                ),
            ]
        )

        let records = try await repository.records(matching: HistoryQuery(workflowID: workflowID, limit: 1))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.workflowID, workflowID)
        XCTAssertEqual(records.first?.finalText, "second")
    }

    func testDiagnosticRepositoryFiltersByRunAndMinimumLevel() async throws {
        let runID = UUID()
        let repository = InMemoryDiagnosticRepository(
            events: [
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 10),
                    runID: runID,
                    subsystem: .session,
                    level: .debug,
                    event: "session.debug",
                    message: "debug"
                ),
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 20),
                    runID: runID,
                    subsystem: .session,
                    level: .error,
                    event: "session.error",
                    message: "error"
                ),
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 30),
                    runID: UUID(),
                    subsystem: .providers,
                    level: .warning,
                    event: "providers.warning",
                    message: "warning"
                ),
            ]
        )

        let events = try await repository.events(
            matching: DiagnosticQuery(runID: runID, minimumLevel: .warning)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "session.error")
    }
}
