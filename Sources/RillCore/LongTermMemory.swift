import Foundation

public enum MemoryEvidenceKind: String, Codable, Sendable, CaseIterable {
    case userStatement, userCorrection, screenObservation
}

public struct ConfirmedMemoryCorrection: Codable, Sendable, Equatable, Hashable {
    public var original: String
    public var corrected: String

    public init(original: String, corrected: String) {
        self.original = original
        self.corrected = corrected
    }

    public var isValid: Bool {
        !original.isEmpty && !corrected.isEmpty && original != corrected
            && original.utf8.count <= 256 && corrected.utf8.count <= 256
    }
}

public struct MemorySourceVersion: Codable, Sendable, Equatable, Hashable {
    public let sourceID: UUID
    public let revision: Int64

    public init(sourceID: UUID, revision: Int64) {
        self.sourceID = sourceID
        self.revision = revision
    }
}

public struct MemorySource: Codable, Sendable, Equatable {
    public var version: MemorySourceVersion
    public var scope: ContextMemoryScope
    public var transcript: String
    public var polishedText: String?
    public var userCorrections: [ConfirmedMemoryCorrection]
    public var screenObservations: ScreenReferenceSummary?
    public var timestamp: Date

    public init(version: MemorySourceVersion, scope: ContextMemoryScope, transcript: String,
                polishedText: String? = nil, userCorrections: [ConfirmedMemoryCorrection] = [],
                screenObservations: ScreenReferenceSummary? = nil, timestamp: Date) {
        self.version = version
        self.scope = scope
        self.transcript = transcript
        self.polishedText = polishedText
        self.userCorrections = userCorrections
        self.screenObservations = screenObservations
        self.timestamp = timestamp
    }
    public func evidenceText(for kind: MemoryEvidenceKind) -> String {
        switch kind {
        case .userStatement: transcript
        case .userCorrection: userCorrections.map { $0.original + "\n" + $0.corrected }.joined(separator: "\n")
        case .screenObservation: ((screenObservations?.terms ?? []) + (screenObservations?.observations ?? [])).joined(separator: "\n")
        }
    }

}

public enum LongTermMemoryState: String, Codable, Sendable, CaseIterable {
    case candidate, active, archived
}

public struct LongTermMemory: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var revision: Int64
    public var scope: ContextMemoryScope
    public var summary: String
    public var terms: [String]
    public var corrections: [ConfirmedMemoryCorrection]
    public var evidenceKind: MemoryEvidenceKind
    public var sources: [MemorySourceVersion]
    public var state: LongTermMemoryState
    public var confirmed: Bool
    public var locked: Bool
    public var expiresAt: Date?
    public var replacesMemoryID: UUID?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var sourceHistoryDeleted: Bool

    public init(id: UUID = UUID(), revision: Int64 = 1, scope: ContextMemoryScope,
                summary: String, terms: [String] = [], corrections: [ConfirmedMemoryCorrection] = [],
                evidenceKind: MemoryEvidenceKind, sources: [MemorySourceVersion],
                state: LongTermMemoryState = .active, confirmed: Bool = false, locked: Bool = false,
                expiresAt: Date? = nil, replacesMemoryID: UUID? = nil, createdAt: Date = Date(),
                lastUsedAt: Date? = nil, sourceHistoryDeleted: Bool = false) {
        self.id = id
        self.revision = revision
        self.scope = scope
        self.summary = summary
        self.terms = terms
        self.corrections = corrections
        self.evidenceKind = evidenceKind
        self.sources = sources
        self.state = state
        self.confirmed = confirmed
        self.locked = locked
        self.expiresAt = expiresAt
        self.replacesMemoryID = replacesMemoryID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sourceHistoryDeleted = sourceHistoryDeleted
    }

    public var isValid: Bool {
        !summary.isEmpty && summary.utf8.count <= 2_048 && terms.count <= 32
            && terms.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
            && corrections.count <= 16 && corrections.allSatisfy(\.isValid)
            && !sources.isEmpty && sources.count <= 100
            && Set(sources.map(\.sourceID)).count == sources.count
    }

    public mutating func confirm() {
        confirmed = true
        if state == .candidate { state = .active }
    }

    public func isRetrievable(in scene: ContextMemoryScope, now: Date) -> Bool {
        state == .active && scope.matches(scene) && (expiresAt.map { $0 > now } ?? true)
            && (!terms.isEmpty || (confirmed && !corrections.isEmpty))
    }
}

public struct MemoryConsolidationBatch: Sendable {
    public let id: UUID
    public let historyGeneration: RunHistoryWriteGeneration
    public let authorizationID: UUID
    public let memoryRevision: Int64
    public let sources: [MemorySource]
    public let relatedMemories: [LongTermMemory]
    public var authorization: ContextReferenceAuthorization?

    public init(id: UUID = UUID(), historyGeneration: RunHistoryWriteGeneration, authorizationID: UUID,
                memoryRevision: Int64, sources: [MemorySource], relatedMemories: [LongTermMemory],
                authorization: ContextReferenceAuthorization? = nil) {
        self.id = id
        self.historyGeneration = historyGeneration
        self.authorizationID = authorizationID
        self.memoryRevision = memoryRevision
        self.sources = sources
        self.relatedMemories = relatedMemories
        self.authorization = authorization
    }
}

public struct MemoryConsolidationResult: Codable, Sendable {
    public var memories: [LongTermMemory]
    public init(memories: [LongTermMemory]) { self.memories = memories }
}

public struct MemoryConsolidationInput: Encodable, Sendable {
    public let sources: [MemorySource]
    public let relatedMemories: [LongTermMemory]
    public init(batch: MemoryConsolidationBatch) {
        sources = batch.sources
        relatedMemories = batch.relatedMemories
    }
    public init(sources: [MemorySource], relatedMemories: [LongTermMemory]) {
        self.sources = sources
        self.relatedMemories = relatedMemories
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct MemoryMaintenanceStatus: Sendable, Equatable {
    public var requestsToday: Int
    public var foregroundRequestsToday: Int
    public var pendingSourceCount: Int
    public var skippedSourceCount: Int
    public init(requestsToday: Int = 0, foregroundRequestsToday: Int = 0, pendingSourceCount: Int = 0, skippedSourceCount: Int = 0) {
        self.requestsToday = requestsToday
        self.foregroundRequestsToday = foregroundRequestsToday
        self.pendingSourceCount = pendingSourceCount
        self.skippedSourceCount = skippedSourceCount
    }
}

public protocol ContextMemoryRepository: Sendable {
    func setContextAuthorization(_ id: UUID?) async throws
    func recordForegroundContextRequest(authorization: ContextReferenceAuthorization, now: Date) async throws
    func memories() async throws -> [LongTermMemory]
    func saveMemory(_ memory: LongTermMemory, expectedRevision: Int64) async throws
    func deleteMemory(id: UUID, expectedRevision: Int64) async throws
    func relevantMemories(scope: ContextMemoryScope, now: Date) async throws -> [LongTermMemory]
    func prepareMemoryBatch(authorizationID: UUID, allowedWorkflowIDs: Set<UUID>, excludedApplications: Set<String>, now: Date) async throws -> MemoryConsolidationBatch?
    func commitMemoryBatch(_ batch: MemoryConsolidationBatch, result: MemoryConsolidationResult) async throws
    func memoryMaintenanceStatus(now: Date) async throws -> MemoryMaintenanceStatus
    func appendScreenSummary(_ summary: ScreenReferenceSummary, runID: UUID,
                             generation: RunHistoryWriteGeneration, authorization: ContextReferenceAuthorization) async throws
    func recordUserCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) async throws
}

public protocol MemoryConsolidating: Sendable {
    func consolidate(_ batch: MemoryConsolidationBatch) async throws -> MemoryConsolidationResult
}
