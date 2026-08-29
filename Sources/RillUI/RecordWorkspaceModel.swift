import Foundation
import Observation
import RillCore
import RillRuntime

/// UI-owned projection of the Record graph. The actor remains the only state
/// owner; this model only keeps a refreshable snapshot and user navigation.
@MainActor
@Observable
public final class RecordWorkspaceModel {
    public private(set) var snapshot = RecordStoreSnapshot(
        revision: 0,
        records: [],
        collections: [],
        captureRules: [],
        deliveryRules: []
    )
    public var selectedCollectionID: RecordCollectionID?
    public var selectedRecordID: RecordID?
    public var searchText = ""
    public var showsPinnedOnly = false
    /// Panel-mode session filter: when set, only records captured from this
    /// application remain visible. Not persisted.
    public var sourceAppFilterBundleIdentifier: String?
    public private(set) var isLoading = false
    public private(set) var isMutating = false
    public private(set) var errorMessage: String?
    public private(set) var pendingCollectionDeletion: RecordCollectionDeletionImpact?

    private let store: RecordStore
    private var observationTask: Task<Void, Never>?

    public init(store: RecordStore) {
        self.store = store
    }

    public var selectedCollection: RecordCollection? {
        selectedCollectionID.flatMap { id in snapshot.collections.first { $0.id == id } }
    }

    /// Freezes the exact immutable Record and active membership selected in a
    /// reusable List. Automatic Stack/Queue selection and custom collection
    /// policies remain owned by runtime routing rather than being overridden
    /// by UI state.
    public var selectedListDeliverySubject: RecordDeliverySubject? {
        guard let selectedCollection,
              selectedCollection.matchingPreset == .list,
              let selectedRecordID,
              let projection = snapshot.records.first(where: { $0.id == selectedRecordID }),
              let membership = projection.memberships.first(where: {
                  $0.collectionID == selectedCollection.id && $0.state == .active
              }) else {
            return nil
        }
        return RecordDeliverySubject(
            recordID: projection.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: projection.record.payload.kind,
            captureTags: projection.record.provenance.captureTags
        )
    }

    /// Freezes the exact immutable Record and an active membership for the
    /// record currently visible at `index`. Membership selection mirrors the
    /// inspector's preferred-membership rule, but unlike
    /// `selectedListDeliverySubject` it is not restricted to List presets.
    /// Records without an active membership cannot be delivered and return nil.
    public func deliverySubject(forVisibleRecordAt index: Int) -> RecordDeliverySubject? {
        let records = visibleRecords
        guard records.indices.contains(index) else { return nil }
        let projection = records[index]
        let membership: RecordMembership?
        if let selectedCollectionID,
           let selected = projection.memberships.first(where: { $0.collectionID == selectedCollectionID }) {
            membership = selected
        } else {
            membership = projection.memberships.first
        }
        guard let membership, membership.state == .active else { return nil }
        return RecordDeliverySubject(
            recordID: projection.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: projection.record.payload.kind,
            captureTags: projection.record.provenance.captureTags
        )
    }

    public var visibleRecords: [RecordProjection] {
        let records: [RecordProjection]
        if let selectedCollectionID {
            let projectionsByID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            let memberships = snapshot.records
                .flatMap(\.memberships)
                .filter { $0.collectionID == selectedCollectionID }
                .sorted { $0.ordinal > $1.ordinal }
            records = memberships.compactMap { projectionsByID[$0.recordID] }
        } else {
            // All Records is a virtual, de-duplicated RecordStore timeline.
            records = snapshot.records
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { projection in
            if let sourceAppFilterBundleIdentifier,
               projection.record.provenance.sourceBundleIdentifier != sourceAppFilterBundleIdentifier {
                return false
            }
            guard !showsPinnedOnly || projection.metadata.isPinned else { return false }
            guard !query.isEmpty else { return true }
            return searchableText(for: projection).contains(query)
        }
    }

    public func collectionName(_ id: RecordCollectionID) -> String {
        snapshot.collections.first(where: { $0.id == id })?.name ?? id.description
    }

    public func membership(
        for record: RecordProjection,
        in collectionID: RecordCollectionID
    ) -> RecordMembership? {
        record.memberships.first { $0.collectionID == collectionID }
    }

    public func refresh() async {
        startObservingIfNeeded()
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await store.snapshot()
            repairSelection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startObservingIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, store] in
            do {
                let stream = try await store.snapshotStream()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    self?.snapshot = snapshot
                    self?.repairSelection()
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    public func selectCollection(_ id: RecordCollectionID?) {
        selectedCollectionID = id
        selectedRecordID = nil
    }

    public func createCollection(name: String, preset: RecordCollectionPreset) async {
        await mutate {
            let collection = try await self.store.createCollection(name: name, preset: preset)
            self.selectedCollectionID = collection.id
        }
    }

    public func updateCollection(
        _ id: RecordCollectionID,
        name: String? = nil,
        selectionPolicy: RecordSelectionPolicy? = nil,
        consumptionPolicy: RecordConsumptionPolicy? = nil,
        preset: RecordCollectionPreset? = nil
    ) async {
        await mutate {
            _ = try await self.store.updateCollection(
                id,
                name: name,
                selectionPolicy: selectionPolicy,
                consumptionPolicy: consumptionPolicy,
                preset: preset
            )
        }
    }

    public func addRecord(
        _ recordID: RecordID,
        to collectionIDs: [RecordCollectionID]
    ) async {
        await mutate {
            for collectionID in Self.stableUnique(collectionIDs) {
                _ = try await self.store.addMembership(recordID: recordID, to: collectionID)
            }
        }
    }

    public func removeMembership(_ membership: RecordMembership) async {
        await mutate {
            try await self.store.removeMembership(
                membership.id,
                expectedRevision: membership.revision
            )
        }
    }

    public func deleteRecord(_ id: RecordID) async {
        await mutate {
            try await self.store.deleteRecord(id)
            if self.selectedRecordID == id { self.selectedRecordID = nil }
        }
    }

    public func updateMetadata(
        for record: RecordProjection,
        tags: [String]? = nil,
        isPinned: Bool? = nil
    ) async {
        await mutate {
            _ = try await self.store.updateMetadata(
                recordID: record.id,
                tags: tags,
                isPinned: isPinned,
                expectedRevision: record.metadata.revision
            )
        }
    }

    public func replaceText(
        membership: RecordMembership,
        text: String,
        inAllCollections: Bool
    ) async {
        await mutate {
            let replacement = try await self.store.replace(
                membershipID: membership.id,
                expectedRevision: membership.revision,
                with: .text(text),
                inAllCollections: inAllCollections
            )
            self.selectedRecordID = replacement.id
        }
    }

    public func requestCollectionDeletion(_ id: RecordCollectionID) async {
        do {
            let impact = try await store.deletionImpact(for: id)
            if impact.hasRouteReferences {
                pendingCollectionDeletion = impact
            } else {
                await confirmCollectionDeletion(id, resolution: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelCollectionDeletion() {
        pendingCollectionDeletion = nil
    }

    public func confirmCollectionDeletion(
        _ id: RecordCollectionID,
        resolution: RecordCollectionReferenceResolution?
    ) async {
        pendingCollectionDeletion = nil
        await mutate {
            try await self.store.deleteCollection(id, resolvingReferences: resolution)
            if self.selectedCollectionID == id { self.selectedCollectionID = nil }
        }
    }

    public func replaceCaptureRules(_ rules: [CaptureRouteRule]) async {
        await mutate { try await self.store.replaceCaptureRules(rules) }
    }

    public func replaceDeliveryRules(_ rules: [DeliveryRouteRule]) async {
        await mutate { try await self.store.replaceDeliveryRules(rules) }
    }

    public func dismissError() {
        errorMessage = nil
    }

    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation()
            snapshot = try await store.snapshot()
            repairSelection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repairSelection() {
        if let selectedCollectionID,
           !snapshot.collections.contains(where: { $0.id == selectedCollectionID }) {
            self.selectedCollectionID = nil
        }
        if let selectedRecordID,
           !snapshot.records.contains(where: { $0.id == selectedRecordID }) {
            self.selectedRecordID = nil
        }
    }

    private func searchableText(for projection: RecordProjection) -> String {
        let payload: String
        switch projection.record.payload {
        case .text(let text):
            payload = text
        case .image:
            payload = "image"
        case .files(let urls):
            payload = urls.map(\.lastPathComponent).joined(separator: " ")
        }
        return ([
            payload,
            projection.record.provenance.sourceApplicationName ?? "",
            projection.record.provenance.sourceBundleIdentifier ?? "",
        ] + projection.metadata.tags).joined(separator: " ").lowercased()
    }

    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
