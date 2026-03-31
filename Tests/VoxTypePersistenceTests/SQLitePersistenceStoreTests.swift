import Foundation
import XCTest
@testable import VoxTypeCore
@testable import VoxTypePersistence

final class SQLitePersistenceStoreTests: XCTestCase {
    func testHistoryRoundTrip() async throws {
        let store = try makeStore()
        let workflowID = UUID()
        let record = HistoryRecord(
            runID: UUID(),
            workflowID: workflowID,
            workflow: WorkflowPresentation(fallbackName: "Persisted Workflow", titleKey: .directDemoClipboard),
            finalText: "hello persistence",
            timestamp: Date(timeIntervalSince1970: 42),
            isStackRelated: true,
            outcome: .completed
        )

        try await store.save(record)
        let records = try await store.records(matching: HistoryQuery(workflowID: workflowID, limit: 10))

        XCTAssertEqual(records, [record])
    }

    func testDiagnosticsAndSettingsRoundTrip() async throws {
        let store = try makeStore()
        let runID = UUID()
        let event = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 64),
            runID: runID,
            subsystem: .providers,
            level: .warning,
            event: "providers.warning",
            message: "provider warning",
            metadata: ["source": "tests"]
        )

        try await store.save(event)
        try await store.setString("simplifiedChinese", forKey: .interfaceLanguage)
        try await store.setString(UUID().uuidString, forKey: .selectedWorkflowID)

        let diagnostics = try await store.events(
            matching: DiagnosticQuery(runID: runID, minimumLevel: .info)
        )
        let language = try await store.string(forKey: .interfaceLanguage)

        XCTAssertEqual(diagnostics, [event])
        XCTAssertEqual(language, "simplifiedChinese")
    }

    func testBatchSettingsFetchReturnsRequestedValues() async throws {
        let store = try makeStore()
        let selectedWorkflowID = UUID().uuidString

        try await store.setString("simplifiedChinese", forKey: .interfaceLanguage)
        try await store.setString(selectedWorkflowID, forKey: .selectedWorkflowID)

        let values = try await store.strings(forKeys: [
            .interfaceLanguage,
            .selectedWorkflowID,
            .deepgramModel,
        ])

        XCTAssertEqual(values[.interfaceLanguage], "simplifiedChinese")
        XCTAssertEqual(values[.selectedWorkflowID], selectedWorkflowID)
        XCTAssertNil(values[.deepgramModel])
        XCTAssertEqual(values.count, 2)
    }

    func testExportMetadataRoundTrip() async throws {
        let store = try makeStore()
        let export = ExportMetadata(
            kind: .diagnostics,
            destinationPath: "/tmp/diagnostics.json",
            itemCount: 7,
            createdAt: Date(timeIntervalSince1970: 128),
            metadata: ["format": "json"]
        )

        try await store.save(export)
        let exports = try await store.exports(limit: 10)

        XCTAssertEqual(exports, [export])
    }

    private func makeStore(file: StaticString = #filePath, line: UInt = #line) throws -> SQLitePersistenceStore {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return try SQLitePersistenceStore(
                databaseURL: directoryURL.appendingPathComponent("voxtype-test.sqlite")
            )
        } catch {
            XCTFail("Failed to create SQLitePersistenceStore: \(error)", file: file, line: line)
            throw error
        }
    }
}
