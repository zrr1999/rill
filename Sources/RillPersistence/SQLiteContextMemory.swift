import Foundation
import RillCore
import SQLite3

private struct MemoryControl: Codable {
    var authorizationID: UUID?
    var revision: Int64 = 0
    var day: Int = 0
    var requests: Int = 0
    var eligibilityKey: String?
    var foregroundRequests: Int?
}

extension SQLitePersistenceStore: ContextMemoryRepository {
    public func setContextAuthorization(_ id: UUID?) async throws {
        try withImmediateTransaction {
            var control = try memoryControl()
            control.authorizationID = id
            try writeMemoryControl(control)
        }
    }

    public func recordForegroundContextRequest(authorization: ContextReferenceAuthorization, now: Date) async throws {
        try withImmediateTransaction(authorization: authorization) {
            var control = try memoryControl()
            guard control.authorizationID == authorization.id else { throw ContextCorrectionError.authorizationChanged }
            let today = max(control.day, Int(now.timeIntervalSince1970 / 86_400))
            if control.day != today { control.day = today; control.requests = 0; control.foregroundRequests = 0 }
            control.foregroundRequests = (control.foregroundRequests ?? 0) + 1
            try writeMemoryControl(control)
        }
    }

    public func memories() async throws -> [LongTermMemory] {
        try readMemories().map { memory in
            var memory = memory
            memory.sourceHistoryDeleted = try memory.sources.allSatisfy {
                try historyRecords(sourceID: $0.sourceID).isEmpty
            }
            return memory
        }
    }

    public func saveMemory(_ memory: LongTermMemory, expectedRevision: Int64) async throws {
        guard memory.isValid else { throw ContextCorrectionError.invalidReference }
        try withImmediateTransaction {
            let existing = try readMemories().first { $0.id == memory.id }
            guard let existing, existing.revision == expectedRevision,
                  memory.sources == existing.sources, memory.scope == existing.scope,
                  memory.evidenceKind == existing.evidenceKind else { throw ContextCorrectionError.staleSource }
            var updated = memory
            updated.revision = existing.revision + 1
            if updated.confirmed, updated.state == .active, let replacedID = updated.replacesMemoryID,
               var replaced = try readMemories().first(where: { $0.id == replacedID }) {
                guard !replaced.locked, replaced.scope == updated.scope else { throw ContextCorrectionError.invalidReference }
                replaced.state = .archived
                replaced.revision += 1
                try writeMemory(replaced)
            }
            try writeMemory(updated)
            try advanceMemoryRevision()
        }
    }

    public func deleteMemory(id: UUID, expectedRevision: Int64) async throws {
        try withImmediateTransaction {
            guard let memory = try readMemories().first(where: { $0.id == id }),
                  memory.revision == expectedRevision else { throw ContextCorrectionError.staleSource }
            for source in memory.sources {
                try memorySQL("INSERT OR IGNORE INTO context_memory_exclusions(source_id) VALUES (?);",
                              [.text(source.sourceID.uuidString)])
            }
            try memorySQL("DELETE FROM context_memories WHERE id = ?;", [.text(id.uuidString)])
            try advanceMemoryRevision()
        }
    }

    public func relevantMemories(scope: ContextMemoryScope, now: Date) async throws -> [LongTermMemory] {
        try withImmediateTransaction {
            let memories = try archiveExpiredMemories(now: now)
            let selected = memories.filter { $0.isRetrievable(in: scope, now: now) }.sorted {
                if $0.confirmed != $1.confirmed { return $0.confirmed }
                let lhs = $0.lastUsedAt ?? $0.createdAt
                let rhs = $1.lastUsedAt ?? $1.createdAt
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
            }.prefix(5)
            // Usage changes ranking only. It never becomes new evidence or refreshes an expiry.
            return try selected.map { memory in
                var updated = memory
                updated.lastUsedAt = now
                try writeMemory(updated)
                return updated
            }
        }
    }

    public func prepareMemoryBatch(authorizationID: UUID, allowedWorkflowIDs: Set<UUID>, excludedApplications: Set<String> = [], now: Date) async throws -> MemoryConsolidationBatch? {
        try withImmediateTransaction {
            var control = try memoryControl()
            guard control.authorizationID == authorizationID else { throw ContextCorrectionError.authorizationChanged }
            let today = max(control.day, Int(now.timeIntervalSince1970 / 86_400))
            if control.day != today { control.day = today; control.requests = 0; control.foregroundRequests = 0 }
            guard control.requests < 8 else { throw ContextCorrectionError.dailyBudgetExhausted }
            let memories = try archiveExpiredMemories(now: now)
            control.revision = try memoryControl().revision
            let excludedApplications = Set(excludedApplications.map { SensitiveAppRule(bundleIdentifier: $0).normalizedBundleIdentifier })
            let eligibilityKey = allowedWorkflowIDs.map(\.uuidString).sorted().joined(separator: ",")
                + "|" + excludedApplications.sorted().joined(separator: ",")
            if control.eligibilityKey != eligibilityKey {
                try memorySQL("UPDATE context_memory_sources SET processed_revision = 0, skipped_reason = NULL WHERE skipped_reason = 'ineligible';")
                control.eligibilityKey = eligibilityKey
                try writeMemoryControl(control)
            }
            func collectSources() throws -> [MemorySource] {
                var sources: [MemorySource] = []
                while true {
                    try Task.checkCancellation()
                    let pending = try pendingMemorySources(limit: 100)
                    guard !pending.isEmpty else { return sources }
                    for version in pending {
                        let records = try historyRecords(sourceID: version.sourceID)
                        guard let source = try memorySource(version: version, records: records),
                              allowedWorkflowIDs.contains(source.scope.workflowID),
                              !excludedApplications.contains(SensitiveAppRule(bundleIdentifier: source.scope.applicationBundleID ?? "").normalizedBundleIdentifier) else {
                            try markMemorySource(version, skipped: "ineligible")
                            continue
                        }
                        let candidate = sources + [source]
                        let bytes = try MemoryConsolidationInput(sources: candidate, relatedMemories: []).encoded().count
                        if bytes > 12_000 {
                            if !sources.isEmpty { return sources }
                            try markMemorySource(version, skipped: "oversized")
                            continue
                        }
                        sources = candidate
                        if sources.count == 10 { return sources }
                    }
                    // Selected versions remain pending until atomic commit. Stop after this page if any fit.
                    if !sources.isEmpty { return sources }
                }
            }
            let sources = try collectSources()
            guard !sources.isEmpty else { return nil }
            var related: [LongTermMemory] = []
            for memory in memories where memory.state == .active && sources.contains(where: { $0.scope == memory.scope }) {
                let candidate = related + [memory]
                if try MemoryConsolidationInput(sources: sources, relatedMemories: candidate).encoded().count <= 12_000 {
                    related = candidate
                }
                if related.count == 5 { break }
            }
            control.requests += 1 // Reservation is durable; failures and cancellation are not refunded.
            try writeMemoryControl(control)
            return MemoryConsolidationBatch(historyGeneration: try currentRunHistoryWriteGeneration(),
                                            authorizationID: authorizationID, memoryRevision: control.revision,
                                            sources: sources, relatedMemories: related)
        }
    }

    public func commitMemoryBatch(_ batch: MemoryConsolidationBatch, result: MemoryConsolidationResult) async throws {
        try Task.checkCancellation()
        try withImmediateTransaction(authorization: batch.authorization) {
            let control = try memoryControl()
            guard control.authorizationID == batch.authorizationID,
                  control.revision == batch.memoryRevision,
                  try generationIsCurrent(batch.historyGeneration) else { throw ContextCorrectionError.staleSource }
            for source in batch.sources {
                guard try currentMemorySourceVersion(source.version.sourceID) == source.version,
                      try !sourceExcluded(source.version.sourceID),
                      try !historyRecords(sourceID: source.version.sourceID).isEmpty
                else { throw ContextCorrectionError.staleSource }
            }
            guard result.memories.count <= 20, Set(result.memories.map(\.id)).count == result.memories.count else {
                throw ContextCorrectionError.invalidReference
            }
            let existing = try readMemories()
            for proposed in result.memories {
                var memory = proposed
                guard memory.isValid, !memory.confirmed, !memory.locked,
                      memory.state != .archived else { throw ContextCorrectionError.invalidReference }
                let prior = existing.first { $0.id == memory.id }
                if let prior {
                    guard !prior.confirmed, !prior.locked, prior.revision == memory.revision,
                          prior.scope == memory.scope, prior.evidenceKind == memory.evidenceKind,
                          prior.state == .active, prior.expiresAt == memory.expiresAt,
                          batch.relatedMemories.contains(where: { $0.id == prior.id })
                    else { throw ContextCorrectionError.staleSource }
                    memory.revision += 1
                }
                if prior == nil && memory.expiresAt != nil { throw ContextCorrectionError.invalidReference }
                let permitted = Set(batch.sources.filter { $0.scope == memory.scope }.map(\.version) + (prior?.sources ?? []))
                guard Set(memory.sources).isSubset(of: permitted),
                      memory.sources.contains(where: { source in batch.sources.contains { $0.version == source } })
                else { throw ContextCorrectionError.invalidReference }
                let evidence = batch.sources.filter { memory.sources.contains($0.version) }
                    .map { $0.evidenceText(for: memory.evidenceKind) }.joined(separator: "\n")
                guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      memory.terms.allSatisfy({ evidence.contains($0) || prior?.terms.contains($0) == true })
                else { throw ContextCorrectionError.invalidReference }
                if !memory.corrections.isEmpty || memory.replacesMemoryID != nil { memory.state = .candidate }
                try writeMemory(memory)
            }
            for source in batch.sources { try markMemorySource(source.version, skipped: nil) }
            try advanceMemoryRevision()
        }
    }

    public func memoryMaintenanceStatus(now: Date) async throws -> MemoryMaintenanceStatus {
        let control = try memoryControl()
        let pending = try memoryCount("SELECT COUNT(*) FROM context_memory_sources WHERE revision > processed_revision;")
        let skipped = try memoryCount("SELECT COUNT(*) FROM context_memory_sources WHERE skipped_reason IS NOT NULL;")
        return MemoryMaintenanceStatus(requestsToday: Int(now.timeIntervalSince1970 / 86_400) <= control.day ? control.requests : 0,
                                       foregroundRequestsToday: Int(now.timeIntervalSince1970 / 86_400) <= control.day ? (control.foregroundRequests ?? 0) : 0,
                                       pendingSourceCount: pending, skippedSourceCount: skipped)
    }

    public func appendScreenSummary(_ summary: ScreenReferenceSummary, runID: UUID,
                                    generation: RunHistoryWriteGeneration, authorization: ContextReferenceAuthorization) async throws {
        guard summary.isValid else { throw ContextCorrectionError.invalidReference }
        try withImmediateTransaction(authorization: authorization) {
            guard try generationIsCurrent(generation), try memoryControl().authorizationID == authorization.id else {
                throw ContextCorrectionError.staleSource
            }
            for record in try historyRecords(sourceID: runID) {
                guard var source = record.correctionSource, var references = source.references,
                      references.screenSummary != summary else { continue }
                references.screenSummary = summary
                // Preserve the frozen request's pending/sent status even when the historical summary arrives later.
                source.references = references
                try writeCorrectionSource(source, recordID: record.id)
            }
        }
    }

    public func recordUserCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) async throws {
        guard correction.isValid else { throw ContextCorrectionError.invalidReference }
        try withImmediateTransaction {
            let statement = try prepare("SELECT COALESCE(run_id, id) FROM history_records WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            try bind([.text(recordID.uuidString)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let rawID = textColumn(in: statement, index: 0), let sourceID = UUID(uuidString: rawID),
                  let record = try historyRecords(sourceID: sourceID).first(where: { $0.id == recordID }),
                  var source = record.correctionSource else { throw ContextCorrectionError.staleSource }
            var corrections = source.userCorrections ?? []
            guard !corrections.contains(correction) else { return }
            corrections.append(correction)
            source.userCorrections = corrections
            try writeCorrectionSource(source, recordID: recordID)
        }
    }

    private func archiveExpiredMemories(now: Date) throws -> [LongTermMemory] {
        var memories = try readMemories()
        var changed = false
        for index in memories.indices where memories[index].state != .archived {
            guard let expiry = memories[index].expiresAt, expiry <= now else { continue }
            memories[index].state = .archived
            memories[index].revision += 1
            try writeMemory(memories[index])
            changed = true
        }
        if changed { try advanceMemoryRevision() }
        return memories
    }

    private func writeCorrectionSource(_ source: RecognitionCorrectionSource, recordID: UUID) throws {
        let payload = try protectString(String(decoding: encoder.encode(source), as: UTF8.self),
                                        context: historyProtectionContext(recordID: recordID.uuidString, field: "correction_source_json"))
        try memorySQL("UPDATE history_records SET correction_source_json = ? WHERE id = ?;",
                      [.text(payload), .text(recordID.uuidString)])
    }

    private func memorySource(version: MemorySourceVersion, records: [WorkflowResultRecord]) throws -> MemorySource? {
        let receiptTrigger = try memoryReceiptTrigger(sourceID: version.sourceID)
        let voice = records.filter { ($0.trigger ?? receiptTrigger)?.isVoiceCapture == true && $0.outcome == .completed }
        guard let record = voice.first, let workflowID = record.workflowID,
              let text = record.correctionSource?.preMappingText ?? record.finalText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let context = record.correctionSource?.context
        return MemorySource(version: version,
                            scope: ContextMemoryScope(workflowID: workflowID, applicationBundleID: context?.bundleIdentifier,
                                                      language: context?.locale),
                            transcript: text, polishedText: record.finalText,
                            userCorrections: Array(Set(voice.flatMap { $0.correctionSource?.userCorrections ?? [] })).sorted { ($0.original, $0.corrected) < ($1.original, $1.corrected) },
                            screenObservations: voice.compactMap { $0.correctionSource?.references?.screenSummary }.first,
                            timestamp: record.timestamp)
    }

    private func memoryReceiptTrigger(sourceID: UUID) throws -> WorkflowRunTriggerKind? {
        let statement = try prepare("SELECT run_id, timestamp, payload FROM workflow_run_receipts WHERE run_id = ? AND write_generation = ?;")
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID.uuidString), .int(try currentRunHistoryWriteGeneration().value)], to: statement)
        guard try memoryHasRow(statement) else { return nil }
        return try decodeRunReceipt(from: statement).trigger
    }

    func historyRecords(sourceID: UUID) throws -> [WorkflowResultRecord] {
        let statement = try prepare("""
            SELECT id, run_id, workflow_id, workflow_fallback_name, workflow_title_key, final_text,
                   failure_message, timestamp, is_stack_related, outcome, correction_source_json, trigger_kind
            FROM history_records WHERE COALESCE(run_id, id) = ? AND write_generation = ?
            ORDER BY write_ordinal DESC;
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID.uuidString), .int(try currentRunHistoryWriteGeneration().value)], to: statement)
        var records: [WorkflowResultRecord] = []
        while try memoryHasRow(statement) { records.append(try decodeHistoryRecord(from: statement)) }
        return records
    }

    private func pendingMemorySources(limit: Int) throws -> [MemorySourceVersion] {
        let statement = try prepare("""
            SELECT source_id, revision FROM context_memory_sources
            WHERE revision > processed_revision AND source_id NOT IN (SELECT source_id FROM context_memory_exclusions)
            ORDER BY rowid LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.int(Int64(limit))], to: statement)
        var sources: [MemorySourceVersion] = []
        while try memoryHasRow(statement) {
            guard let rawID = textColumn(in: statement, index: 0), let id = UUID(uuidString: rawID) else {
                throw ContextCorrectionError.invalidReference
            }
            sources.append(MemorySourceVersion(sourceID: id, revision: sqlite3_column_int64(statement, 1)))
        }
        return sources
    }

    private func currentMemorySourceVersion(_ id: UUID) throws -> MemorySourceVersion? {
        let statement = try prepare("SELECT revision FROM context_memory_sources WHERE source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        guard try memoryHasRow(statement) else { return nil }
        return MemorySourceVersion(sourceID: id, revision: sqlite3_column_int64(statement, 0))
    }

    private func sourceExcluded(_ id: UUID) throws -> Bool {
        try memoryCount("SELECT COUNT(*) FROM context_memory_exclusions WHERE source_id = ?;", [.text(id.uuidString)]) > 0
    }

    private func markMemorySource(_ version: MemorySourceVersion, skipped: String?) throws {
        try memorySQL("UPDATE context_memory_sources SET processed_revision = ?, skipped_reason = ? WHERE source_id = ? AND revision = ?;",
                      [.int(version.revision), skipped.map(SQLiteBinding.text) ?? .null,
                       .text(version.sourceID.uuidString), .int(version.revision)])
    }

    private func readMemories() throws -> [LongTermMemory] {
        let statement = try prepare("SELECT id, payload FROM context_memories ORDER BY id;")
        defer { sqlite3_finalize(statement) }
        var memories: [LongTermMemory] = []
        while try memoryHasRow(statement) {
            guard let id = textColumn(in: statement, index: 0), let payload = textColumn(in: statement, index: 1) else {
                throw ContextCorrectionError.invalidReference
            }
            let memory = try decoder.decode(LongTermMemory.self, from: Data(openString(payload, context: LocalDataProtectionContext(namespace: "context-memory", recordID: id, field: "payload")).utf8))
            guard memory.id.uuidString == id, memory.isValid else { throw ContextCorrectionError.invalidReference }
            memories.append(memory)
        }
        return memories
    }

    private func writeMemory(_ memory: LongTermMemory) throws {
        let payload = try protectString(String(decoding: encoder.encode(memory), as: UTF8.self), context: LocalDataProtectionContext(namespace: "context-memory", recordID: memory.id.uuidString, field: "payload"))
        try memorySQL("INSERT INTO context_memories(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload;",
                      [.text(memory.id.uuidString), .text(payload)])
    }

    private func memoryControl() throws -> MemoryControl {
        let statement = try prepare("SELECT payload FROM context_memory_control WHERE id = 1;")
        defer { sqlite3_finalize(statement) }
        if try !memoryHasRow(statement) { return MemoryControl() }
        guard let payload = textColumn(in: statement, index: 0) else { throw ContextCorrectionError.invalidReference }
        return try decoder.decode(MemoryControl.self, from: Data(openString(payload, context: LocalDataProtectionContext(namespace: "context-memory", recordID: "control", field: "payload")).utf8))
    }

    private func writeMemoryControl(_ control: MemoryControl) throws {
        let payload = try protectString(String(decoding: encoder.encode(control), as: UTF8.self), context: LocalDataProtectionContext(namespace: "context-memory", recordID: "control", field: "payload"))
        try memorySQL("INSERT INTO context_memory_control(id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload;", [.text(payload)])
    }

    private func advanceMemoryRevision() throws {
        var control = try memoryControl()
        control.revision += 1
        try writeMemoryControl(control)
    }

    private func memorySQL(_ sql: String, _ bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        try step(statement, expecting: SQLITE_DONE)
    }

    private func memoryHasRow(_ statement: OpaquePointer?) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
        }
    }

    private func memoryCount(_ sql: String, _ bindings: [SQLiteBinding] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        try step(statement, expecting: SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
}
