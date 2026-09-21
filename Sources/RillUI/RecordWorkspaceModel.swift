import Foundation
import Observation
import RillCore
import RillRuntime

/// UI-owned projection of the Record graph. The actor remains the only state
/// owner; this model only keeps a refreshable snapshot and user navigation.
@MainActor
@Observable
public final class RecordWorkspaceModel {
    public private(set) var snapshot = RecordCatalogSnapshot.empty
    public var selectedCollectionID: RecordCollectionID?
    public var selectedRecordID: RecordID?
    public var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    public var showsPinnedOnly = false
    /// Panel-mode session filter: when set, only records captured from this
    /// application remain visible. Not persisted.
    public var sourceAppFilterBundleIdentifier: String?
    public private(set) var isLoading = false
    public private(set) var isMutating = false
    public private(set) var errorMessage: String?
    public private(set) var pendingCollectionDeletion: RecordCollectionDeletionImpact?

    public let cleanup: RecordCleanupModel
    public private(set) var retentionSuggestionCount = 0
    private var collectionDeletionPlan: RecordCleanupPlan?
    private var pendingRecordDeletionSelection: (deleted: RecordID, neighbor: RecordID?)?
    private let store: RecordStore
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var isClosed = false
    private var searchMatches: Set<RecordID> = []
    public private(set) var isSearching = false

    public init(store: RecordStore) {
        self.store = store
        cleanup = RecordCleanupModel(store: store)
    }

    isolated deinit { observationTask?.cancel(); searchTask?.cancel() }

    public func sealMutations() {
        isClosed = true
        cleanup.seal()
    }

    public func shutdown() async {
        sealMutations()
        observationTask?.cancel()
        searchTask?.cancel()
        await mutationTask?.value
        await cleanup.shutdown()
    }

    var selectedVisibleRecord: RecordSummary? {
        selectedRecordID.flatMap { id in visibleRecords.first { $0.id == id } }
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
            payloadKind: projection.header.kind,
            captureTags: projection.header.provenance.captureTags
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
            payloadKind: projection.header.kind,
            captureTags: projection.header.provenance.captureTags
        )
    }

    public var visibleRecords: [RecordSummary] {
        let records: [RecordSummary]
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
               projection.header.provenance.sourceBundleIdentifier != sourceAppFilterBundleIdentifier {
                return false
            }
            guard !showsPinnedOnly || projection.metadata.isPinned else { return false }
            guard !query.isEmpty else { return true }
            return searchMatches.contains(projection.id)
        }
    }

    public func collectionName(_ id: RecordCollectionID) -> String {
        snapshot.collections.first(where: { $0.id == id })?.name ?? id.description
    }

    public func membership(
        for record: RecordSummary,
        in collectionID: RecordCollectionID
    ) -> RecordMembership? {
        record.memberships.first { $0.collectionID == collectionID }
    }

    public func refresh() async {
        startObservingIfNeeded()
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await store.catalogSnapshot()
            scheduleSearch()
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
                let stream = try await store.catalogStream()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    self?.snapshot = snapshot
                    self?.scheduleSearch()
                    self?.repairSelection()
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchMatches = []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        searchTask = Task { [weak self, store] in
            do {
                var offset = 0
                repeat {
                    let page = try await store.query(.init(text: query), offset: offset, limit: 100)
                    guard !Task.isCancelled, let self, self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                    self.searchMatches.formUnion(page.records.map(\.id))
                    if let next = page.nextOffset { offset = next } else { break }
                } while true
                guard !Task.isCancelled else { return }
                self?.isSearching = false
                self?.repairSelection()
            } catch is CancellationError {
            } catch RecordStoreError.membershipChanged {
                guard !Task.isCancelled else { return }
                self?.scheduleSearch()
            } catch {
                guard !Task.isCancelled else { return }
                self?.isSearching = false
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
        await cleanup.request(scope: .membership(membership.id))
    }

    public func deleteRecord(_ id: RecordID) async {
        let ids = visibleRecords.map(\.id)
        if let index = ids.firstIndex(of: id), selectedRecordID == id {
            let neighbor = index + 1 < ids.count ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
            pendingRecordDeletionSelection = (id, neighbor)
        }
        await cleanup.request(scope: .record(id))
    }

    public func refreshRetentionSuggestion(olderThan cutoff: Date?) async {
        guard let cutoff else { retentionSuggestionCount = 0; return }
        do { retentionSuggestionCount = try await store.prepareCleanup(olderThan: cutoff).recordIDs.count }
        catch { errorMessage = error.localizedDescription }
    }

    public func updateMetadata(
        for record: RecordSummary,
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

    public func updateMetadata(for record: RecordProjection, tags: [String]? = nil, isPinned: Bool? = nil) async {
        await mutate {
            _ = try await self.store.updateMetadata(recordID: record.id, tags: tags, isPinned: isPinned,
                                                   expectedRevision: record.metadata.revision)
        }
    }

    public func loadRecord(_ id: RecordID) async -> RecordProjection? {
        do { return try await store.record(id: id) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    public func makeQuickPanelModel() -> RecordQuickPanelModel {
        RecordQuickPanelModel(store: store)
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
            collectionDeletionPlan = try await store.prepareCleanup(scope: .collection(id))
            let impact = try await store.deletionImpact(for: id)
            pendingCollectionDeletion = impact
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelCollectionDeletion() {
        collectionDeletionPlan = nil
        pendingCollectionDeletion = nil
    }

    public func confirmCollectionDeletion(
        _ id: RecordCollectionID,
        resolution: RecordCollectionReferenceResolution?
    ) async {
        guard let plan = collectionDeletionPlan, plan.scope == .collection(id) else { return }
        await mutate {
            do {
                _ = try await self.store.confirmCleanup(plan, resolvingReferences: resolution)
                self.cancelCollectionDeletion()
                if self.selectedCollectionID == id { self.selectedCollectionID = nil }
            } catch RecordStoreError.membershipChanged {
                await self.requestCollectionDeletion(id)
                throw RecordStoreError.membershipChanged
            }
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
        guard !isClosed, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let task = Task {
            do {
                try await operation()
                snapshot = try await store.catalogSnapshot()
                if !isClosed { scheduleSearch() }
                repairSelection()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        mutationTask = task
        await task.value
        mutationTask = nil
    }

    private func repairSelection() {
        if let pending = pendingRecordDeletionSelection, !snapshot.records.contains(where: { $0.id == pending.deleted }) {
            if selectedRecordID == pending.deleted { selectedRecordID = pending.neighbor }
            pendingRecordDeletionSelection = nil
        }
        if let selectedCollectionID,
           !snapshot.collections.contains(where: { $0.id == selectedCollectionID }) {
            self.selectedCollectionID = nil
        }
        if let selectedRecordID,
           !snapshot.records.contains(where: { $0.id == selectedRecordID }) {
            self.selectedRecordID = nil
        }
    }


    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
