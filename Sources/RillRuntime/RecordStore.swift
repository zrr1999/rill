import Foundation
import RillCore

public enum RecordStoreError: Error, LocalizedError, Sendable, Equatable {
    case collectionUnavailable
    case recordUnavailable
    case membershipUnavailable
    case membershipChanged
    case membershipAlreadyInUse
    case manualSelectionRequired
    case membershipLimitReached
    case routeCollectionLimitReached
    case recordLimitReached
    case payloadLimitReached
    case totalPayloadLimitReached
    case collectionLimitReached
    case routeLimitReached
    case invalidGraph
    case invalidTextCorrection
    case invalidDeliveryReceipt
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .collectionUnavailable: "The selected record collection is unavailable."
        case .recordUnavailable: "The selected record is unavailable."
        case .membershipUnavailable: "The selected collection membership is unavailable."
        case .membershipChanged: "The selected collection membership changed."
        case .membershipAlreadyInUse: "The selected record is already being delivered."
        case .manualSelectionRequired: "This collection requires an explicit record selection."
        case .membershipLimitReached: "The record membership limit has been reached."
        case .routeCollectionLimitReached: "The route collection limit has been reached."
        case .recordLimitReached: "The Record store item limit has been reached."
        case .payloadLimitReached: "The Record payload exceeds the local storage limit."
        case .totalPayloadLimitReached: "The Record store content budget has been reached."
        case .collectionLimitReached: "The record collection limit has been reached."
        case .routeLimitReached: "The record route limit has been reached."
        case .invalidGraph: "The stored record graph is invalid."
        case .invalidTextCorrection: "The text correction is empty or no longer matches this edit."
        case .invalidDeliveryReceipt: "The delivery sink returned an invalid receipt."
        case .persistenceUnavailable: "The protected record store is unavailable."
        }
    }
}

public struct RecordDeliveryLease: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let record: Record
    public let membership: RecordMembership
    public let consumptionPolicy: RecordConsumptionPolicy
    public let sink: RecordSinkIdentity

    init(
        id: UUID,
        record: Record,
        membership: RecordMembership,
        consumptionPolicy: RecordConsumptionPolicy,
        sink: RecordSinkIdentity
    ) {
        self.id = id
        self.record = record
        self.membership = membership
        self.consumptionPolicy = consumptionPolicy
        self.sink = sink
    }
}

public struct RecordCollectionDeletionImpact: Identifiable, Sendable, Equatable {
    public var collectionID: RecordCollectionID
    public var membershipCount: Int
    public var captureRuleIDs: [RecordRouteRuleID]
    public var deliveryRuleIDs: [RecordRouteRuleID]

    public init(
        collectionID: RecordCollectionID,
        membershipCount: Int,
        captureRuleIDs: [RecordRouteRuleID],
        deliveryRuleIDs: [RecordRouteRuleID]
    ) {
        self.collectionID = collectionID
        self.membershipCount = membershipCount
        self.captureRuleIDs = captureRuleIDs
        self.deliveryRuleIDs = deliveryRuleIDs
    }

    public var hasRouteReferences: Bool {
        !captureRuleIDs.isEmpty || !deliveryRuleIDs.isEmpty
    }

    public var id: RecordCollectionID { collectionID }
}

public enum RecordCollectionReferenceResolution: Sendable, Equatable {
    case replace(with: RecordCollectionID)
    case disableAffectedRoutes
}

/// Single owner of the local Record graph, membership leases, and persistence
/// CAS coordinate. Records are immutable; every mutating command touches only
/// metadata, activity, membership, collection, or route state.
public actor RecordStore {
    private struct GraphState {
        var recordsByID: [RecordID: RecordHeader] = [:]
        var recordOrder: [RecordID] = []
        var metadataByRecordID: [RecordID: RecordMetadata] = [:]
        var activityByRecordID: [RecordID: RecordActivity] = [:]
        var collectionsByID: [RecordCollectionID: RecordCollection] = [
            RecordCollection.inboxID: .inbox,
            RecordCollection.voiceInputID: .voiceInput,
        ]
        var collectionOrder: [RecordCollectionID] = [
            RecordCollection.inboxID,
            RecordCollection.voiceInputID,
        ]
        var membershipsByID: [RecordMembershipID: RecordMembership] = [:]
        var membershipIDsByRecordID: [RecordID: [RecordMembershipID]] = [:]
        var membershipIDsByCollectionID: [RecordCollectionID: [RecordMembershipID]] = [
            RecordCollection.inboxID: [],
            RecordCollection.voiceInputID: [],
        ]
        var captureRules: [CaptureRouteRule] = []
        var deliveryRules: [DeliveryRouteRule] = []
        var nextMembershipOrdinal: UInt64 = 1
        var revision: UInt64 = 0
        var repositoryRevision: Int64?
        var durableBlobReferencesByRecordID: [RecordID: RecordGraphPersistenceBlobReference] = [:]
    }

    private struct LeaseState: Sendable {
        let membershipID: RecordMembershipID
        let expectedRevision: UInt64
        let consumptionPolicy: RecordConsumptionPolicy
        let sink: RecordSinkIdentity
    }

    private struct PersistedGraph: Codable {
        static let schemaVersion = 1

        struct PersistedRecord: Codable {
            var id: RecordID
            var payloadKind: RecordPayloadKind
            var payloadBlob: RecordGraphPersistenceBlobReference
            var provenance: RecordProvenance
            var createdAt: Date
        }

        var schemaVersion: Int
        var records: [PersistedRecord]
        var metadata: [RecordMetadata]
        var activity: [RecordActivity]
        var collections: [RecordCollection]
        var memberships: [RecordMembership]
        var captureRules: [CaptureRouteRule]
        var deliveryRules: [DeliveryRouteRule]
        var nextMembershipOrdinal: UInt64
    }

    private var graphState = GraphState()
    private var reuseLeases: [UUID: RecordReuseLease] = [:]
    private var leasesByID: [UUID: LeaseState] = [:]
    private var leasedMembershipIDs: Set<RecordMembershipID> = []
    private var settlingLeaseIDs: Set<UUID> = []

    private let persistence: (any RecordGraphPersistenceStore)?
    private let storageLimits: RecordStorageLimits
    private var dirtyCatalogIDs: [RecordCatalogNode.Kind: Set<UUID>] = [:]
    private var committedGraphState: GraphState? {
        didSet { dirtyCatalogIDs.removeAll(keepingCapacity: true) }
    }
    private var isInitialized = false
    private var isInitializing = false
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []
    private var initializationError: RecordStoreError?
    private var isPersistingGraph = false
    private var graphPersistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotContinuations: [UUID: AsyncStream<RecordCatalogSnapshot>.Continuation] = [:]
    private var collectionEventSink: (any RecordCollectionEventSink)?
    private var payloadCache: [RecordID: RecordPayload] = [:]
    private var payloadCacheOrder: [RecordID] = []
    private var payloadCacheBytes = 0
    private var hasCatalogPersistence = false
    private var admissionWasLimited = false
    private var searchCache: [RecordID: RecordSearchDocument] = [:]
    private var searchCacheOrder: [RecordID] = []
    private var searchCacheBytes = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        persistence: (any RecordGraphPersistenceStore)? = nil,
        collectionEventSink: (any RecordCollectionEventSink)? = nil,
        storageLimits: RecordStorageLimits = .productDefault
    ) {
        self.persistence = persistence
        self.collectionEventSink = collectionEventSink
        self.storageLimits = storageLimits
        isInitialized = persistence == nil
    }

    private func ensureInitialized() async throws {
        if !isInitialized {
            if isInitializing {
                await withCheckedContinuation { continuation in
                    initializationWaiters.append(continuation)
                }
            } else {
                isInitializing = true
                await loadPersistedGraph()
                isInitializing = false
                isInitialized = true
                let waiters = initializationWaiters
                initializationWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        if let initializationError { throw initializationError }
        if committedGraphState == nil {
            committedGraphState = graphState
        }
        await waitForGraphPersistence()
    }

    public func snapshot() async throws -> RecordStoreSnapshot {
        try await ensureInitialized()
        let catalog = makeCatalogSnapshot()
        var records: [RecordProjection] = []
        for summary in catalog.records {
            if let record = try await projection(for: summary.id) { records.append(record) }
        }
        guard graphState.revision == catalog.revision else { throw RecordStoreError.membershipChanged }
        return RecordStoreSnapshot(revision: catalog.revision, records: records, collections: catalog.collections,
                                   captureRules: catalog.captureRules, deliveryRules: catalog.deliveryRules)
    }

    public func catalogSnapshot() async throws -> RecordCatalogSnapshot {
        try await ensureInitialized()
        return makeCatalogSnapshot()
    }

    public func catalogStream() async throws -> AsyncStream<RecordCatalogSnapshot> {
        try await ensureInitialized()
        let id = UUID()
        let initial = makeCatalogSnapshot()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    public func snapshotStream() async throws -> AsyncStream<RecordStoreSnapshot> {
        let source = try await catalogStream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                for await _ in source {
                    guard !Task.isCancelled, let self else { break }
                    do { continuation.yield(try await self.snapshot()) }
                    catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func setRecordCollectionEventSink(_ sink: (any RecordCollectionEventSink)?) {
        collectionEventSink = sink
    }

    public func record(id: RecordID) async throws -> RecordProjection? {
        try await ensureInitialized()
        return try await projection(for: id)
    }

    public func collection(id: RecordCollectionID) async throws -> RecordCollectionProjection? {
        try await ensureInitialized()
        guard let collection = graphState.collectionsByID[id] else { return nil }
        let memberships = graphState.membershipIDsByCollectionID[id, default: []]
            .compactMap { graphState.membershipsByID[$0] }
        var records: [RecordID: Record] = [:]
        for id in Set(memberships.map(\.recordID)) {
            records[id] = try await materializedRecord(id)
        }
        return RecordCollectionProjection(collection: collection, memberships: memberships, recordsByID: records)
    }

    /// A local correction is a new immutable, history-only Record. It neither
    /// changes the original nor emits collection events that could deliver it.
    public func saveTextCorrection(
        workflowRunID: UUID, text: String, operationID: UUID
    ) async throws -> RecordProjection {
        try await ensureInitialized()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordStoreError.invalidTextCorrection
        }
        let identity = "text-correction/\(operationID.uuidString)"
        if let existing = graphState.recordsByID.values.first(where: {
            $0.provenance.source.identifier == identity
        }), let projection = try await projection(for: existing.id) {
            guard existing.provenance.workflowRunID == workflowRunID,
                  projection.record.payload.textValue == text else {
                throw RecordStoreError.invalidTextCorrection
            }
            return projection
        }
        guard let original = graphState.recordOrder.reversed().compactMap({ graphState.recordsByID[$0] })
            .first(where: {
                $0.kind == .text && $0.provenance.workflowRunID == workflowRunID
                    && $0.provenance.derivedFrom == nil
            }) else { throw RecordStoreError.recordUnavailable }
        var provenance = original.provenance
        provenance.source = RecordSourceIdentity(kind: .user, identifier: identity)
        provenance.derivedFrom = original.id
        provenance.supersedes = nil
        provenance.alternatives = []
        return try await ingest(RecordDraft(payload: .text(text), provenance: provenance), into: [])
    }

    @discardableResult
    public func ingest(
        _ draft: RecordDraft,
        into destinationCollectionIDs: [RecordCollectionID]
    ) async throws -> RecordProjection {
        try await ensureInitialized()
        let destinations = stableUnique(destinationCollectionIDs)
        guard destinations.count <= RecordGraphLimits.maximumRouteCollections else {
            throw RecordStoreError.routeCollectionLimitReached
        }
        guard destinations.allSatisfy({ graphState.collectionsByID[$0] != nil }) else {
            throw RecordStoreError.collectionUnavailable
        }
        guard graphState.membershipsByID.count + destinations.count <= RecordGraphLimits.maximumMemberships else {
            throw RecordStoreError.membershipLimitReached
        }
        try validateRecordAdmission(
            payload: draft.payload,
            tags: draft.tags,
            activeRecordDelta: destinations.isEmpty ? 0 : 1,
            historyOnlyRecordDelta: destinations.isEmpty ? 1 : 0
        )
        for collectionID in destinations {
            guard activeMembershipCount(in: collectionID)
                    < storageLimits.maximumActiveMembershipCountPerCollection
            else { throw RecordStoreError.recordLimitReached }
        }

        let record = Record(
            payload: draft.payload,
            provenance: draft.provenance,
            createdAt: draft.createdAt
        )
        markCatalogChange(.record, id: record.id)
        graphState.recordsByID[record.id] = RecordHeader(record: record, byteCount: try encodedPayload(record.payload).count)
        cachePayload(record.payload, for: record.id)
        graphState.recordOrder.insert(record.id, at: 0)
        markCatalogChange(.metadata, id: record.id)
        graphState.metadataByRecordID[record.id] = RecordMetadata(
            recordID: record.id,
            tags: normalizedTags(draft.tags),
            isPinned: draft.isPinned
        )
        markCatalogChange(.activity, id: record.id)
        graphState.activityByRecordID[record.id] = RecordActivity(recordID: record.id)
        graphState.membershipIDsByRecordID[record.id] = []
        for collectionID in destinations {
            _ = try addMembershipWithoutPersistence(recordID: record.id, collectionID: collectionID)
        }
        noteMutation()
        try await persistCurrentGraph()
        guard let projection = try await projection(for: record.id) else {
            throw RecordStoreError.invalidGraph
        }
        await publishCollectionEvents(
            projection.memberships.map {
                collectionEvent(.recordCreated, membership: $0, record: record)
            }
        )
        return projection
    }

    @discardableResult
    public func addMembership(
        recordID: RecordID,
        to collectionID: RecordCollectionID
    ) async throws -> RecordMembership {
        try await ensureInitialized()
        if let existing = graphState.membershipIDsByRecordID[recordID, default: []]
            .compactMap({ graphState.membershipsByID[$0] })
            .first(where: { $0.collectionID == collectionID }) {
            return existing
        }
        let wasActive = hasActiveMembership(recordID: recordID)
        guard activeMembershipCount(in: collectionID)
                < storageLimits.maximumActiveMembershipCountPerCollection
        else { throw RecordStoreError.recordLimitReached }
        if !wasActive,
           activeRecordCount() >= storageLimits.maximumActiveRecordCount {
            throw RecordStoreError.recordLimitReached
        }
        let membership = try addMembershipWithoutPersistence(
            recordID: recordID,
            collectionID: collectionID
        )
        noteMutation()
        try await persistCurrentGraph()
        if let record = graphState.recordsByID[recordID] {
            await publishCollectionEvents([
                collectionEvent(.recordCreated, membership: membership, record: record)
            ])
        }
        return membership
    }

    public func removeMembership(
        _ membershipID: RecordMembershipID,
        expectedRevision: UInt64? = nil
    ) async throws {
        try await ensureInitialized()
        guard let membership = graphState.membershipsByID[membershipID] else {
            throw RecordStoreError.membershipUnavailable
        }
        if let expectedRevision, membership.revision != expectedRevision {
            throw RecordStoreError.membershipChanged
        }
        guard !leasedMembershipIDs.contains(membershipID) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let record = graphState.recordsByID[membership.recordID]
        removeMembershipWithoutPersistence(membershipID)
        noteMutation()
        try await persistCurrentGraph()
        if let record {
            await publishCollectionEvents([
                collectionEvent(.recordRemoved, membership: membership, record: record)
            ])
        }
    }

    public func deleteRecord(_ recordID: RecordID) async throws {
        try await ensureInitialized()
        guard graphState.recordsByID[recordID] != nil else { throw RecordStoreError.recordUnavailable }
        guard !reuseLeases.values.contains(where: { $0.record.id == recordID }) else { throw RecordStoreError.membershipAlreadyInUse }
        let membershipIDs = graphState.membershipIDsByRecordID[recordID, default: []]
        guard membershipIDs.allSatisfy({ !leasedMembershipIDs.contains($0) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let removedMemberships = membershipIDs.compactMap { graphState.membershipsByID[$0] }
        let removedRecord = graphState.recordsByID[recordID]
        for membershipID in membershipIDs { removeMembershipWithoutPersistence(membershipID) }
        markCatalogChange(.record, id: recordID)
        graphState.recordsByID.removeValue(forKey: recordID)
        graphState.recordOrder.removeAll { $0 == recordID }
        markCatalogChange(.metadata, id: recordID)
        graphState.metadataByRecordID.removeValue(forKey: recordID)
        markCatalogChange(.activity, id: recordID)
        graphState.activityByRecordID.removeValue(forKey: recordID)
        graphState.membershipIDsByRecordID.removeValue(forKey: recordID)
        graphState.durableBlobReferencesByRecordID.removeValue(forKey: recordID)
        noteMutation()
        try await persistCurrentGraph()
        if let removedRecord {
            await publishCollectionEvents(
                removedMemberships.map {
                    collectionEvent(.recordRemoved, membership: $0, record: removedRecord)
                }
            )
        }
    }

    public func updateMetadata(
        recordID: RecordID,
        tags: [String]? = nil,
        isPinned: Bool? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> RecordMetadata {
        try await ensureInitialized()
        guard var metadata = graphState.metadataByRecordID[recordID] else {
            throw RecordStoreError.recordUnavailable
        }
        if let expectedRevision, metadata.revision != expectedRevision {
            throw RecordStoreError.membershipChanged
        }
        if let tags {
            let normalized = normalizedTags(tags)
            try validateTags(normalized)
            metadata.tags = normalized
        }
        if let isPinned { metadata.isPinned = isPinned }
        metadata.advanceRevision()
        markCatalogChange(.metadata, id: recordID)
        graphState.metadataByRecordID[recordID] = metadata
        noteMutation()
        try await persistCurrentGraph()
        return metadata
    }

    @discardableResult
    public func replace(
        membershipID: RecordMembershipID,
        expectedRevision: UInt64,
        with payload: RecordPayload,
        inAllCollections: Bool = false,
        createdAt: Date = Date()
    ) async throws -> RecordProjection {
        try await ensureInitialized()
        guard let sourceMembership = graphState.membershipsByID[membershipID] else {
            throw RecordStoreError.membershipUnavailable
        }
        guard sourceMembership.revision == expectedRevision else {
            throw RecordStoreError.membershipChanged
        }
        guard !leasedMembershipIDs.contains(membershipID),
              let sourceRecord = graphState.recordsByID[sourceMembership.recordID],
              let sourceMetadata = graphState.metadataByRecordID[sourceRecord.id]
        else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let destinationMemberships = inAllCollections
            ? graphState.membershipIDsByRecordID[sourceRecord.id, default: []].compactMap { graphState.membershipsByID[$0] }
            : [sourceMembership]
        guard destinationMemberships.allSatisfy({ !leasedMembershipIDs.contains($0.id) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let replacingMembershipIDs = Set(destinationMemberships.map(\.id))
        let sourceWasActive = hasActiveMembership(recordID: sourceRecord.id)
        let sourceRemainsActive = graphState.membershipIDsByRecordID[sourceRecord.id, default: []]
            .compactMap { graphState.membershipsByID[$0] }
            .contains { !replacingMembershipIDs.contains($0.id) && $0.state == .active }
        let replacementIsActive = destinationMemberships.contains { $0.state == .active }
        try validateRecordAdmission(
            payload: payload,
            tags: sourceMetadata.tags,
            activeRecordDelta: (replacementIsActive ? 1 : 0)
                + (sourceRemainsActive ? 1 : 0)
                - (sourceWasActive ? 1 : 0),
            historyOnlyRecordDelta: (replacementIsActive ? 0 : 1)
                + (sourceRemainsActive ? 0 : 1)
                - (sourceWasActive ? 0 : 1)
        )

        var provenance = sourceRecord.provenance
        provenance.source = RecordSourceIdentity(kind: .user, identifier: "replace")
        provenance.derivedFrom = sourceRecord.id
        provenance.supersedes = sourceRecord.id
        let replacement = Record(payload: payload, provenance: provenance, createdAt: createdAt)
        markCatalogChange(.record, id: replacement.id)
        graphState.recordsByID[replacement.id] = RecordHeader(record: replacement, byteCount: try encodedPayload(replacement.payload).count)
        cachePayload(replacement.payload, for: replacement.id)
        graphState.recordOrder.insert(replacement.id, at: 0)
        markCatalogChange(.metadata, id: replacement.id)
        graphState.metadataByRecordID[replacement.id] = RecordMetadata(
            recordID: replacement.id,
            tags: sourceMetadata.tags,
            isPinned: sourceMetadata.isPinned
        )
        markCatalogChange(.activity, id: replacement.id)
        graphState.activityByRecordID[replacement.id] = RecordActivity(recordID: replacement.id)
        graphState.membershipIDsByRecordID[replacement.id] = []

        for membership in destinationMemberships {
            removeMembershipWithoutPersistence(membership.id)
            let replacementMembership = RecordMembership(
                id: membership.id,
                recordID: replacement.id,
                collectionID: membership.collectionID,
                ordinal: membership.ordinal,
                state: membership.state,
                revision: membership.revision == .max ? 1 : membership.revision + 1
            )
            markCatalogChange(.membership, id: replacementMembership.id)
            graphState.membershipsByID[replacementMembership.id] = replacementMembership
            graphState.membershipIDsByRecordID[replacement.id, default: []].append(replacementMembership.id)
            graphState.membershipIDsByCollectionID[replacementMembership.collectionID, default: []]
                .append(replacementMembership.id)
            sortCollectionMemberships(replacementMembership.collectionID)
        }
        noteMutation()
        try await persistCurrentGraph()
        guard let projection = try await projection(for: replacement.id) else {
            throw RecordStoreError.invalidGraph
        }
        await publishCollectionEvents(
            projection.memberships.map {
                collectionEvent(.recordEdited, membership: $0, record: replacement)
            }
        )
        return projection
    }

    @discardableResult
    public func createCollection(
        name: String,
        preset: RecordCollectionPreset = .stack
    ) async throws -> RecordCollection {
        try await ensureInitialized()
        guard graphState.collectionsByID.count < storageLimits.maximumCollectionCount else {
            throw RecordStoreError.collectionLimitReached
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= storageLimits.maximumCollectionNameUTF8ByteCount
        else { throw RecordStoreError.payloadLimitReached }
        let collection = RecordCollection(name: normalizedName, preset: preset)
        markCatalogChange(.collection, id: collection.id)
        graphState.collectionsByID[collection.id] = collection
        graphState.collectionOrder.append(collection.id)
        graphState.membershipIDsByCollectionID[collection.id] = []
        noteMutation()
        try await persistCurrentGraph()
        return collection
    }

    public func updateCollection(
        _ collectionID: RecordCollectionID,
        name: String? = nil,
        selectionPolicy: RecordSelectionPolicy? = nil,
        consumptionPolicy: RecordConsumptionPolicy? = nil,
        preset: RecordCollectionPreset? = nil
    ) async throws -> RecordCollection {
        try await ensureInitialized()
        guard var collection = graphState.collectionsByID[collectionID] else {
            throw RecordStoreError.collectionUnavailable
        }
        if let name {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty,
                  normalizedName.utf8.count <= storageLimits.maximumCollectionNameUTF8ByteCount
            else { throw RecordStoreError.payloadLimitReached }
            collection.name = normalizedName
        }
        if let preset {
            collection.apply(preset)
        } else {
            if let selectionPolicy { collection.selectionPolicy = selectionPolicy }
            if let consumptionPolicy { collection.consumptionPolicy = consumptionPolicy }
            collection.revision = collection.revision == .max ? 1 : collection.revision + 1
        }
        markCatalogChange(.collection, id: collectionID)
        graphState.collectionsByID[collectionID] = collection
        noteMutation()
        try await persistCurrentGraph()
        return collection
    }

    public func deletionImpact(for collectionID: RecordCollectionID) async throws -> RecordCollectionDeletionImpact {
        try await ensureInitialized()
        guard graphState.collectionsByID[collectionID] != nil else {
            throw RecordStoreError.collectionUnavailable
        }
        return RecordCollectionDeletionImpact(
            collectionID: collectionID,
            membershipCount: graphState.membershipIDsByCollectionID[collectionID, default: []].count,
            captureRuleIDs: graphState.captureRules.filter { $0.destinationCollectionIDs.contains(collectionID) }.map(\.id),
            deliveryRuleIDs: graphState.deliveryRules.filter {
                $0.sourceCollectionIDs.contains(collectionID) || $0.sinkCollectionID == collectionID
            }.map(\.id)
        )
    }

    public func deleteCollection(
        _ collectionID: RecordCollectionID,
        resolvingReferences resolution: RecordCollectionReferenceResolution? = nil
    ) async throws {
        try await ensureInitialized()
        let impact = try await deletionImpact(for: collectionID)
        if impact.hasRouteReferences, resolution == nil {
            throw RecordStoreError.collectionUnavailable
        }
        let membershipIDs = graphState.membershipIDsByCollectionID[collectionID, default: []]
        guard membershipIDs.allSatisfy({ !leasedMembershipIDs.contains($0) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        switch resolution {
        case .replace(let replacementID):
            guard replacementID != collectionID, graphState.collectionsByID[replacementID] != nil else {
                throw RecordStoreError.collectionUnavailable
            }
            graphState.captureRules = graphState.captureRules.map { rule in
                var rule = rule
                rule.destinationCollectionIDs = stableUnique(
                    rule.destinationCollectionIDs.map { $0 == collectionID ? replacementID : $0 }
                )
                return rule
            }
            graphState.deliveryRules = graphState.deliveryRules.map { rule in
                var rule = rule
                rule.sourceCollectionIDs = stableUnique(
                    rule.sourceCollectionIDs.map { $0 == collectionID ? replacementID : $0 }
                )
                if rule.sinkCollectionID == collectionID {
                    rule.sinkCollectionID = replacementID
                }
                return rule
            }
        case .disableAffectedRoutes:
            graphState.captureRules = graphState.captureRules.map { rule in
                guard rule.destinationCollectionIDs.contains(collectionID) else { return rule }
                var rule = rule
                rule.destinationCollectionIDs.removeAll { $0 == collectionID }
                if rule.destinationCollectionIDs.isEmpty { rule.isEnabled = false }
                return rule
            }
            graphState.deliveryRules = graphState.deliveryRules.map { rule in
                guard rule.sourceCollectionIDs.contains(collectionID)
                    || rule.sinkCollectionID == collectionID
                else { return rule }
                var rule = rule
                rule.sourceCollectionIDs.removeAll { $0 == collectionID }
                if rule.sinkCollectionID == collectionID {
                    rule.sinkCollectionID = nil
                    rule.isEnabled = false
                }
                if rule.sourceCollectionIDs.isEmpty { rule.isEnabled = false }
                return rule
            }
        case nil:
            break
        }
        let removedMemberships = membershipIDs.compactMap { graphState.membershipsByID[$0] }
        let removedRecords = Dictionary(
            uniqueKeysWithValues: Set(removedMemberships.map(\.recordID)).compactMap { recordID in
                graphState.recordsByID[recordID].map { (recordID, $0) }
            }
        )
        for membershipID in membershipIDs {
            removeMembershipWithoutPersistence(membershipID)
        }
        markCatalogChange(.collection, id: collectionID)
        graphState.collectionsByID.removeValue(forKey: collectionID)
        graphState.collectionOrder.removeAll { $0 == collectionID }
        graphState.membershipIDsByCollectionID.removeValue(forKey: collectionID)
        noteMutation()
        try await persistCurrentGraph()
        await publishCollectionEvents(
            removedMemberships.compactMap { membership in
                removedRecords[membership.recordID].map {
                    collectionEvent(.recordRemoved, membership: membership, record: $0)
                }
            }
        )
    }

    public func replaceCaptureRules(_ rules: [CaptureRouteRule]) async throws {
        try await ensureInitialized()
        guard rules.count <= storageLimits.maximumCaptureRouteCount,
              Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({
            $0.destinationCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections
                && stableUnique($0.destinationCollectionIDs) == $0.destinationCollectionIDs
                && $0.destinationCollectionIDs.allSatisfy { graphState.collectionsByID[$0] != nil }
        }) else { throw RecordStoreError.invalidGraph }
        graphState.captureRules = rules
        noteMutation()
        try await persistCurrentGraph()
    }

    public func replaceDeliveryRules(_ rules: [DeliveryRouteRule]) async throws {
        try await ensureInitialized()
        guard rules.count <= storageLimits.maximumDeliveryRouteCount,
              Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({
            $0.sourceCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections
                && stableUnique($0.sourceCollectionIDs) == $0.sourceCollectionIDs
                && $0.sourceCollectionIDs.allSatisfy { graphState.collectionsByID[$0] != nil }
                && ($0.sink != .recordCollection
                    ? $0.sinkCollectionID == nil
                    : $0.sinkCollectionID.map { graphState.collectionsByID[$0] != nil } == true)
        }) else { throw RecordStoreError.invalidGraph }
        graphState.deliveryRules = rules
        noteMutation()
        try await persistCurrentGraph()
    }

    public func routedCaptureDestinations(
        for envelope: RecordCaptureEnvelope
    ) async throws -> [RecordCollectionID] {
        try await ensureInitialized()
        guard envelope.requestedCollectionIDs.allSatisfy({ graphState.collectionsByID[$0] != nil }) else {
            throw RecordStoreError.collectionUnavailable
        }
        var result = stableUnique(envelope.requestedCollectionIDs)
        for rule in graphState.captureRules
        where rule.isEnabled && rule.matcher.matches(envelope.draft.provenance) {
            for collectionID in rule.destinationCollectionIDs where !result.contains(collectionID) {
                result.append(collectionID)
            }
        }
        if result.isEmpty {
            result = [
                envelope.draft.provenance.source.kind == .voiceInput
                    ? RecordCollection.voiceInputID
                    : RecordCollection.inboxID
            ]
        }
        guard result.count <= RecordGraphLimits.maximumRouteCollections else {
            throw RecordStoreError.routeCollectionLimitReached
        }
        return result
    }

    public func resolveDeliveryRoute(
        target: FocusedApplicationIdentity
    ) async throws -> DeliveryRouteRule? {
        try await ensureInitialized()
        return graphState.deliveryRules
            .filter { $0.isEnabled && $0.matcher.matches(target) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .first
    }

    public func routeProjection(
        target: FocusedApplicationIdentity
    ) async throws -> RecordRouteProjection {
        try await ensureInitialized()
        let route = graphState.deliveryRules
            .filter { $0.isEnabled && $0.matcher.matches(target) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .first
        let sourceIDs = route?.sourceCollectionIDs ?? [RecordCollection.inboxID]
        for collectionID in sourceIDs {
            guard let collection = graphState.collectionsByID[collectionID] else { continue }
            let active = activeMemberships(in: collectionID)
            guard collection.selectionPolicy != .manual,
                  let membership = selectedMembership(from: active, policy: collection.selectionPolicy),
                  let record = try await materializedRecord(membership.recordID),
                  graphState.membershipsByID[membership.id] == membership,
                  !leasedMembershipIDs.contains(membership.id)
            else { continue }
            return RecordRouteProjection(
                collection: collection,
                count: active.count,
                previewText: record.payload.textValue.map { text in
                    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized.count <= 120 ? normalized : String(normalized.prefix(117)) + "…"
                },
                previewSubject: deliverySubject(record: record, membership: membership),
                previewPayload: record.payload
            )
        }
        return RecordRouteProjection()
    }

    public func beginDelivery(
        sourceCollectionIDs: [RecordCollectionID],
        sink: RecordSinkIdentity,
        manualMembershipID: RecordMembershipID? = nil
    ) async throws -> RecordDeliveryLease {
        try await ensureInitialized()
        for collectionID in sourceCollectionIDs {
            guard let collection = graphState.collectionsByID[collectionID] else { continue }
            let membership: RecordMembership?
            if collection.selectionPolicy == .manual {
                guard let manualMembershipID else { continue }
                membership = graphState.membershipsByID[manualMembershipID].flatMap {
                    $0.collectionID == collectionID && $0.state == .active ? $0 : nil
                }
            } else {
                let candidates = graphState.membershipIDsByCollectionID[collectionID, default: []]
                    .compactMap { graphState.membershipsByID[$0] }
                    .filter { $0.state == .active && !leasedMembershipIDs.contains($0.id) }
                switch collection.selectionPolicy {
                case .newestFirst: membership = candidates.max { $0.ordinal < $1.ordinal }
                case .oldestFirst: membership = candidates.min { $0.ordinal < $1.ordinal }
                case .manual: membership = nil
                }
            }
            guard let membership,
                  !leasedMembershipIDs.contains(membership.id),
                  let record = try await materializedRecord(membership.recordID),
                  graphState.membershipsByID[membership.id] == membership,
                  !leasedMembershipIDs.contains(membership.id)
            else { continue }
            let leaseID = UUID()
            leasesByID[leaseID] = LeaseState(
                membershipID: membership.id,
                expectedRevision: membership.revision,
                consumptionPolicy: collection.consumptionPolicy,
                sink: sink
            )
            leasedMembershipIDs.insert(membership.id)
            return RecordDeliveryLease(
                id: leaseID,
                record: record,
                membership: membership,
                consumptionPolicy: collection.consumptionPolicy,
                sink: sink
            )
        }
        if manualMembershipID != nil { throw RecordStoreError.membershipUnavailable }
        if sourceCollectionIDs.contains(where: { graphState.collectionsByID[$0]?.selectionPolicy == .manual }) {
            throw RecordStoreError.manualSelectionRequired
        }
        throw RecordStoreError.membershipUnavailable
    }

    public func beginDelivery(
        matching subject: RecordDeliverySubject,
        sink: RecordSinkIdentity
    ) async throws -> RecordDeliveryLease {
        try await ensureInitialized()
        guard let membership = graphState.membershipsByID[subject.membershipID],
              let record = try await materializedRecord(subject.recordID),
              graphState.membershipsByID[membership.id] == membership
        else { throw RecordStoreError.membershipUnavailable }
        guard membership.recordID == subject.recordID,
              membership.collectionID == subject.collectionID,
              membership.revision == subject.membershipRevision,
              membership.state == .active,
              record.payload.kind == subject.payloadKind,
              record.provenance.captureTags == subject.captureTags
        else { throw RecordStoreError.membershipChanged }
        guard !leasedMembershipIDs.contains(membership.id) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        guard let collection = graphState.collectionsByID[membership.collectionID] else {
            throw RecordStoreError.collectionUnavailable
        }
        let leaseID = UUID()
        leasesByID[leaseID] = LeaseState(
            membershipID: membership.id,
            expectedRevision: membership.revision,
            consumptionPolicy: collection.consumptionPolicy,
            sink: sink
        )
        leasedMembershipIDs.insert(membership.id)
        return RecordDeliveryLease(
            id: leaseID,
            record: record,
            membership: membership,
            consumptionPolicy: collection.consumptionPolicy,
            sink: sink
        )
    }

    @discardableResult
    public func captureSystemClipboard(
        snapshot: SystemClipboardSnapshot,
        sourceApplication: FocusedApplicationIdentity,
        allowsWorkflowCapture: Bool
    ) async throws -> RecordProjection {
        let payload: RecordPayload
        if let image = snapshot.imagePNGData {
            payload = .image(image)
        } else if !snapshot.fileURLs.isEmpty {
            payload = .files(snapshot.fileURLs)
        } else {
            payload = .text(snapshot.plainText)
        }
        var captureTags = snapshot.captureTags
        if !allowsWorkflowCapture, !captureTags.contains(.excludeFromWorkflowCapture) {
            captureTags.append(.excludeFromWorkflowCapture)
        }
        let envelope = RecordCaptureEnvelope(
            draft: RecordDraft(
                payload: payload,
                provenance: RecordProvenance(
                    source: RecordSourceIdentity(kind: .systemClipboard),
                    sourceApplicationName: sourceApplication.applicationName,
                    sourceBundleIdentifier: sourceApplication.bundleIdentifier,
                    captureTags: captureTags
                )
            )
        )
        let destinations = try await routedCaptureDestinations(for: envelope)
        return try await ingest(envelope.draft, into: destinations)
    }

    public func completeDelivery(
        leaseID: UUID,
        receipt: RecordDeliveryReceipt? = nil,
        deliveredAt: Date = Date()
    ) async throws -> RecordDeliveryReceipt {
        try await ensureInitialized()
        if let reuse = reuseLeases[leaseID] {
            guard receipt == nil, settlingLeaseIDs.insert(leaseID).inserted else { throw RecordStoreError.invalidDeliveryReceipt }
            defer { settlingLeaseIDs.remove(leaseID) }
            guard var activity = graphState.activityByRecordID[reuse.record.id] else { throw RecordStoreError.recordUnavailable }
            activity.recordDelivery(at: deliveredAt)
            markCatalogChange(.activity, id: reuse.record.id)
            graphState.activityByRecordID[reuse.record.id] = activity
            noteMutation()
            try await persistCurrentGraph()
            reuseLeases.removeValue(forKey: leaseID)
            return RecordDeliveryReceipt(recordID: reuse.record.id, membershipID: nil, sink: reuse.sink, deliveredAt: deliveredAt)
        }
        guard let lease = leasesByID[leaseID],
              var membership = graphState.membershipsByID[lease.membershipID]
        else { throw RecordStoreError.membershipUnavailable }
        guard settlingLeaseIDs.insert(leaseID).inserted else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        defer { settlingLeaseIDs.remove(leaseID) }
        if let receipt {
            guard receipt.recordID == membership.recordID,
                  receipt.membershipID == membership.id,
                  receipt.sink == lease.sink
            else { throw RecordStoreError.invalidDeliveryReceipt }
        }
        guard membership.revision == lease.expectedRevision else {
            throw RecordStoreError.membershipChanged
        }
        guard var activity = graphState.activityByRecordID[membership.recordID] else {
            throw RecordStoreError.invalidGraph
        }
        if lease.consumptionPolicy == .consumeAfterSuccessfulDelivery {
            membership.setState(.consumed)
            markCatalogChange(.membership, id: membership.id)
            graphState.membershipsByID[membership.id] = membership
        }
        let completedAt = receipt?.deliveredAt ?? deliveredAt
        activity.recordDelivery(at: completedAt)
        markCatalogChange(.activity, id: membership.recordID)
        graphState.activityByRecordID[membership.recordID] = activity
        noteMutation()
        try await persistCurrentGraph()
        releaseDeliveryLease(leaseID, lease: lease)
        return receipt ?? RecordDeliveryReceipt(
            recordID: membership.recordID,
            membershipID: membership.id,
            sink: lease.sink,
            deliveredAt: completedAt
        )
    }

    public func failDelivery(
        leaseID: UUID,
        failure: RecordDeliveryFailureCode = .deliveryFailed
    ) async throws {
        try await ensureInitialized()
        if let reuse = reuseLeases[leaseID] {
            guard !settlingLeaseIDs.contains(leaseID) else { throw RecordStoreError.membershipAlreadyInUse }
            defer { reuseLeases.removeValue(forKey: leaseID) }
            if var activity = graphState.activityByRecordID[reuse.record.id] {
                activity.recordFailure(failure)
                markCatalogChange(.activity, id: reuse.record.id)
                graphState.activityByRecordID[reuse.record.id] = activity
                noteMutation()
                try await persistCurrentGraph()
            }
            return
        }
        guard let lease = leasesByID[leaseID],
              let membership = graphState.membershipsByID[lease.membershipID]
        else { throw RecordStoreError.membershipUnavailable }
        guard settlingLeaseIDs.insert(leaseID).inserted else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        defer { settlingLeaseIDs.remove(leaseID) }
        guard membership.revision == lease.expectedRevision else {
            releaseDeliveryLease(leaseID, lease: lease)
            throw RecordStoreError.membershipChanged
        }
        guard var activity = graphState.activityByRecordID[membership.recordID] else {
            releaseDeliveryLease(leaseID, lease: lease)
            throw RecordStoreError.invalidGraph
        }
        activity.recordFailure(failure)
        markCatalogChange(.activity, id: membership.recordID)
        graphState.activityByRecordID[membership.recordID] = activity
        noteMutation()
        try await persistCurrentGraph()
        releaseDeliveryLease(leaseID, lease: lease)
    }

    /// Releases a reservation without recording a sink failure. A user
    /// cancellation leaves the membership and RecordActivity unchanged.
    public func cancelDelivery(leaseID: UUID) async throws {
        try await ensureInitialized()
        guard !settlingLeaseIDs.contains(leaseID) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        if reuseLeases.removeValue(forKey: leaseID) != nil { return }
        guard let lease = leasesByID.removeValue(forKey: leaseID),
              let membership = graphState.membershipsByID[lease.membershipID]
        else { throw RecordStoreError.membershipUnavailable }
        leasedMembershipIDs.remove(lease.membershipID)
        guard membership.revision == lease.expectedRevision else {
            throw RecordStoreError.membershipChanged
        }
    }

    private func releaseDeliveryLease(_ leaseID: UUID, lease: LeaseState) {
        leasesByID.removeValue(forKey: leaseID)
        leasedMembershipIDs.remove(lease.membershipID)
    }

    public func isProtectedFromRetention(_ recordID: RecordID) async throws -> Bool {
        try await ensureInitialized()
        guard let metadata = graphState.metadataByRecordID[recordID] else {
            throw RecordStoreError.recordUnavailable
        }
        return metadata.isPinned || graphState.membershipIDsByRecordID[recordID, default: []].contains {
            graphState.membershipsByID[$0]?.state == .active
        }
    }

    private func addMembershipWithoutPersistence(
        recordID: RecordID,
        collectionID: RecordCollectionID
    ) throws -> RecordMembership {
        guard graphState.recordsByID[recordID] != nil else { throw RecordStoreError.recordUnavailable }
        guard graphState.collectionsByID[collectionID] != nil else { throw RecordStoreError.collectionUnavailable }
        if let existing = graphState.membershipIDsByRecordID[recordID, default: []]
            .compactMap({ graphState.membershipsByID[$0] })
            .first(where: { $0.collectionID == collectionID }) {
            return existing
        }
        guard graphState.membershipIDsByRecordID[recordID, default: []].count
                < RecordGraphLimits.maximumMembershipsPerRecord,
              graphState.membershipsByID.count < RecordGraphLimits.maximumMemberships
        else { throw RecordStoreError.membershipLimitReached }
        let membership = RecordMembership(
            recordID: recordID,
            collectionID: collectionID,
            ordinal: graphState.nextMembershipOrdinal
        )
        graphState.nextMembershipOrdinal = graphState.nextMembershipOrdinal == .max ? 1 : graphState.nextMembershipOrdinal + 1
        markCatalogChange(.membership, id: membership.id)
        graphState.membershipsByID[membership.id] = membership
        graphState.membershipIDsByRecordID[recordID, default: []].append(membership.id)
        graphState.membershipIDsByCollectionID[collectionID, default: []].append(membership.id)
        sortCollectionMemberships(collectionID)
        return membership
    }

    private func removeMembershipWithoutPersistence(_ membershipID: RecordMembershipID) {
        markCatalogChange(.membership, id: membershipID)
        guard let membership = graphState.membershipsByID.removeValue(forKey: membershipID) else { return }
        graphState.membershipIDsByRecordID[membership.recordID]?.removeAll { $0 == membershipID }
        graphState.membershipIDsByCollectionID[membership.collectionID]?.removeAll { $0 == membershipID }
    }

    private func sortCollectionMemberships(_ collectionID: RecordCollectionID) {
        graphState.membershipIDsByCollectionID[collectionID] = graphState.membershipIDsByCollectionID[collectionID]?.sorted {
            (graphState.membershipsByID[$0]?.ordinal ?? 0) < (graphState.membershipsByID[$1]?.ordinal ?? 0)
        }
    }

    private func activeMemberships(in collectionID: RecordCollectionID) -> [RecordMembership] {
        graphState.membershipIDsByCollectionID[collectionID, default: []]
            .compactMap { graphState.membershipsByID[$0] }
            .filter { $0.state == .active && !leasedMembershipIDs.contains($0.id) }
    }

    private func selectedMembership(
        from candidates: [RecordMembership],
        policy: RecordSelectionPolicy
    ) -> RecordMembership? {
        switch policy {
        case .newestFirst: candidates.max { $0.ordinal < $1.ordinal }
        case .oldestFirst: candidates.min { $0.ordinal < $1.ordinal }
        case .manual: nil
        }
    }

    private func deliverySubject(
        record: Record,
        membership: RecordMembership
    ) -> RecordDeliverySubject {
        RecordDeliverySubject(
            recordID: record.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: record.payload.kind,
            captureTags: record.provenance.captureTags
        )
    }

    private func projection(for recordID: RecordID) async throws -> RecordProjection? {
        guard let record = try await materializedRecord(recordID),
              let metadata = graphState.metadataByRecordID[recordID], let activity = graphState.activityByRecordID[recordID]
        else { return nil }
        return RecordProjection(record: record, metadata: metadata, activity: activity,
                                memberships: graphState.membershipIDsByRecordID[recordID, default: []].compactMap { graphState.membershipsByID[$0] })
    }

    private func summary(for recordID: RecordID) -> RecordSummary? {
        guard let header = graphState.recordsByID[recordID], let metadata = graphState.metadataByRecordID[recordID],
              let activity = graphState.activityByRecordID[recordID] else { return nil }
        return RecordSummary(header: header, metadata: metadata, activity: activity,
                             memberships: graphState.membershipIDsByRecordID[recordID, default: []].compactMap { graphState.membershipsByID[$0] })
    }

    private func makeCatalogSnapshot() -> RecordCatalogSnapshot {
        RecordCatalogSnapshot(revision: graphState.revision, records: graphState.recordOrder.compactMap(summary),
                              collections: graphState.collectionOrder.compactMap { graphState.collectionsByID[$0] },
                              captureRules: graphState.captureRules, deliveryRules: graphState.deliveryRules,
                              capacity: RecordCapacity(count: graphState.recordsByID.count, byteCount: totalPayloadByteCount(), limits: storageLimits, admissionWasLimited: admissionWasLimited))
    }

    private func noteMutation() {
        graphState.revision = graphState.revision == .max ? 1 : graphState.revision + 1
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func publishSnapshotToObservers() {
        let snapshot = makeCatalogSnapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func restoreCommittedGraphState(_ state: GraphState) {
        graphState = state
        dirtyCatalogIDs.removeAll(keepingCapacity: true)
        trimPayloadCache()
        publishSnapshotToObservers()
    }

    private func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        stableUnique(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func activeMembershipCount(in collectionID: RecordCollectionID) -> Int {
        graphState.membershipIDsByCollectionID[collectionID, default: []].reduce(into: 0) { count, membershipID in
            if graphState.membershipsByID[membershipID]?.state == .active { count += 1 }
        }
    }

    private func hasActiveMembership(recordID: RecordID) -> Bool {
        graphState.membershipIDsByRecordID[recordID, default: []].contains {
            graphState.membershipsByID[$0]?.state == .active
        }
    }

    private func activeRecordCount() -> Int {
        graphState.recordsByID.keys.reduce(into: 0) { count, recordID in
            if hasActiveMembership(recordID: recordID) { count += 1 }
        }
    }

    private func historyOnlyRecordCount() -> Int {
        graphState.recordsByID.count - activeRecordCount()
    }

    private func validateRecordAdmission(
        payload: RecordPayload,
        tags: [String],
        activeRecordDelta: Int,
        historyOnlyRecordDelta: Int
    ) throws {
        guard graphState.recordsByID.count < storageLimits.maximumRecordCount,
              activeRecordCount() + activeRecordDelta <= storageLimits.maximumActiveRecordCount,
              historyOnlyRecordCount() + historyOnlyRecordDelta
                <= storageLimits.maximumHistoryOnlyRecordCount
        else {
            admissionWasLimited = true
            publishSnapshotToObservers()
            throw RecordStoreError.recordLimitReached
        }
        _ = try validatedPayloadByteCount(payload)
        let payloadBytes = try encodedPayload(payload).count
        guard totalPayloadByteCount() <= storageLimits.maximumTotalPayloadByteCount - payloadBytes else {
            admissionWasLimited = true
            publishSnapshotToObservers()
            throw RecordStoreError.totalPayloadLimitReached
        }
        try validateTags(normalizedTags(tags))
    }

    private func validateTags(_ tags: [String]) throws {
        guard tags.count <= storageLimits.maximumTagCount,
              tags.allSatisfy({ $0.utf8.count <= storageLimits.maximumTagUTF8ByteCount }),
              tags.reduce(0, { $0 + $1.utf8.count }) <= storageLimits.maximumTotalTagUTF8ByteCount
        else { throw RecordStoreError.payloadLimitReached }
    }

    private func totalPayloadByteCount() -> Int {
        graphState.recordsByID.values.reduce(0) { $0 + $1.byteCount }
    }

    private func validatedPayloadByteCount(_ payload: RecordPayload) throws -> Int {
        switch payload {
        case .text(let text):
            let count = text.utf8.count
            guard count <= storageLimits.maximumTextUTF8ByteCount else {
                throw RecordStoreError.payloadLimitReached
            }
            return count
        case .image(let data):
            guard !data.isEmpty, data.count <= storageLimits.maximumImageByteCount else {
                throw RecordStoreError.payloadLimitReached
            }
            return data.count
        case .files(let urls):
            let byteCounts = urls.map { $0.absoluteString.utf8.count }
            guard !urls.isEmpty,
                  urls.count <= storageLimits.maximumFileURLCount,
                  byteCounts.allSatisfy({ $0 <= storageLimits.maximumFileURLUTF8ByteCount }),
                  byteCounts.reduce(0, +) <= storageLimits.maximumTotalFileURLUTF8ByteCount
            else { throw RecordStoreError.payloadLimitReached }
            return byteCounts.reduce(0, +)
        }
    }
}

extension RecordStore {
    private func loadPersistedGraph() async {
        guard let persistence else { return }
        do {
            if let catalogStore = persistence as? any RecordCatalogPersistenceStore,
               let catalog = try await catalogStore.loadRecordCatalog() {
                try installCatalog(catalog)
                hasCatalogPersistence = true
                return
            }
            switch try await persistence.loadRecordGraph() {
            case .empty:
                return
            case .legacyClipboard(let metadata, let imageBlobs):
                let migrated = try LegacyClipboardMigration.decodeAndMigrate(
                    metadata: metadata,
                    imageBlobs: imageBlobs
                )
                try install(migrated)
                graphState.repositoryRevision = nil
                graphState.durableBlobReferencesByRecordID = [:]
                try await persistCurrentGraph()
            case .current(let storedRevision, let graph, let payloadBlobs):
                guard storedRevision > 0 else { throw RecordStoreError.invalidGraph }
                let persisted = try decoder.decode(PersistedGraph.self, from: graph)
                guard persisted.schemaVersion == PersistedGraph.schemaVersion else {
                    throw RecordStoreError.invalidGraph
                }
                let records = try materializeRecords(persisted.records, payloadBlobs: payloadBlobs)
                try install(
                    LegacyClipboardMigration.MigratedGraph(
                        records: records,
                        metadata: persisted.metadata,
                        activity: persisted.activity,
                        collections: persisted.collections,
                        memberships: persisted.memberships,
                        captureRules: persisted.captureRules,
                        deliveryRules: persisted.deliveryRules,
                        nextMembershipOrdinal: persisted.nextMembershipOrdinal
                    )
                )
                graphState.repositoryRevision = storedRevision
                graphState.durableBlobReferencesByRecordID = Dictionary(
                    uniqueKeysWithValues: persisted.records.map { ($0.id, $0.payloadBlob) }
                )
                if persistence is any RecordCatalogPersistenceStore {
                    committedGraphState = graphState
                    try await persistCurrentGraph()
                }
            }
        } catch {
            initializationError = .persistenceUnavailable
        }
    }

    private struct InstalledGraph {
        var records: [RecordHeader]
        var metadata: [RecordMetadata]
        var activity: [RecordActivity]
        var collections: [RecordCollection]
        var memberships: [RecordMembership]
        var captureRules: [CaptureRouteRule]
        var deliveryRules: [DeliveryRouteRule]
        var nextMembershipOrdinal: UInt64
    }

    private func install(_ legacy: LegacyClipboardMigration.MigratedGraph) throws {
        let headers = try legacy.records.map { RecordHeader(record: $0, byteCount: try encodedPayload($0.payload).count) }
        try install(InstalledGraph(records: headers, metadata: legacy.metadata, activity: legacy.activity,
                                   collections: legacy.collections, memberships: legacy.memberships,
                                   captureRules: legacy.captureRules, deliveryRules: legacy.deliveryRules,
                                   nextMembershipOrdinal: legacy.nextMembershipOrdinal))
        for record in legacy.records { cachePayload(record.payload, for: record.id) }
    }

    private func install(_ graph: InstalledGraph) throws {
        let recordIDs = Set(graph.records.map(\.id))
        let collectionIDs = Set(graph.collections.map(\.id))
        guard graph.records.count == recordIDs.count,
              graph.records.count <= storageLimits.maximumRecordCount,
              graph.metadata.count == graph.records.count,
              Set(graph.metadata.map(\.recordID)) == recordIDs,
              graph.activity.count == graph.records.count,
              Set(graph.activity.map(\.recordID)) == recordIDs,
              graph.collections.count == collectionIDs.count,
              graph.collections.count <= storageLimits.maximumCollectionCount,
              graph.collections.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.name.utf8.count <= storageLimits.maximumCollectionNameUTF8ByteCount
              }),
              graph.memberships.count <= RecordGraphLimits.maximumMemberships,
              graph.memberships.count == Set(graph.memberships.map(\.id)).count,
              graph.nextMembershipOrdinal > 0,
              graph.memberships.allSatisfy({ $0.ordinal > 0 && $0.ordinal < .max }),
              graph.memberships.count == Set(graph.memberships.map(\.ordinal)).count,
              graph.memberships.allSatisfy({ membership in
                  recordIDs.contains(membership.recordID)
                    && collectionIDs.contains(membership.collectionID)
              }),
              graph.captureRules.count <= storageLimits.maximumCaptureRouteCount,
              graph.captureRules.count == Set(graph.captureRules.map(\.id)).count,
              graph.captureRules.allSatisfy({ rule in
                  rule.destinationCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections
                    && stableUnique(rule.destinationCollectionIDs) == rule.destinationCollectionIDs
                    && rule.destinationCollectionIDs.allSatisfy(collectionIDs.contains)
              }),
              graph.deliveryRules.count <= storageLimits.maximumDeliveryRouteCount,
              graph.deliveryRules.count == Set(graph.deliveryRules.map(\.id)).count,
              graph.deliveryRules.allSatisfy({ rule in
                  rule.sourceCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections
                    && stableUnique(rule.sourceCollectionIDs) == rule.sourceCollectionIDs
                    && rule.sourceCollectionIDs.allSatisfy(collectionIDs.contains)
                    && (rule.sink != .recordCollection
                        ? rule.sinkCollectionID == nil
                        : rule.sinkCollectionID.map(collectionIDs.contains) == true)
              })
        else { throw RecordStoreError.invalidGraph }
        let membershipCounts = Dictionary(grouping: graph.memberships, by: \.recordID).mapValues(\.count)
        guard membershipCounts.values.allSatisfy({ $0 <= RecordGraphLimits.maximumMembershipsPerRecord }) else {
            throw RecordStoreError.invalidGraph
        }
        let activeMemberships = graph.memberships.filter { $0.state == .active }
        let activeRecordIDs = Set(activeMemberships.map(\.recordID))
        let activeMembershipCounts = Dictionary(grouping: activeMemberships, by: \.collectionID)
            .mapValues(\.count)
        guard activeRecordIDs.count <= storageLimits.maximumActiveRecordCount,
              graph.records.count - activeRecordIDs.count
                <= storageLimits.maximumHistoryOnlyRecordCount,
              activeMembershipCounts.values.allSatisfy({
                  $0 <= storageLimits.maximumActiveMembershipCountPerCollection
              })
        else { throw RecordStoreError.invalidGraph }
        var payloadByteCount = 0
        for record in graph.records {
            payloadByteCount += record.byteCount
            guard payloadByteCount <= storageLimits.maximumTotalPayloadByteCount else {
                throw RecordStoreError.invalidGraph
            }
        }
        for metadata in graph.metadata {
            try validateTags(metadata.tags)
        }
        graphState.recordsByID = Dictionary(uniqueKeysWithValues: graph.records.map { ($0.id, $0) })
        graphState.recordOrder = graph.records.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        graphState.metadataByRecordID = Dictionary(uniqueKeysWithValues: graph.metadata.map { ($0.recordID, $0) })
        graphState.activityByRecordID = Dictionary(uniqueKeysWithValues: graph.activity.map { ($0.recordID, $0) })
        graphState.collectionsByID = Dictionary(uniqueKeysWithValues: graph.collections.map { ($0.id, $0) })
        graphState.collectionOrder = graph.collections.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        graphState.membershipsByID = Dictionary(uniqueKeysWithValues: graph.memberships.map { ($0.id, $0) })
        graphState.membershipIDsByRecordID = Dictionary(grouping: graph.memberships, by: \.recordID)
            .mapValues { $0.sorted { $0.ordinal < $1.ordinal }.map(\.id) }
        graphState.membershipIDsByCollectionID = Dictionary(grouping: graph.memberships, by: \.collectionID)
            .mapValues { $0.sorted { $0.ordinal < $1.ordinal }.map(\.id) }
        for recordID in graphState.recordsByID.keys where graphState.membershipIDsByRecordID[recordID] == nil {
            graphState.membershipIDsByRecordID[recordID] = []
        }
        for collectionID in graphState.collectionsByID.keys where graphState.membershipIDsByCollectionID[collectionID] == nil {
            graphState.membershipIDsByCollectionID[collectionID] = []
        }
        graphState.captureRules = graph.captureRules
        graphState.deliveryRules = graph.deliveryRules
        let maximumOrdinal = graph.memberships.map(\.ordinal).max() ?? 0
        graphState.nextMembershipOrdinal = max(graph.nextMembershipOrdinal, maximumOrdinal + 1)
        graphState.revision = 1
    }

    private func persistCurrentGraph() async throws {
        precondition(!isPersistingGraph, "Record graph writes must be serialized.")
        isPersistingGraph = true
        defer { finishGraphPersistence() }
        let rollbackState = committedGraphState
        guard let persistence else {
            if let rollbackState, graphState.recordsByID.count < rollbackState.recordsByID.count { admissionWasLimited = false }
            trimPayloadCache()
            committedGraphState = graphState
            publishSnapshotToObservers()
            return
        }
        do {
            if let catalogStore = persistence as? any RecordCatalogPersistenceStore {
                let prepared = try prepareCatalogMutation()
                graphState.repositoryRevision = try await catalogStore.commitRecordCatalog(prepared.mutation)
                graphState.durableBlobReferencesByRecordID = prepared.references
                hasCatalogPersistence = true
            } else {
                let prepared = try preparePersistenceWrite()
                graphState.repositoryRevision = try await persistence.replaceRecordGraph(with: prepared.snapshot)
                graphState.durableBlobReferencesByRecordID = prepared.referencesByRecordID
            }
            trimPayloadCache()
            committedGraphState = graphState
            if let rollbackState, graphState.recordsByID.count < rollbackState.recordsByID.count { admissionWasLimited = false }
            publishSnapshotToObservers()
        } catch {
            if let rollbackState {
                restoreCommittedGraphState(rollbackState)
            }
            throw RecordStoreError.persistenceUnavailable
        }
    }

    private func waitForGraphPersistence() async {
        while isPersistingGraph {
            await withCheckedContinuation { continuation in
                graphPersistenceWaiters.append(continuation)
            }
        }
    }

    private func finishGraphPersistence() {
        guard isPersistingGraph else { return }
        isPersistingGraph = false
        let waiters = graphPersistenceWaiters
        graphPersistenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private struct PreparedPersistenceWrite {
        let snapshot: RecordGraphPersistenceWriteSnapshot
        let referencesByRecordID: [RecordID: RecordGraphPersistenceBlobReference]
    }

    private func preparePersistenceWrite() throws -> PreparedPersistenceWrite {
        var persistedRecords: [PersistedGraph.PersistedRecord] = []
        var newBlobs: [RecordGraphPersistenceBlob] = []
        var retained: [RecordGraphPersistenceBlobReference] = []
        var referencesByRecordID: [RecordID: RecordGraphPersistenceBlobReference] = [:]
        for recordID in graphState.recordOrder {
            guard let record = graphState.recordsByID[recordID] else { throw RecordStoreError.invalidGraph }
            let reference: RecordGraphPersistenceBlobReference
            if let durable = graphState.durableBlobReferencesByRecordID[recordID] {
                reference = durable
                retained.append(durable)
            } else {
                guard let content = payloadCache[record.id] else { throw RecordStoreError.recordUnavailable }
                let payload = try encodedPayload(content)
                reference = RecordGraphPersistenceBlobReference(
                    blobID: UUID(),
                    recordID: record.id,
                    kind: record.kind,
                    byteCount: payload.count
                )
                newBlobs.append(RecordGraphPersistenceBlob(reference: reference, payload: payload))
            }
            referencesByRecordID[recordID] = reference
            persistedRecords.append(
                PersistedGraph.PersistedRecord(
                    id: record.id,
                    payloadKind: record.kind,
                    payloadBlob: reference,
                    provenance: record.provenance,
                    createdAt: record.createdAt
                )
            )
        }
        let graph = PersistedGraph(
            schemaVersion: PersistedGraph.schemaVersion,
            records: persistedRecords,
            metadata: graphState.recordOrder.compactMap { graphState.metadataByRecordID[$0] },
            activity: graphState.recordOrder.compactMap { graphState.activityByRecordID[$0] },
            collections: graphState.collectionOrder.compactMap { graphState.collectionsByID[$0] },
            memberships: graphState.membershipsByID.values.sorted { $0.ordinal < $1.ordinal },
            captureRules: graphState.captureRules,
            deliveryRules: graphState.deliveryRules,
            nextMembershipOrdinal: graphState.nextMembershipOrdinal
        )
        return PreparedPersistenceWrite(
            snapshot: RecordGraphPersistenceWriteSnapshot(
                expectedRevision: graphState.repositoryRevision,
                graph: try encoder.encode(graph),
                newPayloadBlobs: newBlobs,
                retainedPayloadBlobReferences: retained
            ),
            referencesByRecordID: referencesByRecordID
        )
    }

    private func materializeRecords(
        _ persistedRecords: [PersistedGraph.PersistedRecord],
        payloadBlobs: [RecordGraphPersistenceBlob]
    ) throws -> [Record] {
        let blobsByID = Dictionary(uniqueKeysWithValues: payloadBlobs.map { ($0.reference.blobID, $0) })
        guard blobsByID.count == persistedRecords.count else { throw RecordStoreError.invalidGraph }
        return try persistedRecords.map { persisted in
            guard let blob = blobsByID[persisted.payloadBlob.blobID],
                  blob.reference == persisted.payloadBlob,
                  blob.reference.recordID == persisted.id,
                  blob.reference.kind == persisted.payloadKind,
                  blob.payload.count == blob.reference.byteCount
            else { throw RecordStoreError.invalidGraph }
            return Record(
                id: persisted.id,
                payload: try decodedPayload(blob.payload, kind: persisted.payloadKind),
                provenance: persisted.provenance,
                createdAt: persisted.createdAt
            )
        }
    }

    private func encodedPayload(_ payload: RecordPayload) throws -> Data {
        switch payload {
        case .text(let text): Data(text.utf8)
        case .image(let data): data
        case .files(let urls): try encoder.encode(urls)
        }
    }

    private func decodedPayload(_ data: Data, kind: RecordPayloadKind) throws -> RecordPayload {
        switch kind {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                throw RecordStoreError.invalidGraph
            }
            return .text(text)
        case .image: return .image(data)
        case .files: return .files(try decoder.decode([URL].self, from: data))
        }
    }
}

private extension RecordStore {
    func collectionEvent(
        _ kind: RecordCollectionEventKind,
        membership: RecordMembership,
        record: Record
    ) -> RecordCollectionEventDescriptor {
        RecordCollectionEventDescriptor(
            kind: kind,
            collectionID: membership.collectionID,
            recordID: record.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            storeRevision: graphState.revision,
            captureTags: record.provenance.captureTags
        )
    }

    func collectionEvent(
        _ kind: RecordCollectionEventKind,
        membership: RecordMembership,
        record: RecordHeader
    ) -> RecordCollectionEventDescriptor {
        RecordCollectionEventDescriptor(kind: kind, collectionID: membership.collectionID, recordID: record.id,
                                        membershipID: membership.id, membershipRevision: membership.revision,
                                        storeRevision: graphState.revision, captureTags: record.provenance.captureTags)
    }

    func publishCollectionEvents(_ descriptors: [RecordCollectionEventDescriptor]) async {
        guard let collectionEventSink else { return }
        for descriptor in descriptors {
            _ = await collectionEventSink.submit(descriptor)
        }
    }
}

extension RecordStore {
    // Compatibility with pending maintenance from older versions: the Record
    // domain no longer deletes from a time range without a confirmed plan.
    public func pruneHistory(olderThan cutoff: Date) async throws -> RecordCleanupResult {
        let plan = try await prepareCleanup(olderThan: cutoff)
        return RecordCleanupResult(removedCount: 0, preservedActiveCount: plan.protectedCount)
    }

    public func clearHistory(through upperBound: Date) async throws -> RecordCleanupResult {
        try await pruneHistory(olderThan: upperBound)
    }

}

private extension RecordStore {
    func materializedRecord(_ id: RecordID) async throws -> Record? {
        guard let header = graphState.recordsByID[id] else { return nil }
        if let payload = payloadCache[id] { return header.materialize(payload) }
        guard let repository = persistence as? any RecordCatalogPersistenceStore,
              let reference = graphState.durableBlobReferencesByRecordID[id] else {
            throw RecordStoreError.persistenceUnavailable
        }
        let data = try await repository.loadRecordPayload(reference)
        await waitForGraphPersistence()
        guard graphState.recordsByID[id] == header, graphState.durableBlobReferencesByRecordID[id] == reference else {
            throw RecordStoreError.recordUnavailable
        }
        let payload = try decodedPayload(data, kind: header.kind)
        _ = try validatedPayloadByteCount(payload)
        cachePayload(payload, for: id)
        evictPayloadsOverBudget()
        return header.materialize(payload)
    }

    func cachePayload(_ payload: RecordPayload, for id: RecordID) {
        if payloadCache[id] == nil {
            payloadCacheOrder.append(id)
            payloadCacheBytes += graphState.recordsByID[id]?.byteCount ?? 0
        }
        payloadCache[id] = payload
    }

    func trimPayloadCache() {
        searchCacheOrder.removeAll { graphState.recordsByID[$0] == nil }
        searchCache = searchCache.filter { graphState.recordsByID[$0.key] != nil }
        searchCacheBytes = searchCache.values.reduce(0) { $0 + $1.byteCount }
        payloadCacheOrder.removeAll { graphState.recordsByID[$0] == nil }
        payloadCache = payloadCache.filter { graphState.recordsByID[$0.key] != nil }
        payloadCacheBytes = payloadCache.keys.reduce(0) { $0 + (graphState.recordsByID[$1]?.byteCount ?? 0) }
        evictPayloadsOverBudget()
    }

    func evictPayloadsOverBudget() {
        guard persistence is any RecordCatalogPersistenceStore else { return }
        while payloadCacheBytes > 64 * 1_024 * 1_024,
              let index = payloadCacheOrder.firstIndex(where: { graphState.durableBlobReferencesByRecordID[$0] != nil }) {
            let id = payloadCacheOrder.remove(at: index)
            payloadCache.removeValue(forKey: id)
            payloadCacheBytes -= graphState.recordsByID[id]?.byteCount ?? 0
        }
    }

    func installCatalog(_ catalog: RecordCatalogRead) throws {
        func values<T: Decodable>(_ kind: RecordCatalogNode.Kind, _ type: T.Type, id: (T) -> String) throws -> [T] {
            try catalog.nodes.filter { $0.kind == kind }.map { node in
                let value = try decoder.decode(type, from: node.value)
                guard id(value) == node.id else { throw RecordStoreError.invalidGraph }
                return value
            }
        }
        let headers = try values(.record, RecordHeader.self, id: { $0.id.description })
        guard catalog.manifest.schemaVersion == 2, catalog.revision > 0,
              Set(catalog.nodes.map(\.key)).count == catalog.nodes.count,
              catalog.references.count == headers.count,
              Set(catalog.references.map(\.recordID)).count == headers.count,
              Set(catalog.manifest.recordOrder) == Set(headers.map(\.id)),
              catalog.manifest.recordOrder.count == headers.count
        else { throw RecordStoreError.invalidGraph }
        let references = Dictionary(uniqueKeysWithValues: catalog.references.map { ($0.recordID, $0) })
        for header in headers {
            guard let reference = references[header.id], reference.kind == header.kind,
                  reference.byteCount == header.byteCount, header.byteCount > 0,
                  header.preview.utf8.count <= 4_096 else { throw RecordStoreError.invalidGraph }
        }
        try install(InstalledGraph(
            records: headers,
            metadata: try values(.metadata, RecordMetadata.self, id: { $0.recordID.description }),
            activity: try values(.activity, RecordActivity.self, id: { $0.recordID.description }),
            collections: try values(.collection, RecordCollection.self, id: { $0.id.description }),
            memberships: try values(.membership, RecordMembership.self, id: { $0.id.description }),
            captureRules: try values(.captureRule, CaptureRouteRule.self, id: { $0.id.description }),
            deliveryRules: try values(.deliveryRule, DeliveryRouteRule.self, id: { $0.id.description }),
            nextMembershipOrdinal: catalog.manifest.nextMembershipOrdinal
        ))
        guard Set(catalog.manifest.collectionOrder) == Set(graphState.collectionOrder),
              catalog.manifest.collectionOrder.count == graphState.collectionOrder.count else { throw RecordStoreError.invalidGraph }
        graphState.recordOrder = catalog.manifest.recordOrder
        graphState.collectionOrder = catalog.manifest.collectionOrder
        graphState.repositoryRevision = catalog.revision
        graphState.durableBlobReferencesByRecordID = references
    }

    private func markCatalogChange<K: RecordIdentifier>(_ kind: RecordCatalogNode.Kind, id: K) {
        dirtyCatalogIDs[kind, default: []].insert(id.rawValue)
    }

    func prepareCatalogMutation() throws -> (mutation: RecordCatalogMutation, references: [RecordID: RecordGraphPersistenceBlobReference]) {
        let old = hasCatalogPersistence ? committedGraphState : nil
        var nodes: [RecordCatalogNode] = []
        var removedKeys: [String] = []
        func changes<K: RecordIdentifier, V: Encodable & Equatable>(
            _ kind: RecordCatalogNode.Kind, _ current: [K: V], _ previous: [K: V]
        ) throws {
            let touched = old == nil ? Set(current.keys).union(previous.keys)
                : Set((dirtyCatalogIDs[kind] ?? []).compactMap(K.init(rawValue:)))
            for id in touched where current[id] != previous[id] {
                if let value = current[id] {
                    nodes.append(RecordCatalogNode(kind: kind, id: id.description, value: try encoder.encode(value)))
                } else { removedKeys.append("\(kind.rawValue)/\(id.description)") }
            }
        }
        try changes(.record, graphState.recordsByID, old?.recordsByID ?? [:])
        try changes(.metadata, graphState.metadataByRecordID, old?.metadataByRecordID ?? [:])
        try changes(.activity, graphState.activityByRecordID, old?.activityByRecordID ?? [:])
        try changes(.membership, graphState.membershipsByID, old?.membershipsByID ?? [:])
        try changes(.collection, graphState.collectionsByID, old?.collectionsByID ?? [:])
        try changes(.captureRule, Dictionary(uniqueKeysWithValues: graphState.captureRules.map { ($0.id, $0) }),
                    Dictionary(uniqueKeysWithValues: (old?.captureRules ?? []).map { ($0.id, $0) }))
        try changes(.deliveryRule, Dictionary(uniqueKeysWithValues: graphState.deliveryRules.map { ($0.id, $0) }),
                    Dictionary(uniqueKeysWithValues: (old?.deliveryRules ?? []).map { ($0.id, $0) }))
        let touchedRecords = old == nil ? Set(graphState.recordOrder)
            : Set((dirtyCatalogIDs[.record] ?? []).map(RecordID.init(rawValue:)))
        var references = graphState.durableBlobReferencesByRecordID
        for id in touchedRecords where graphState.recordsByID[id] == nil { references.removeValue(forKey: id) }
        var blobs: [RecordGraphPersistenceBlob] = []
        for id in touchedRecords where graphState.recordsByID[id] != nil && references[id] == nil {
            guard let header = graphState.recordsByID[id], let payload = payloadCache[id] else { throw RecordStoreError.invalidGraph }
            let data = try encodedPayload(payload)
            let reference = RecordGraphPersistenceBlobReference(blobID: UUID(), recordID: id, kind: header.kind, byteCount: data.count)
            references[id] = reference
            blobs.append(RecordGraphPersistenceBlob(reference: reference, payload: data))
        }
        let removedBlobs = touchedRecords.filter { graphState.recordsByID[$0] == nil }
            .compactMap { committedGraphState?.durableBlobReferencesByRecordID[$0]?.blobID }
        let mutation = RecordCatalogMutation(
            expectedRevision: graphState.repositoryRevision,
            manifest: RecordCatalogManifest(nextMembershipOrdinal: graphState.nextMembershipOrdinal, recordOrder: graphState.recordOrder, collectionOrder: graphState.collectionOrder),
            upserts: nodes, removedKeys: removedKeys, newPayloadBlobs: blobs, removedPayloadBlobIDs: removedBlobs
        )
        return (mutation, references)
    }
}

extension RecordStore {
    public func query(_ query: RecordQuery, offset: Int = 0, limit: Int = 50) async throws -> RecordQueryPage {
        try await ensureInitialized()
        let expectedRevision = graphState.revision
        let ids = graphState.recordOrder
        let matcher = RecordSearchMatcher(query)
        var preparedMetadata: [String: RecordSearchDocument] = [:]
        var results: [RecordSummary] = []
        var index = min(max(0, offset), ids.count)
        let pageSize = min(max(1, limit), 100)
        let batchEnd = min(ids.count, index + 256)
        while index < batchEnd, results.count < pageSize {
            try Task.checkCancellation()
            let id = ids[index]
            index += 1
            if index.isMultiple(of: 32) { await Task.yield(); try Task.checkCancellation() }
            guard let item = summary(for: id),
                  !query.pinnedOnly || item.metadata.isPinned,
                  query.kind == nil || item.header.kind == query.kind,
                  query.sourceBundleIdentifier == nil || item.header.provenance.sourceBundleIdentifier == query.sourceBundleIdentifier,
                  query.collectionID == nil || item.memberships.contains(where: { $0.collectionID == query.collectionID })
            else { continue }
            if !matcher.keywords.isEmpty {
                var metadata = RecordSearchDocument(
                    ([item.header.provenance.sourceApplicationName ?? "", item.header.provenance.sourceBundleIdentifier ?? ""] + item.metadata.tags)
                        .joined(separator: " "))
                if !matcher.matchesLiteral("", metadata: metadata.text) {
                    var content = try await searchableContent(id, kind: item.header.kind)
                    if !matcher.matchesLiteral(content.text, metadata: metadata.text) {
                        guard matcher.canApproximate else { continue }
                        if content.approximation == nil {
                            content = try await content.preparingApproximation()
                            cacheSearchContent(content, for: id)
                        }
                        if let cached = preparedMetadata[metadata.text] {
                            metadata = cached
                        } else {
                            metadata = try await metadata.preparingApproximation()
                            preparedMetadata[metadata.text] = metadata
                        }
                        try Task.checkCancellation()
                        guard graphState.revision == expectedRevision else { throw RecordStoreError.membershipChanged }
                        guard matcher.matches(content, metadata: metadata) else { continue }
                    }
                }
            }
            results.append(item)
        }
        guard graphState.revision == expectedRevision else { throw RecordStoreError.membershipChanged }
        return RecordQueryPage(revision: graphState.revision, records: results, nextOffset: index < ids.count ? index : nil)
    }

    private func searchableContent(_ id: RecordID, kind: RecordPayloadKind) async throws -> RecordSearchDocument {
        if let cached = searchCache[id] { return cached }
        guard kind != .image, let record = try await materializedRecord(id) else { return RecordSearchDocument("") }
        let text: String
        switch record.payload {
        case .text(let value): text = value
        case .files(let urls): text = urls.map(\.lastPathComponent).joined(separator: " ")
        case .image: text = ""
        }
        try Task.checkCancellation()
        let content = RecordSearchDocument(text)
        cacheSearchContent(content, for: id)
        return content
    }

    private func cacheSearchContent(_ content: RecordSearchDocument, for id: RecordID) {
        if let previous = searchCache.removeValue(forKey: id) {
            searchCacheBytes -= previous.byteCount
            if searchCacheOrder.last == id {
                searchCacheOrder.removeLast()
            } else {
                searchCacheOrder.removeAll { $0 == id }
            }
        }
        let bytes = content.byteCount
        let maximumBytes = 16 * 1_024 * 1_024
        guard bytes <= maximumBytes, graphState.recordsByID[id] != nil else { return }
        while searchCacheBytes + bytes > maximumBytes, !searchCacheOrder.isEmpty {
            let evicted = searchCacheOrder.removeFirst()
            searchCacheBytes -= searchCache.removeValue(forKey: evicted)?.byteCount ?? 0
        }
        searchCache[id] = content
        searchCacheOrder.append(id)
        searchCacheBytes += bytes
    }

    public func prepareCleanup(olderThan cutoff: Date = .distantFuture) async throws -> RecordCleanupPlan {
        try await ensureInitialized()
        let candidates = graphState.recordOrder.reversed().filter { id in
            guard !reuseLeases.values.contains(where: { $0.record.id == id }),
                  let header = graphState.recordsByID[id], header.createdAt <= cutoff,
                  header.provenance.source.kind == .systemClipboard,
                  let metadata = graphState.metadataByRecordID[id], !metadata.isPinned, metadata.tags.isEmpty else { return false }
            return graphState.membershipIDsByRecordID[id, default: []].allSatisfy { membershipID in
                guard let membership = graphState.membershipsByID[membershipID] else { return false }
                return membership.collectionID == RecordCollection.inboxID && !leasedMembershipIDs.contains(membershipID)
            }
        }
        return RecordCleanupPlan(revision: graphState.revision, recordIDs: candidates,
                                 byteCount: candidates.reduce(0) { $0 + (graphState.recordsByID[$1]?.byteCount ?? 0) },
                                 protectedCount: graphState.recordsByID.count - candidates.count, scope: .history(olderThan: cutoff))
    }

    public func prepareCleanup(scope: RecordCleanupScope) async throws -> RecordCleanupPlan {
        try await ensureInitialized()
        let recordIDs: [RecordID]
        let membershipIDs: [RecordMembershipID]
        switch scope {
        case .history(let cutoff): return try await prepareCleanup(olderThan: cutoff)
        case .record(let id):
            guard graphState.recordsByID[id] != nil else { throw RecordStoreError.recordUnavailable }
            recordIDs = [id]
            membershipIDs = graphState.membershipIDsByRecordID[id, default: []]
        case .collection(let id):
            guard graphState.collectionsByID[id] != nil else { throw RecordStoreError.collectionUnavailable }
            recordIDs = []
            membershipIDs = graphState.membershipIDsByCollectionID[id, default: []]
        case .membership(let id):
            guard graphState.membershipsByID[id] != nil else { throw RecordStoreError.membershipUnavailable }
            recordIDs = []
            membershipIDs = [id]
        }
        guard membershipIDs.allSatisfy({ !leasedMembershipIDs.contains($0) }),
              !reuseLeases.values.contains(where: { recordIDs.contains($0.record.id) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        return RecordCleanupPlan(revision: graphState.revision, recordIDs: recordIDs,
                                 byteCount: recordIDs.reduce(0) { $0 + (graphState.recordsByID[$1]?.byteCount ?? 0) },
                                 protectedCount: graphState.recordsByID.count - recordIDs.count,
                                 scope: scope, membershipIDs: membershipIDs)
    }

    public func refreshCleanupPlan(_ previous: RecordCleanupPlan) async throws -> RecordCleanupPlan {
        let eligible = try await prepareCleanup(scope: previous.scope)
        guard Set(eligible.membershipIDs) == Set(previous.membershipIDs) else {
            throw RecordStoreError.membershipChanged
        }
        let allowed = Set(previous.recordIDs)
        let candidates = eligible.recordIDs.filter { allowed.contains($0) }
        return RecordCleanupPlan(revision: graphState.revision, recordIDs: candidates,
                                 byteCount: candidates.reduce(0) { $0 + (graphState.recordsByID[$1]?.byteCount ?? 0) },
                                 protectedCount: graphState.recordsByID.count - candidates.count,
                                 scope: previous.scope, membershipIDs: previous.membershipIDs)
    }

    public func confirmCleanup(_ plan: RecordCleanupPlan, resolvingReferences resolution: RecordCollectionReferenceResolution? = nil) async throws -> RecordCleanupResult {
        try await ensureInitialized()
        guard plan.revision == graphState.revision, Set(plan.recordIDs).count == plan.recordIDs.count else {
            throw RecordStoreError.membershipChanged
        }
        let eligible = try await prepareCleanup(scope: plan.scope)
        guard plan.revision == graphState.revision, Set(plan.recordIDs).isSubset(of: Set(eligible.recordIDs)),
              Set(plan.membershipIDs) == Set(eligible.membershipIDs) else { throw RecordStoreError.membershipChanged }
        switch plan.scope {
        case .collection(let id):
            try await deleteCollection(id, resolvingReferences: resolution)
            return RecordCleanupResult(removedCount: 0, preservedActiveCount: eligible.protectedCount)
        case .membership(let id):
            try await removeMembership(id)
            return RecordCleanupResult(removedCount: 0, preservedActiveCount: eligible.protectedCount)
        case .record(let id):
            guard plan.recordIDs == [id] else { throw RecordStoreError.membershipChanged }
            try await deleteRecord(id)
            return RecordCleanupResult(removedCount: 1, preservedActiveCount: eligible.protectedCount)
        case .history: break
        }
        guard !plan.recordIDs.isEmpty else {
            return RecordCleanupResult(removedCount: 0, preservedActiveCount: eligible.protectedCount)
        }
        let removed = Set(plan.recordIDs)
        for id in removed {
            for membershipID in graphState.membershipIDsByRecordID[id, default: []] { removeMembershipWithoutPersistence(membershipID) }
            markCatalogChange(.record, id: id)
            graphState.recordsByID.removeValue(forKey: id)
            markCatalogChange(.metadata, id: id)
            graphState.metadataByRecordID.removeValue(forKey: id)
            markCatalogChange(.activity, id: id)
            graphState.activityByRecordID.removeValue(forKey: id)
            graphState.membershipIDsByRecordID.removeValue(forKey: id)
            graphState.durableBlobReferencesByRecordID.removeValue(forKey: id)
        }
        graphState.recordOrder.removeAll { removed.contains($0) }
        noteMutation()
        try await persistCurrentGraph()
        return RecordCleanupResult(removedCount: removed.count, preservedActiveCount: graphState.recordsByID.count)
    }
}

public struct RecordReuseLease: Sendable {
    public let id: UUID
    public let record: Record
    public let sink: RecordSinkIdentity
}

extension RecordStore {
    public func beginReuse(_ subject: RecordReuseSubject, sink: RecordSinkIdentity) async throws -> RecordReuseLease {
        try await ensureInitialized()
        guard sink != .recordCollection,
              let record = try await materializedRecord(subject.recordID),
              graphState.metadataByRecordID[subject.recordID]?.revision == subject.metadataRevision else {
            throw RecordStoreError.recordUnavailable
        }
        let lease = RecordReuseLease(id: UUID(), record: record, sink: sink)
        reuseLeases[lease.id] = lease
        return lease
    }
}
