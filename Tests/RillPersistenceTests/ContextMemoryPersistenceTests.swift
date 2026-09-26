import Foundation
import SQLite3
import Testing

@testable import RillCore
@testable import RillPersistence

struct ContextMemoryPersistenceTests {
    @Test func vocabularyReceiptsRoundTripWithoutBecomingMemoryEvidence() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let reference = try CorrectionVocabularyReference(terms: ["ReferenceOnlyPrivateTerm"])
        let record = fixture.record(text: "Actual transcript", vocabulary: reference.receipt)
        try await fixture.store.save(record)
        let reopened = try SQLitePersistenceStore(databaseURL: fixture.url, localDataProtector: fixture.protector)
        let saved = try #require(try await reopened.records(matching: .all).first)
        #expect(saved.correctionSource?.references?.vocabulary == reference.receipt)
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("ReferenceOnlyPrivateTerm"))
        #expect(!String(decoding: try MemoryConsolidationInput(batch: batch).encoded(), as: UTF8.self).contains("ReferenceOnlyPrivateTerm"))
    }

    @Test(arguments: [false, true]) @MainActor
    func busyDatabaseDoesNotHoldAuthorizationLockAndRevocationRollsBack(screenSummary: Bool) async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let record = fixture.record()
        try await fixture.store.save(record)
        let generation = try await fixture.store.captureRunHistoryWriteGeneration()
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let runAuthorization = ContextReferenceAuthorization(parent: fixture.authorization)
        var competingWriter: OpaquePointer?
        #expect(sqlite3_open_v2(fixture.url.path, &competingWriter, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(competingWriter) }
        #expect(sqlite3_exec(competingWriter, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(competingWriter, "ROLLBACK;", nil, nil, nil) }
        let write = Task {
            if screenSummary {
                try await fixture.store.appendScreenSummary(.init(terms: ["Late"], observations: []),
                    runID: try #require(record.runID), generation: generation, authorization: runAuthorization)
            } else {
                try await fixture.store.recordForegroundContextRequest(authorization: runAuthorization, now: Date())
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(runAuthorization.isValid)
        runAuthorization.revoke()
        #expect(start.duration(to: .now) < .milliseconds(100))
        #expect(sqlite3_exec(competingWriter, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: ContextCorrectionError.authorizationChanged) { try await write.value }
        #expect(try await fixture.store.memoryMaintenanceStatus(now: Date()).foregroundRequestsToday == 0)
        #expect(try await fixture.store.records(matching: .all).first?.correctionSource?.references?.screenSummary == nil)
        #expect(fixture.authorization.isValid)
    }

    @Test func backfillAdvancesPastIneligiblePagesAndDoesNotRestartOnEveryGrant() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let otherWorkflow = UUID()
        for _ in 0..<105 { try await fixture.store.save(fixture.record(workflowID: otherWorkflow)) }
        let allowed = fixture.record()
        try await fixture.store.save(allowed)
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        #expect(batch.sources.map(\.version.sourceID) == [allowed.runID])
        try await fixture.store.commitMemoryBatch(batch, result: .init(memories: [fixture.memory(batch)]))
        let token = UUID()
        try await fixture.store.setContextAuthorization(token)
        #expect(try await fixture.store.prepareMemoryBatch(authorizationID: token, allowedWorkflowIDs: [fixture.workflowID], now: Date()) == nil)
        #expect(try await fixture.store.memoryMaintenanceStatus(now: Date()).requestsToday == 1)
    }

    @Test func screenTermsCannotBeCommittedAsUserStatementsAndForegroundBudgetIsIndependent() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let record = fixture.record()
        try await fixture.store.save(record)
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        try await fixture.store.recordForegroundContextRequest(authorization: fixture.authorization, now: Date())
        let generation = try await fixture.store.captureRunHistoryWriteGeneration()
        try await fixture.store.appendScreenSummary(.init(terms: ["ScreenOnly"], observations: []),
            runID: try #require(record.runID), generation: generation, authorization: fixture.authorization)
        let batch = try #require(try await fixture.batch())
        var invalid = fixture.memory(batch)
        invalid.terms = ["ScreenOnly"]
        await #expect(throws: ContextCorrectionError.invalidReference) {
            try await fixture.store.commitMemoryBatch(batch, result: .init(memories: [invalid]))
        }
        invalid.evidenceKind = .screenObservation
        try await fixture.store.commitMemoryBatch(batch, result: .init(memories: [invalid]))
        let status = try await fixture.store.memoryMaintenanceStatus(now: Date())
        #expect(status.requestsToday == 1)
        #expect(status.foregroundRequestsToday == 1)
    }

    @Test func sensitiveApplicationsAreExcludedRegardlessOfBundleCase() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.record())
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try await fixture.store.prepareMemoryBatch(authorizationID: fixture.authorization.id,
            allowedWorkflowIDs: [fixture.workflowID], excludedApplications: ["  TEST.EDITOR  "], now: Date())
        #expect(batch == nil)
        #expect(try await fixture.store.memoryMaintenanceStatus(now: Date()).requestsToday == 0)
    }

    @Test func backgroundArchivesExpiredMemoryBeforeChoosingMergeTargets() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.record())
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let first = try #require(try await fixture.batch())
        var memory = fixture.memory(first)
        try await fixture.store.commitMemoryBatch(first, result: .init(memories: [memory]))
        memory.expiresAt = Date().addingTimeInterval(-1)
        try await fixture.store.saveMemory(memory, expectedRevision: memory.revision)
        try await fixture.store.save(fixture.record(text: "Another Rill record"))
        let next = try #require(try await fixture.batch())
        #expect(next.relatedMemories.isEmpty)
        #expect(try await fixture.store.memories().first?.state == .archived)
    }

    @Test func identicalHistorySaveDoesNotRelearnAndRevokedTokenCannotAppendOrCommit() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let record = fixture.record()
        try await fixture.store.save(record)
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        try await fixture.store.commitMemoryBatch(batch, result: .init(memories: [fixture.memory(batch)]))
        try await fixture.store.save(record)
        #expect(try await fixture.batch() == nil)
        try await fixture.store.recordUserCorrection(.init(original: "Real", corrected: "Rill"), recordID: record.id)
        var pending = try #require(try await fixture.batch())
        pending.authorization = fixture.authorization
        let generation = try await fixture.store.captureRunHistoryWriteGeneration()
        fixture.authorization.revoke()
        await #expect(throws: ContextCorrectionError.authorizationChanged) {
            try await fixture.store.commitMemoryBatch(pending, result: .init(memories: []))
        }
        await #expect(throws: ContextCorrectionError.authorizationChanged) {
            try await fixture.store.appendScreenSummary(.init(terms: ["Late"], observations: []),
                runID: try #require(record.runID), generation: generation, authorization: fixture.authorization)
        }
    }

    @Test func backfillIsBoundedEncryptedAndDoesNotLearnItsOwnMemorySummary() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        for index in 0..<13 {
            try await fixture.store.save(fixture.record(text: "Project\(index)"))
        }
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        #expect(batch.sources.count == 10)
        #expect(try MemoryConsolidationInput(batch: batch).encoded().count <= 12_000)
        let memory = fixture.memory(batch)
        try await fixture.store.commitMemoryBatch(
            batch, result: MemoryConsolidationResult(memories: [memory]))
        let next = try #require(try await fixture.batch())
        #expect(next.sources.count == 3)
        #expect(
            Set(next.sources.map(\.version.sourceID)).isDisjoint(
                with: Set(batch.sources.map(\.version.sourceID))))
        let serialized = try JSONEncoder().encode(batch.sources)
        #expect(!String(decoding: serialized, as: UTF8.self).contains("memorySummary"))
        var database: OpaquePointer?
        #expect(
            sqlite3_open_v2(fixture.url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(
                database, "SELECT payload FROM context_memories;", -1, &statement, nil)
                == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let stored = String(cString: try #require(sqlite3_column_text(statement, 0)))
        #expect(!stored.contains(memory.summary))
        #expect(!stored.contains("Project"))
    }

    @Test func oneRecordingProducesOneSourceAndLateScreenSummaryAdvancesThatSource() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let runID = UUID()
        let first = fixture.record(runID: runID)
        try await fixture.store.save(first)
        try await fixture.store.save(fixture.record(runID: runID, text: "Polished"))
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        #expect(batch.sources.count == 1)
        let generation = try await fixture.store.captureRunHistoryWriteGeneration()
        let screen = ScreenReferenceSummary(terms: ["VisibleName"], observations: ["Budget: 2000"])
        try await fixture.store.appendScreenSummary(
            screen, runID: runID, generation: generation, authorization: fixture.authorization)
        await #expect(throws: ContextCorrectionError.self) {
            try await fixture.store.commitMemoryBatch(
                batch, result: MemoryConsolidationResult(memories: [fixture.memory(batch)]))
        }
        let revised = try #require(try await fixture.batch())
        #expect(revised.sources.count == 1)
        #expect(revised.sources[0].version.sourceID == batch.sources[0].version.sourceID)
        #expect(revised.sources[0].version.revision > batch.sources[0].version.revision)
        #expect(revised.sources[0].screenObservations == screen)
        #expect(revised.sources[0].userCorrections.isEmpty)
        let records = try await fixture.store.records(matching: .all)
        #expect(records.allSatisfy { $0.correctionSource?.references?.imageSummary == .pending })
    }

    @Test func historyCleanupKeepsCommittedMemoryButCannotCommitPendingLearning() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.record())
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        let memory = fixture.memory(batch)
        try await fixture.store.commitMemoryBatch(
            batch, result: MemoryConsolidationResult(memories: [memory]))
        try await fixture.store.save(fixture.record(text: "New source"))
        let pending = try #require(try await fixture.batch())
        _ = try await fixture.store.deleteAllRecords()
        await #expect(throws: ContextCorrectionError.self) {
            try await fixture.store.commitMemoryBatch(
                pending, result: MemoryConsolidationResult(memories: [fixture.memory(pending)]))
        }
        let retained = try await fixture.store.memories()
        #expect(retained.count == 1)
        #expect(retained[0].sourceHistoryDeleted)
        #expect(
            try await fixture.store.relevantMemories(scope: retained[0].scope, now: Date()).count
                == 1)
    }

    @Test func permanentDeletionExcludesSameSourceEvenAfterSourceRevisionAndRestart() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let record = fixture.record(runID: UUID())
        try await fixture.store.save(record)
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let batch = try #require(try await fixture.batch())
        let memory = fixture.memory(batch)
        try await fixture.store.commitMemoryBatch(
            batch, result: MemoryConsolidationResult(memories: [memory]))
        try await fixture.store.deleteMemory(id: memory.id, expectedRevision: 1)
        let revised = WorkflowResultRecord(id: record.id, runID: record.runID, workflowID: record.workflowID,
                                          workflow: record.workflow, finalText: "Revised Rill",
                                          timestamp: record.timestamp, outcome: record.outcome,
                                          correctionSource: record.correctionSource, trigger: record.trigger)
        try await fixture.store.save(revised)
        let reopened = try SQLitePersistenceStore(
            databaseURL: fixture.url, localDataProtector: fixture.protector)
        #expect(try await reopened.memories().isEmpty)
        #expect(
            try await reopened.prepareMemoryBatch(
                authorizationID: fixture.authorization.id,
                allowedWorkflowIDs: [fixture.workflowID], now: Date()) == nil)
    }

    @Test func userLockAndAuthorizationChangesInvalidatePendingBackgroundMerge() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        let record = fixture.record()
        try await fixture.store.save(record)
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        let initial = try #require(try await fixture.batch())
        var memory = fixture.memory(initial)
        try await fixture.store.commitMemoryBatch(
            initial, result: MemoryConsolidationResult(memories: [memory]))
        try await fixture.store.recordUserCorrection(
            .init(original: "Real", corrected: "Rill"), recordID: record.id)
        let pending = try #require(try await fixture.batch())
        memory.locked = true
        memory.confirmed = true
        try await fixture.store.saveMemory(memory, expectedRevision: memory.revision)
        await #expect(throws: ContextCorrectionError.self) {
            try await fixture.store.commitMemoryBatch(
                pending, result: .init(memories: [fixture.memory(pending)]))
        }
        let second = try #require(try await fixture.batch())
        try await fixture.store.setContextAuthorization(nil)
        await #expect(throws: ContextCorrectionError.self) {
            try await fixture.store.commitMemoryBatch(
                second, result: .init(memories: [fixture.memory(second)]))
        }
        #expect(try await fixture.store.memories().first?.locked == true)
    }

    @Test func failedRequestsConsumeDurableDailyBudgetButNoNewSourcesMakeNoRequest() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        #expect(try await fixture.batch() == nil)
        #expect(try await fixture.store.memoryMaintenanceStatus(now: Date()).requestsToday == 0)
        try await fixture.store.save(fixture.record())
        for _ in 0..<8 { #expect(try await fixture.batch() != nil) }
        await #expect(throws: ContextCorrectionError.self) { _ = try await fixture.batch() }
        let reopened = try SQLitePersistenceStore(
            databaseURL: fixture.url, localDataProtector: fixture.protector)
        #expect(try await reopened.memoryMaintenanceStatus(now: Date()).requestsToday == 8)
    }

    @Test func oversizedSourcesAreSkippedWholeAndExpiredMemoriesAreArchived() async throws {
        let fixture = try MemoryStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.setContextAuthorization(fixture.authorization.id)
        try await fixture.store.save(fixture.record(text: String(repeating: "Long", count: 4_000)))
        #expect(try await fixture.batch() == nil)
        #expect(
            try await fixture.store.memoryMaintenanceStatus(now: Date()).skippedSourceCount == 1)
        try await fixture.store.save(fixture.record())
        let batch = try #require(try await fixture.batch())
        var memory = fixture.memory(batch)
        try await fixture.store.commitMemoryBatch(batch, result: .init(memories: [memory]))
        memory.expiresAt = Date.distantPast
        memory.locked = true
        try await fixture.store.saveMemory(memory, expectedRevision: 1)
        #expect(try await fixture.store.relevantMemories(scope: memory.scope, now: Date()).isEmpty)
        #expect(try await fixture.store.memories().first?.state == .archived)
    }
}

private struct MemoryStoreFixture {
    let url: URL
    let store: SQLitePersistenceStore
    let protector: AESGCMDataProtector
    let workflowID = UUID()
    let authorization = ContextReferenceAuthorization(providerFingerprint: "fixture")
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-memory-tests-\(UUID())/rill.sqlite")
        protector = try AESGCMDataProtector(
            key: Data(repeating: 0x31, count: AESGCMDataProtector.keyByteCount))
        store = try SQLitePersistenceStore(databaseURL: url, localDataProtector: protector)
    }
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func record(runID: UUID = UUID(), text: String = "Rill project", workflowID: UUID? = nil,
                vocabulary: VocabularyReferenceReceipt? = nil) -> WorkflowResultRecord {
        WorkflowResultRecord(runID: runID, workflowID: workflowID ?? self.workflowID,
                             workflow: WorkflowPresentation(fallbackName: "Cleanup"), finalText: text,
                             timestamp: Date(timeIntervalSince1970: 1_700_000_000), outcome: .completed,
                             correctionSource: .init(preMappingText: text, context: .init(bundleIdentifier: "test.editor"),
                                                     references: .init(image: .sent, imageSummary: .pending, vocabulary: vocabulary)),
                             trigger: .hotkey)
    }
    func batch() async throws -> MemoryConsolidationBatch? {
        try await store.prepareMemoryBatch(
            authorizationID: authorization.id, allowedWorkflowIDs: [workflowID], now: Date())
    }
    func memory(_ batch: MemoryConsolidationBatch) -> LongTermMemory {
        LongTermMemory(scope: batch.sources[0].scope, summary: "Source-backed Rill project", terms: [batch.sources[0].transcript],
                       evidenceKind: .userStatement, sources: batch.sources.map(\.version))
    }
}
