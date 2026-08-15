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
    private struct CommittedGraphState {
        var recordsByID: [RecordID: Record]
        var recordOrder: [RecordID]
        var metadataByRecordID: [RecordID: RecordMetadata]
        var activityByRecordID: [RecordID: RecordActivity]
        var collectionsByID: [RecordCollectionID: RecordCollection]
        var collectionOrder: [RecordCollectionID]
        var membershipsByID: [RecordMembershipID: RecordMembership]
        var membershipIDsByRecordID: [RecordID: [RecordMembershipID]]
        var membershipIDsByCollectionID: [RecordCollectionID: [RecordMembershipID]]
        var captureRules: [CaptureRouteRule]
        var deliveryRules: [DeliveryRouteRule]
        var nextMembershipOrdinal: UInt64
        var revision: UInt64
        var repositoryRevision: Int64?
        var durableBlobReferencesByRecordID: [RecordID: RecordGraphPersistenceBlobReference]
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

    private var recordsByID: [RecordID: Record] = [:]
    private var recordOrder: [RecordID] = []
    private var metadataByRecordID: [RecordID: RecordMetadata] = [:]
    private var activityByRecordID: [RecordID: RecordActivity] = [:]
    private var collectionsByID: [RecordCollectionID: RecordCollection] = [
        RecordCollection.inboxID: .inbox,
        RecordCollection.voiceInputID: .voiceInput,
    ]
    private var collectionOrder: [RecordCollectionID] = [
        RecordCollection.inboxID,
        RecordCollection.voiceInputID,
    ]
    private var membershipsByID: [RecordMembershipID: RecordMembership] = [:]
    private var membershipIDsByRecordID: [RecordID: [RecordMembershipID]] = [:]
    private var membershipIDsByCollectionID: [RecordCollectionID: [RecordMembershipID]] = [
        RecordCollection.inboxID: [],
        RecordCollection.voiceInputID: [],
    ]
    private var captureRules: [CaptureRouteRule] = []
    private var deliveryRules: [DeliveryRouteRule] = []
    private var leasesByID: [UUID: LeaseState] = [:]
    private var leasedMembershipIDs: Set<RecordMembershipID> = []
    private var settlingLeaseIDs: Set<UUID> = []
    private var nextMembershipOrdinal: UInt64 = 1
    private var revision: UInt64 = 0

    private let persistence: (any RecordGraphPersistenceStore)?
    private let storageLimits: RecordStorageLimits
    private var repositoryRevision: Int64?
    private var durableBlobReferencesByRecordID: [RecordID: RecordGraphPersistenceBlobReference] = [:]
    private var committedGraphState: CommittedGraphState?
    private var isInitialized = false
    private var isInitializing = false
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []
    private var initializationError: RecordStoreError?
    private var isPersistingGraph = false
    private var graphPersistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotContinuations: [UUID: AsyncStream<RecordStoreSnapshot>.Continuation] = [:]
    private var collectionEventSink: (any RecordCollectionEventSink)?
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
            committedGraphState = captureCommittedGraphState()
        }
        await waitForGraphPersistence()
    }

    public func snapshot() async throws -> RecordStoreSnapshot {
        try await ensureInitialized()
        return makeSnapshot()
    }

    public func snapshotStream() async throws -> AsyncStream<RecordStoreSnapshot> {
        try await ensureInitialized()
        let id = UUID()
        let initial = makeSnapshot()
        return AsyncStream { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    public func setRecordCollectionEventSink(_ sink: (any RecordCollectionEventSink)?) {
        collectionEventSink = sink
    }

    public func record(id: RecordID) async throws -> RecordProjection? {
        try await ensureInitialized()
        return projection(for: id)
    }

    public func collection(id: RecordCollectionID) async throws -> RecordCollectionProjection? {
        try await ensureInitialized()
        guard let collection = collectionsByID[id] else { return nil }
        let memberships = membershipIDsByCollectionID[id, default: []]
            .compactMap { membershipsByID[$0] }
        return RecordCollectionProjection(
            collection: collection,
            memberships: memberships,
            recordsByID: Dictionary(
                uniqueKeysWithValues: Set(memberships.map(\.recordID)).compactMap { recordID in
                    recordsByID[recordID].map { (recordID, $0) }
                }
            )
        )
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
        guard destinations.allSatisfy({ collectionsByID[$0] != nil }) else {
            throw RecordStoreError.collectionUnavailable
        }
        guard membershipsByID.count + destinations.count <= RecordGraphLimits.maximumMemberships else {
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
        recordsByID[record.id] = record
        recordOrder.insert(record.id, at: 0)
        metadataByRecordID[record.id] = RecordMetadata(
            recordID: record.id,
            tags: normalizedTags(draft.tags),
            isPinned: draft.isPinned
        )
        activityByRecordID[record.id] = RecordActivity(recordID: record.id)
        membershipIDsByRecordID[record.id] = []
        for collectionID in destinations {
            _ = try addMembershipWithoutPersistence(recordID: record.id, collectionID: collectionID)
        }
        noteMutation()
        try await persistCurrentGraph()
        guard let projection = projection(for: record.id) else {
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
        if let existing = membershipIDsByRecordID[recordID, default: []]
            .compactMap({ membershipsByID[$0] })
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
        if let record = recordsByID[recordID] {
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
        guard let membership = membershipsByID[membershipID] else {
            throw RecordStoreError.membershipUnavailable
        }
        if let expectedRevision, membership.revision != expectedRevision {
            throw RecordStoreError.membershipChanged
        }
        guard !leasedMembershipIDs.contains(membershipID) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let record = recordsByID[membership.recordID]
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
        guard recordsByID[recordID] != nil else { throw RecordStoreError.recordUnavailable }
        let membershipIDs = membershipIDsByRecordID[recordID, default: []]
        guard membershipIDs.allSatisfy({ !leasedMembershipIDs.contains($0) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let removedMemberships = membershipIDs.compactMap { membershipsByID[$0] }
        let removedRecord = recordsByID[recordID]
        for membershipID in membershipIDs { removeMembershipWithoutPersistence(membershipID) }
        recordsByID.removeValue(forKey: recordID)
        recordOrder.removeAll { $0 == recordID }
        metadataByRecordID.removeValue(forKey: recordID)
        activityByRecordID.removeValue(forKey: recordID)
        membershipIDsByRecordID.removeValue(forKey: recordID)
        durableBlobReferencesByRecordID.removeValue(forKey: recordID)
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
        guard var metadata = metadataByRecordID[recordID] else {
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
        metadataByRecordID[recordID] = metadata
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
        guard let sourceMembership = membershipsByID[membershipID] else {
            throw RecordStoreError.membershipUnavailable
        }
        guard sourceMembership.revision == expectedRevision else {
            throw RecordStoreError.membershipChanged
        }
        guard !leasedMembershipIDs.contains(membershipID),
              let sourceRecord = recordsByID[sourceMembership.recordID],
              let sourceMetadata = metadataByRecordID[sourceRecord.id]
        else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let destinationMemberships = inAllCollections
            ? membershipIDsByRecordID[sourceRecord.id, default: []].compactMap { membershipsByID[$0] }
            : [sourceMembership]
        guard destinationMemberships.allSatisfy({ !leasedMembershipIDs.contains($0.id) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        let replacingMembershipIDs = Set(destinationMemberships.map(\.id))
        let sourceWasActive = hasActiveMembership(recordID: sourceRecord.id)
        let sourceRemainsActive = membershipIDsByRecordID[sourceRecord.id, default: []]
            .compactMap { membershipsByID[$0] }
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
        recordsByID[replacement.id] = replacement
        recordOrder.insert(replacement.id, at: 0)
        metadataByRecordID[replacement.id] = RecordMetadata(
            recordID: replacement.id,
            tags: sourceMetadata.tags,
            isPinned: sourceMetadata.isPinned
        )
        activityByRecordID[replacement.id] = RecordActivity(recordID: replacement.id)
        membershipIDsByRecordID[replacement.id] = []

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
            membershipsByID[replacementMembership.id] = replacementMembership
            membershipIDsByRecordID[replacement.id, default: []].append(replacementMembership.id)
            membershipIDsByCollectionID[replacementMembership.collectionID, default: []]
                .append(replacementMembership.id)
            sortCollectionMemberships(replacementMembership.collectionID)
        }
        noteMutation()
        try await persistCurrentGraph()
        guard let projection = projection(for: replacement.id) else {
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
        guard collectionsByID.count < storageLimits.maximumCollectionCount else {
            throw RecordStoreError.collectionLimitReached
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= storageLimits.maximumCollectionNameUTF8ByteCount
        else { throw RecordStoreError.payloadLimitReached }
        let collection = RecordCollection(name: normalizedName, preset: preset)
        collectionsByID[collection.id] = collection
        collectionOrder.append(collection.id)
        membershipIDsByCollectionID[collection.id] = []
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
        guard var collection = collectionsByID[collectionID] else {
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
        collectionsByID[collectionID] = collection
        noteMutation()
        try await persistCurrentGraph()
        return collection
    }

    public func deletionImpact(for collectionID: RecordCollectionID) async throws -> RecordCollectionDeletionImpact {
        try await ensureInitialized()
        guard collectionsByID[collectionID] != nil else {
            throw RecordStoreError.collectionUnavailable
        }
        return RecordCollectionDeletionImpact(
            collectionID: collectionID,
            membershipCount: membershipIDsByCollectionID[collectionID, default: []].count,
            captureRuleIDs: captureRules.filter { $0.destinationCollectionIDs.contains(collectionID) }.map(\.id),
            deliveryRuleIDs: deliveryRules.filter {
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
        let membershipIDs = membershipIDsByCollectionID[collectionID, default: []]
        guard membershipIDs.allSatisfy({ !leasedMembershipIDs.contains($0) }) else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        switch resolution {
        case .replace(let replacementID):
            guard replacementID != collectionID, collectionsByID[replacementID] != nil else {
                throw RecordStoreError.collectionUnavailable
            }
            captureRules = captureRules.map { rule in
                var rule = rule
                rule.destinationCollectionIDs = stableUnique(
                    rule.destinationCollectionIDs.map { $0 == collectionID ? replacementID : $0 }
                )
                return rule
            }
            deliveryRules = deliveryRules.map { rule in
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
            captureRules = captureRules.map { rule in
                guard rule.destinationCollectionIDs.contains(collectionID) else { return rule }
                var rule = rule
                rule.destinationCollectionIDs.removeAll { $0 == collectionID }
                if rule.destinationCollectionIDs.isEmpty { rule.isEnabled = false }
                return rule
            }
            deliveryRules = deliveryRules.map { rule in
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
        let removedMemberships = membershipIDs.compactMap { membershipsByID[$0] }
        let removedRecords = Dictionary(
            uniqueKeysWithValues: Set(removedMemberships.map(\.recordID)).compactMap { recordID in
                recordsByID[recordID].map { (recordID, $0) }
            }
        )
        for membershipID in membershipIDs {
            removeMembershipWithoutPersistence(membershipID)
        }
        collectionsByID.removeValue(forKey: collectionID)
        collectionOrder.removeAll { $0 == collectionID }
        membershipIDsByCollectionID.removeValue(forKey: collectionID)
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
                && $0.destinationCollectionIDs.allSatisfy { collectionsByID[$0] != nil }
        }) else { throw RecordStoreError.invalidGraph }
        captureRules = rules
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
                && $0.sourceCollectionIDs.allSatisfy { collectionsByID[$0] != nil }
                && ($0.sink != .recordCollection
                    ? $0.sinkCollectionID == nil
                    : $0.sinkCollectionID.map { collectionsByID[$0] != nil } == true)
        }) else { throw RecordStoreError.invalidGraph }
        deliveryRules = rules
        noteMutation()
        try await persistCurrentGraph()
    }

    public func routedCaptureDestinations(
        for envelope: RecordCaptureEnvelope
    ) async throws -> [RecordCollectionID] {
        try await ensureInitialized()
        guard envelope.requestedCollectionIDs.allSatisfy({ collectionsByID[$0] != nil }) else {
            throw RecordStoreError.collectionUnavailable
        }
        var result = stableUnique(envelope.requestedCollectionIDs)
        for rule in captureRules
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
        return deliveryRules
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
        let route = deliveryRules
            .filter { $0.isEnabled && $0.matcher.matches(target) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .first
        let sourceIDs = route?.sourceCollectionIDs ?? [RecordCollection.inboxID]
        for collectionID in sourceIDs {
            guard let collection = collectionsByID[collectionID] else { continue }
            let active = activeMemberships(in: collectionID)
            guard collection.selectionPolicy != .manual,
                  let membership = selectedMembership(from: active, policy: collection.selectionPolicy),
                  let record = recordsByID[membership.recordID]
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
            guard let collection = collectionsByID[collectionID] else { continue }
            let membership: RecordMembership?
            if collection.selectionPolicy == .manual {
                guard let manualMembershipID else { continue }
                membership = membershipsByID[manualMembershipID].flatMap {
                    $0.collectionID == collectionID && $0.state == .active ? $0 : nil
                }
            } else {
                let candidates = membershipIDsByCollectionID[collectionID, default: []]
                    .compactMap { membershipsByID[$0] }
                    .filter { $0.state == .active && !leasedMembershipIDs.contains($0.id) }
                switch collection.selectionPolicy {
                case .newestFirst: membership = candidates.max { $0.ordinal < $1.ordinal }
                case .oldestFirst: membership = candidates.min { $0.ordinal < $1.ordinal }
                case .manual: membership = nil
                }
            }
            guard let membership,
                  !leasedMembershipIDs.contains(membership.id),
                  let record = recordsByID[membership.recordID]
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
        if sourceCollectionIDs.contains(where: { collectionsByID[$0]?.selectionPolicy == .manual }) {
            throw RecordStoreError.manualSelectionRequired
        }
        throw RecordStoreError.membershipUnavailable
    }

    public func beginDelivery(
        matching subject: RecordDeliverySubject,
        sink: RecordSinkIdentity
    ) async throws -> RecordDeliveryLease {
        try await ensureInitialized()
        guard let membership = membershipsByID[subject.membershipID],
              let record = recordsByID[subject.recordID]
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
        guard let collection = collectionsByID[membership.collectionID] else {
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
        guard let lease = leasesByID[leaseID],
              var membership = membershipsByID[lease.membershipID]
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
        guard var activity = activityByRecordID[membership.recordID] else {
            throw RecordStoreError.invalidGraph
        }
        if lease.consumptionPolicy == .consumeAfterSuccessfulDelivery {
            membership.setState(.consumed)
            membershipsByID[membership.id] = membership
        }
        let completedAt = receipt?.deliveredAt ?? deliveredAt
        activity.recordDelivery(at: completedAt)
        activityByRecordID[membership.recordID] = activity
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
        guard let lease = leasesByID[leaseID],
              let membership = membershipsByID[lease.membershipID]
        else { throw RecordStoreError.membershipUnavailable }
        guard settlingLeaseIDs.insert(leaseID).inserted else {
            throw RecordStoreError.membershipAlreadyInUse
        }
        defer { settlingLeaseIDs.remove(leaseID) }
        guard membership.revision == lease.expectedRevision else {
            releaseDeliveryLease(leaseID, lease: lease)
            throw RecordStoreError.membershipChanged
        }
        guard var activity = activityByRecordID[membership.recordID] else {
            releaseDeliveryLease(leaseID, lease: lease)
            throw RecordStoreError.invalidGraph
        }
        activity.recordFailure(failure)
        activityByRecordID[membership.recordID] = activity
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
        guard let lease = leasesByID.removeValue(forKey: leaseID),
              let membership = membershipsByID[lease.membershipID]
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
        guard let metadata = metadataByRecordID[recordID] else {
            throw RecordStoreError.recordUnavailable
        }
        return metadata.isPinned || membershipIDsByRecordID[recordID, default: []].contains {
            membershipsByID[$0]?.state == .active
        }
    }

    private func addMembershipWithoutPersistence(
        recordID: RecordID,
        collectionID: RecordCollectionID
    ) throws -> RecordMembership {
        guard recordsByID[recordID] != nil else { throw RecordStoreError.recordUnavailable }
        guard collectionsByID[collectionID] != nil else { throw RecordStoreError.collectionUnavailable }
        if let existing = membershipIDsByRecordID[recordID, default: []]
            .compactMap({ membershipsByID[$0] })
            .first(where: { $0.collectionID == collectionID }) {
            return existing
        }
        guard membershipIDsByRecordID[recordID, default: []].count
                < RecordGraphLimits.maximumMembershipsPerRecord,
              membershipsByID.count < RecordGraphLimits.maximumMemberships
        else { throw RecordStoreError.membershipLimitReached }
        let membership = RecordMembership(
            recordID: recordID,
            collectionID: collectionID,
            ordinal: nextMembershipOrdinal
        )
        nextMembershipOrdinal = nextMembershipOrdinal == .max ? 1 : nextMembershipOrdinal + 1
        membershipsByID[membership.id] = membership
        membershipIDsByRecordID[recordID, default: []].append(membership.id)
        membershipIDsByCollectionID[collectionID, default: []].append(membership.id)
        sortCollectionMemberships(collectionID)
        return membership
    }

    private func removeMembershipWithoutPersistence(_ membershipID: RecordMembershipID) {
        guard let membership = membershipsByID.removeValue(forKey: membershipID) else { return }
        membershipIDsByRecordID[membership.recordID]?.removeAll { $0 == membershipID }
        membershipIDsByCollectionID[membership.collectionID]?.removeAll { $0 == membershipID }
    }

    private func sortCollectionMemberships(_ collectionID: RecordCollectionID) {
        membershipIDsByCollectionID[collectionID]?.sort {
            (membershipsByID[$0]?.ordinal ?? 0) < (membershipsByID[$1]?.ordinal ?? 0)
        }
    }

    private func activeMemberships(in collectionID: RecordCollectionID) -> [RecordMembership] {
        membershipIDsByCollectionID[collectionID, default: []]
            .compactMap { membershipsByID[$0] }
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

    private func projection(for recordID: RecordID) -> RecordProjection? {
        guard let record = recordsByID[recordID],
              let metadata = metadataByRecordID[recordID],
              let activity = activityByRecordID[recordID]
        else { return nil }
        return RecordProjection(
            record: record,
            metadata: metadata,
            activity: activity,
            memberships: membershipIDsByRecordID[recordID, default: []]
                .compactMap { membershipsByID[$0] }
        )
    }

    private func makeSnapshot() -> RecordStoreSnapshot {
        RecordStoreSnapshot(
            revision: revision,
            records: recordOrder.compactMap(projection),
            collections: collectionOrder.compactMap { collectionsByID[$0] },
            captureRules: captureRules,
            deliveryRules: deliveryRules
        )
    }

    private func noteMutation() {
        revision = revision == .max ? 1 : revision + 1
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func publishSnapshotToObservers() {
        let snapshot = makeSnapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func captureCommittedGraphState() -> CommittedGraphState {
        CommittedGraphState(
            recordsByID: recordsByID,
            recordOrder: recordOrder,
            metadataByRecordID: metadataByRecordID,
            activityByRecordID: activityByRecordID,
            collectionsByID: collectionsByID,
            collectionOrder: collectionOrder,
            membershipsByID: membershipsByID,
            membershipIDsByRecordID: membershipIDsByRecordID,
            membershipIDsByCollectionID: membershipIDsByCollectionID,
            captureRules: captureRules,
            deliveryRules: deliveryRules,
            nextMembershipOrdinal: nextMembershipOrdinal,
            revision: revision,
            repositoryRevision: repositoryRevision,
            durableBlobReferencesByRecordID: durableBlobReferencesByRecordID
        )
    }

    private func restoreCommittedGraphState(_ state: CommittedGraphState) {
        recordsByID = state.recordsByID
        recordOrder = state.recordOrder
        metadataByRecordID = state.metadataByRecordID
        activityByRecordID = state.activityByRecordID
        collectionsByID = state.collectionsByID
        collectionOrder = state.collectionOrder
        membershipsByID = state.membershipsByID
        membershipIDsByRecordID = state.membershipIDsByRecordID
        membershipIDsByCollectionID = state.membershipIDsByCollectionID
        captureRules = state.captureRules
        deliveryRules = state.deliveryRules
        nextMembershipOrdinal = state.nextMembershipOrdinal
        revision = state.revision
        repositoryRevision = state.repositoryRevision
        durableBlobReferencesByRecordID = state.durableBlobReferencesByRecordID
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
        membershipIDsByCollectionID[collectionID, default: []].reduce(into: 0) { count, membershipID in
            if membershipsByID[membershipID]?.state == .active { count += 1 }
        }
    }

    private func hasActiveMembership(recordID: RecordID) -> Bool {
        membershipIDsByRecordID[recordID, default: []].contains {
            membershipsByID[$0]?.state == .active
        }
    }

    private func activeRecordCount() -> Int {
        recordsByID.keys.reduce(into: 0) { count, recordID in
            if hasActiveMembership(recordID: recordID) { count += 1 }
        }
    }

    private func historyOnlyRecordCount() -> Int {
        recordsByID.count - activeRecordCount()
    }

    private func validateRecordAdmission(
        payload: RecordPayload,
        tags: [String],
        activeRecordDelta: Int,
        historyOnlyRecordDelta: Int
    ) throws {
        guard recordsByID.count < storageLimits.maximumRecordCount,
              activeRecordCount() + activeRecordDelta <= storageLimits.maximumActiveRecordCount,
              historyOnlyRecordCount() + historyOnlyRecordDelta
                <= storageLimits.maximumHistoryOnlyRecordCount
        else { throw RecordStoreError.recordLimitReached }
        let payloadBytes = try validatedPayloadByteCount(payload)
        guard try totalPayloadByteCount() <= storageLimits.maximumTotalPayloadByteCount - payloadBytes else {
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

    private func totalPayloadByteCount() throws -> Int {
        try recordsByID.values.reduce(into: 0) { count, record in
            count += try validatedPayloadByteCount(record.payload)
        }
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
            switch try await persistence.loadRecordGraph() {
            case .empty:
                return
            case .legacyClipboard(let metadata, let imageBlobs):
                let migrated = try LegacyClipboardMigration.decodeAndMigrate(
                    metadata: metadata,
                    imageBlobs: imageBlobs
                )
                try install(migrated)
                repositoryRevision = nil
                durableBlobReferencesByRecordID = [:]
                try await persistCurrentGraph()
            case .current(let revision, let graph, let payloadBlobs):
                guard revision > 0 else { throw RecordStoreError.invalidGraph }
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
                repositoryRevision = revision
                durableBlobReferencesByRecordID = Dictionary(
                    uniqueKeysWithValues: persisted.records.map { ($0.id, $0.payloadBlob) }
                )
            }
        } catch {
            initializationError = .persistenceUnavailable
        }
    }

    private func install(_ graph: LegacyClipboardMigration.MigratedGraph) throws {
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
            payloadByteCount += try validatedPayloadByteCount(record.payload)
            guard payloadByteCount <= storageLimits.maximumTotalPayloadByteCount else {
                throw RecordStoreError.invalidGraph
            }
        }
        for metadata in graph.metadata {
            try validateTags(metadata.tags)
        }
        recordsByID = Dictionary(uniqueKeysWithValues: graph.records.map { ($0.id, $0) })
        recordOrder = graph.records.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        metadataByRecordID = Dictionary(uniqueKeysWithValues: graph.metadata.map { ($0.recordID, $0) })
        activityByRecordID = Dictionary(uniqueKeysWithValues: graph.activity.map { ($0.recordID, $0) })
        collectionsByID = Dictionary(uniqueKeysWithValues: graph.collections.map { ($0.id, $0) })
        collectionOrder = graph.collections.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        membershipsByID = Dictionary(uniqueKeysWithValues: graph.memberships.map { ($0.id, $0) })
        membershipIDsByRecordID = Dictionary(grouping: graph.memberships, by: \.recordID)
            .mapValues { $0.sorted { $0.ordinal < $1.ordinal }.map(\.id) }
        membershipIDsByCollectionID = Dictionary(grouping: graph.memberships, by: \.collectionID)
            .mapValues { $0.sorted { $0.ordinal < $1.ordinal }.map(\.id) }
        for recordID in recordsByID.keys where membershipIDsByRecordID[recordID] == nil {
            membershipIDsByRecordID[recordID] = []
        }
        for collectionID in collectionsByID.keys where membershipIDsByCollectionID[collectionID] == nil {
            membershipIDsByCollectionID[collectionID] = []
        }
        captureRules = graph.captureRules
        deliveryRules = graph.deliveryRules
        let maximumOrdinal = graph.memberships.map(\.ordinal).max() ?? 0
        nextMembershipOrdinal = max(graph.nextMembershipOrdinal, maximumOrdinal + 1)
        revision = 1
    }

    private func persistCurrentGraph() async throws {
        precondition(!isPersistingGraph, "Record graph writes must be serialized.")
        isPersistingGraph = true
        defer { finishGraphPersistence() }
        let rollbackState = committedGraphState
        guard let persistence else {
            committedGraphState = captureCommittedGraphState()
            publishSnapshotToObservers()
            return
        }
        do {
            let prepared = try preparePersistenceWrite()
            let committedRevision = try await persistence.replaceRecordGraph(with: prepared.snapshot)
            repositoryRevision = committedRevision
            durableBlobReferencesByRecordID = prepared.referencesByRecordID
            committedGraphState = captureCommittedGraphState()
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
        for recordID in recordOrder {
            guard let record = recordsByID[recordID] else { throw RecordStoreError.invalidGraph }
            let reference: RecordGraphPersistenceBlobReference
            if let durable = durableBlobReferencesByRecordID[recordID] {
                reference = durable
                retained.append(durable)
            } else {
                let payload = try encodedPayload(record.payload)
                reference = RecordGraphPersistenceBlobReference(
                    blobID: UUID(),
                    recordID: record.id,
                    kind: record.payload.kind,
                    byteCount: payload.count
                )
                newBlobs.append(RecordGraphPersistenceBlob(reference: reference, payload: payload))
            }
            referencesByRecordID[recordID] = reference
            persistedRecords.append(
                PersistedGraph.PersistedRecord(
                    id: record.id,
                    payloadKind: record.payload.kind,
                    payloadBlob: reference,
                    provenance: record.provenance,
                    createdAt: record.createdAt
                )
            )
        }
        let graph = PersistedGraph(
            schemaVersion: PersistedGraph.schemaVersion,
            records: persistedRecords,
            metadata: recordOrder.compactMap { metadataByRecordID[$0] },
            activity: recordOrder.compactMap { activityByRecordID[$0] },
            collections: collectionOrder.compactMap { collectionsByID[$0] },
            memberships: membershipsByID.values.sorted { $0.ordinal < $1.ordinal },
            captureRules: captureRules,
            deliveryRules: deliveryRules,
            nextMembershipOrdinal: nextMembershipOrdinal
        )
        return PreparedPersistenceWrite(
            snapshot: RecordGraphPersistenceWriteSnapshot(
                expectedRevision: repositoryRevision,
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
            storeRevision: revision,
            captureTags: record.provenance.captureTags
        )
    }

    func publishCollectionEvents(_ descriptors: [RecordCollectionEventDescriptor]) async {
        guard let collectionEventSink else { return }
        for descriptor in descriptors {
            _ = await collectionEventSink.submit(descriptor)
        }
    }
}

extension RecordStore {
    public func pruneHistory(olderThan cutoff: Date) async throws -> RecordCleanupResult {
        try await removeRecordsForMaintenance(through: cutoff, preservesPinnedRecords: true)
    }

    public func clearHistory(through upperBound: Date) async throws -> RecordCleanupResult {
        try await removeRecordsForMaintenance(through: upperBound, preservesPinnedRecords: false)
    }

    private func removeRecordsForMaintenance(
        through upperBound: Date,
        preservesPinnedRecords: Bool
    ) async throws -> RecordCleanupResult {
        try await ensureInitialized()
        let eligibleIDs = recordOrder.filter { recordID in
            guard let record = recordsByID[recordID], record.createdAt <= upperBound else { return false }
            if preservesPinnedRecords, metadataByRecordID[recordID]?.isPinned == true { return false }
            return true
        }
        let protectedIDs = Set(eligibleIDs.filter { recordID in
            membershipIDsByRecordID[recordID, default: []].contains { membershipID in
                leasedMembershipIDs.contains(membershipID)
                    || membershipsByID[membershipID]?.state == .active
            }
        })
        let removableIDs = eligibleIDs.filter { !protectedIDs.contains($0) }
        guard !removableIDs.isEmpty else {
            return RecordCleanupResult(
                removedCount: 0,
                preservedActiveCount: protectedIDs.count
            )
        }

        for recordID in removableIDs {
            for membershipID in membershipIDsByRecordID[recordID, default: []] {
                removeMembershipWithoutPersistence(membershipID)
            }
            recordsByID.removeValue(forKey: recordID)
            metadataByRecordID.removeValue(forKey: recordID)
            activityByRecordID.removeValue(forKey: recordID)
            membershipIDsByRecordID.removeValue(forKey: recordID)
            durableBlobReferencesByRecordID.removeValue(forKey: recordID)
        }
        let removedSet = Set(removableIDs)
        recordOrder.removeAll { removedSet.contains($0) }
        noteMutation()
        try await persistCurrentGraph()
        return RecordCleanupResult(
            removedCount: removableIDs.count,
            preservedActiveCount: protectedIDs.count
        )
    }
}
