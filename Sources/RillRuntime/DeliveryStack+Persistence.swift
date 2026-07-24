import Foundation
import RillCore

extension DeliveryStack {
    private enum PersistedClipboardStateLoadError: Error {
        case unavailable
        case duplicateItemID
        case duplicateGroupID
        case duplicateGroupEntryID
        case duplicateGroupItemID
        case duplicateApplicationBundleIdentifier
        case unknownItemGroupID
        case unknownGroupEntryID
        case missingGroupEntryItemID
        case itemReferencedByMultipleGroupEntries
        case itemGroupIDMismatch
        case unknownApplicationAssignmentGroupID
        case nonPositiveFallbackPriority
        case duplicateFallbackPriority
        case persistedStateTooLarge
        case storageLimitExceeded(ClipboardStorageRejectionReason)
    }

    func loadPersistedState() async {
        guard let clipboardPersistenceStore else { return }
        isPersistenceCleanupPending = false
        do {
            let readSnapshot = try await clipboardPersistenceStore.loadClipboardPersistence()
            let stateData: Data
            let loadedRevision: Int64?
            let loadedImageBlobs: [ClipboardPersistenceImageBlob]
            let loadedFromLegacyRow: Bool
            switch readSnapshot {
            case .empty:
                repositoryRevision = nil
                blobReferencesByItemID.removeAll()
                persistedBlobIDs.removeAll()
                persistenceAvailability = .available
                await publishSnapshot()
                return
            case .legacy(let metadata):
                stateData = metadata
                loadedRevision = nil
                loadedImageBlobs = []
                loadedFromLegacyRow = true
            case .current(let revision, let metadata, let imageBlobs):
                guard revision > 0 else {
                    throw PersistedClipboardStateLoadError.unavailable
                }
                stateData = metadata
                loadedRevision = revision
                loadedImageBlobs = imageBlobs
                loadedFromLegacyRow = false
            }
            guard stateData.count <= storageLimits.maximumPersistedStateUTF8ByteCount else {
                throw PersistedClipboardStateLoadError.persistedStateTooLarge
            }

            var state = try decoder.decode(PersistedClipboardState.self, from: stateData)
            if loadedFromLegacyRow {
                guard (state.schemaVersion ?? 0) < PersistedClipboardState.currentSchemaVersion else {
                    throw PersistedClipboardStateLoadError.unavailable
                }
            } else {
                guard state.schemaVersion == PersistedClipboardState.currentSchemaVersion else {
                    throw PersistedClipboardStateLoadError.unavailable
                }
                try attachPersistedImageBlobs(loadedImageBlobs, to: &state)
            }
            var didSanitizePersistedFailure = false
            for index in state.items.indices {
                let sanitizedFailure = ClipboardDeliveryFailureCode.sanitizedStoredValue(
                    state.items[index].latestError
                )
                if state.items[index].latestError != sanitizedFailure {
                    state.items[index].latestError = sanitizedFailure
                    didSanitizePersistedFailure = true
                }
            }
            try validatePersistedState(in: state)
            if let rejection = metadataStorageRejectionReason(
                groups: state.groups.filter { !ClipboardGroup.reservedGroupIDs.contains($0.id) },
                appAssignments: state.appAssignments
            ) {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(rejection)
            }
            if (state.schemaVersion ?? 0) >= 7 {
                try validateCurrentSchemaStorageLimits(in: state)
            }
            let requiresVersionUpgrade = loadedFromLegacyRow
                || (state.schemaVersion ?? 0) < PersistedClipboardState.currentSchemaVersion
            let sanitizedItems = state.items
            let rawOversizedItemIDs = Set(
                sanitizedItems.compactMap { item in
                    rawItemStorageRejectionReason(for: item) == nil ? nil : item.id
                }
            )
            let sanitizedEncodedItemByteCounts = try Dictionary(
                uniqueKeysWithValues: sanitizedItems.map { item in
                    // Legacy rows may predate every per-item limit. Preserve
                    // them for shrink-only recovery without immediately
                    // duplicating or base64-expanding a known-oversized item.
                    if rawOversizedItemIDs.contains(item.id) {
                        return (item.id, 0)
                    }
                    return (item.id, try accountedEncodedItemByteCount(for: item))
                }
            )
            historyIDs = sanitizedItems.map(\.id)
            itemsByID = Dictionary(uniqueKeysWithValues: sanitizedItems.map { ($0.id, $0) })
            encodedItemByteCountsByID = sanitizedEncodedItemByteCounts
            rawOversizedLegacyItemIDs = rawOversizedItemIDs
            repositoryRevision = loadedRevision
            if loadedFromLegacyRow {
                blobReferencesByItemID = Dictionary(
                    uniqueKeysWithValues: sanitizedItems.compactMap { item in
                        guard let imageData = item.imagePNGData else { return nil }
                        return (
                            item.id,
                            PersistedClipboardState.ImageBlobReference(
                                byteCount: imageData.count
                            )
                        )
                    }
                )
                persistedBlobIDs.removeAll()
            } else {
                blobReferencesByItemID = state.imageBlobReferencesByItemID
                persistedBlobIDs = Set(state.imageBlobReferencesByItemID.values.map(\.blobID))
            }
            var defaultGroup = ClipboardGroup.defaultGroup
            defaultGroup.mode = state.defaultGroupMode ?? defaultGroup.mode
            var persistedVoiceGroup = state.groups.first(where: { $0.id == ClipboardGroup.voiceGroup.id }) ?? .voiceGroup
            if (state.schemaVersion ?? 0) < 5 {
                persistedVoiceGroup.allowsCrossGroupPaste = true
            }
            groupsByID = [
                ClipboardGroup.defaultGroup.id: defaultGroup,
                ClipboardGroup.voiceGroup.id: persistedVoiceGroup,
            ]
            for group in state.groups where !ClipboardGroup.reservedGroupIDs.contains(group.id) {
                groupsByID[group.id] = group
            }
            groupOrder = [ClipboardGroup.defaultGroup.id, ClipboardGroup.voiceGroup.id]
            groupOrder.append(
                contentsOf: state.groups.map(\.id).filter { !ClipboardGroup.reservedGroupIDs.contains($0) }
            )
            let legacyDefaultEntries = state.groupEntries.first(where: { $0.groupID == ClipboardGroup.defaultGroup.id })?.itemIDs ?? []
            let voiceEntries = state.groupEntries.first(where: { $0.groupID == ClipboardGroup.voiceGroup.id })?.itemIDs ?? []
            groupEntries = [
                ClipboardGroup.defaultGroup.id: state.defaultGroupEntries ?? legacyDefaultEntries,
                ClipboardGroup.voiceGroup.id: voiceEntries,
            ]
            for entry in state.groupEntries where !ClipboardGroup.reservedGroupIDs.contains(entry.groupID) {
                groupEntries[entry.groupID] = entry.itemIDs
            }
            appAssignments = Dictionary(uniqueKeysWithValues: state.appAssignments.map { assignment in
                var assignment = assignment
                if assignment.groupID == ClipboardGroup.defaultGroup.id {
                    assignment.groupID = nil
                }
                return (assignment.bundleIdentifier, assignment)
            })
            let itemCountBeforeTrim = historyIDs.count
            trimHistoryIfNeeded()
            let didTrimForStorageLimits = historyIDs.count != itemCountBeforeTrim
            hasPersistedStateCapacityRejection = false
            hasLegacyOverCapacityState = loadedFromLegacyRow
                && currentStorageLimitViolation() != nil
            updateStoragePressureAfterCurrentStateChange()
            persistenceAvailability = confirmedPersistenceAvailability
            if !hasLegacyOverCapacityState,
               requiresVersionUpgrade || didSanitizePersistedFailure || didTrimForStorageLimits {
                schedulePersistence()
            }
        } catch {
            persistenceAvailability = .loadUnavailable
            if let loadError = error as? PersistedClipboardStateLoadError {
                switch loadError {
                case .persistedStateTooLarge:
                    lastStorageRejection = .totalByteLimitReached
                    storagePressureContext = .persistedStateRejected
                    hasPersistedStateCapacityRejection = true
                case .storageLimitExceeded(let reason):
                    lastStorageRejection = reason
                    storagePressureContext = .persistedStateRejected
                    hasPersistedStateCapacityRejection = true
                default:
                    break
                }
            }
            if let diagnostics {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .clipboard,
                        level: .warning,
                        event: "clipboard.state.load-failed",
                        message: "Clipboard state could not be restored."
                    )
                )
            }
        }

        await publishSnapshot()
    }

    private func attachPersistedImageBlobs(
        _ imageBlobs: [ClipboardPersistenceImageBlob],
        to state: inout PersistedClipboardState
    ) throws {
        let itemIDs = Set(state.items.map(\.id))
        guard state.imageBlobReferencesByItemID.keys.allSatisfy(itemIDs.contains) else {
            throw PersistedClipboardStateLoadError.missingGroupEntryItemID
        }

        var blobsByItemID: [UUID: ClipboardPersistenceImageBlob] = [:]
        var blobIDs: Set<UUID> = []
        var totalImageByteCount = 0
        for blob in imageBlobs {
            let reference = blob.reference
            guard reference.byteCount > 0,
                  reference.byteCount <= storageLimits.maximumImageByteCount,
                  reference.byteCount == blob.payload.count,
                  blobsByItemID[reference.itemID] == nil,
                  blobIDs.insert(reference.blobID).inserted else {
                throw PersistedClipboardStateLoadError.unavailable
            }
            let (nextTotal, overflowed) = totalImageByteCount.addingReportingOverflow(
                reference.byteCount
            )
            guard !overflowed,
                  nextTotal <= storageLimits.maximumTotalEncodedItemByteCount else {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(
                    .totalByteLimitReached
                )
            }
            totalImageByteCount = nextTotal
            blobsByItemID[reference.itemID] = blob
        }

        guard blobsByItemID.count == state.imageBlobReferencesByItemID.count else {
            throw PersistedClipboardStateLoadError.unavailable
        }
        for index in state.items.indices {
            let itemID = state.items[index].id
            guard let metadataReference = state.imageBlobReferencesByItemID[itemID] else {
                guard blobsByItemID[itemID] == nil else {
                    throw PersistedClipboardStateLoadError.unavailable
                }
                continue
            }
            guard let blob = blobsByItemID[itemID],
                  blob.reference.blobID == metadataReference.blobID,
                  blob.reference.itemID == itemID,
                  blob.reference.byteCount == metadataReference.byteCount else {
                throw PersistedClipboardStateLoadError.unavailable
            }
            state.items[index].imagePNGData = blob.payload
        }
    }

    @discardableResult
    func persistState() async -> Bool {
        guard persistenceAvailability != .loadUnavailable,
              let clipboardPersistenceStore else { return false }
        do {
            let preparedWrite = try preparedPersistenceWrite()
            let committedRevision = try await clipboardPersistenceStore.replaceClipboardPersistence(
                with: preparedWrite.snapshot
            )
            // A commit remains the repository's authoritative baseline even if
            // a newer actor mutation arrived while the repository was awaited.
            repositoryRevision = committedRevision
            persistedBlobIDs = preparedWrite.persistedBlobIDs
            let recoveredAvailability = confirmedPersistenceAvailability
            let shouldPublishRecovery = persistenceAvailability != recoveredAvailability
            persistenceAvailability = recoveredAvailability
            if shouldPublishRecovery {
                await publishPersistenceAvailabilityChange()
            }
            return true
        } catch {
            let shouldPublishFailure = persistenceAvailability != .saveFailed
            persistenceAvailability = .saveFailed
            hasPendingPersistence = true
            if let diagnostics {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .clipboard,
                        level: .warning,
                        event: "clipboard.state.persist-failed",
                        message: "Clipboard state could not be persisted."
                    )
                )
            }
            if shouldPublishFailure {
                await publishPersistenceAvailabilityChange()
            }
            return false
        }
    }

    /// Permanently removes an unreadable protected clipboard row after the UI
    /// has obtained explicit destructive confirmation from the user.
    ///
    /// Nothing in memory is changed until the durable row deletion succeeds.
    /// This keeps the original row and every session-only mutation recoverable
    /// when the backend is still inaccessible. A successful reset starts from
    /// an empty clipboard and restores ordinary persistence for later changes.
    @discardableResult
    public func resetUnavailablePersistedState() async -> ClipboardPersistenceResetResult {
        await ensureInitialized()
        guard persistenceAvailability == .loadUnavailable else {
            return .notRequired
        }
        await beginPersistenceReset()
        defer { endPersistenceReset() }

        // Another reset may have completed while this caller waited for the
        // mutation barrier. Do not perform a second destructive operation.
        guard persistenceAvailability == .loadUnavailable else {
            return .notRequired
        }
        guard let clipboardPersistenceStore else {
            return .notConfigured
        }

        let removalResult: ClipboardPersistenceRemovalResult
        do {
            removalResult = try await clipboardPersistenceStore.removeClipboardPersistence()
        } catch {
            if let diagnostics {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .clipboard,
                        level: .warning,
                        event: "clipboard.state.reset-failed",
                        message: "Clipboard state reset failed."
                    )
                )
            }
            return .failed
        }

        pendingPersistenceGeneration &+= 1
        let pendingTask = pendingPersistenceTask
        pendingPersistenceTask = nil
        pendingTask?.cancel()
        if let pendingTask {
            await pendingTask.value
        }

        historyIDs.removeAll()
        itemsByID.removeAll()
        encodedItemByteCountsByID.removeAll()
        rawOversizedLegacyItemIDs.removeAll()
        repositoryRevision = nil
        blobReferencesByItemID.removeAll()
        persistedBlobIDs.removeAll()
        groupsByID = [
            ClipboardGroup.defaultGroup.id: .defaultGroup,
            ClipboardGroup.voiceGroup.id: .voiceGroup,
        ]
        groupOrder = [ClipboardGroup.defaultGroup.id, ClipboardGroup.voiceGroup.id]
        groupEntries = [
            ClipboardGroup.defaultGroup.id: [],
            ClipboardGroup.voiceGroup.id: [],
        ]
        appAssignments.removeAll()
        pendingLeases.removeAll()
        compatibilityLeaseIDsByItemID.removeAll()
        pendingGroupEvents.removeAll()
        pendingGroupEventDescriptors.removeAll()
        hasPendingPersistence = false
        persistenceRetryAttempt = 0
        lastStorageRejection = nil
        storagePressureContext = nil
        hasLegacyOverCapacityState = false
        hasPersistedStateCapacityRejection = false
        stateRevision &+= 1
        isPersistenceCleanupPending = removalResult == .removedCleanupPending
        persistenceAvailability = confirmedPersistenceAvailability

        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: isPersistenceCleanupPending ? .warning : .info,
                    event: isPersistenceCleanupPending
                        ? "clipboard.state.reset-cleanup-pending"
                        : "clipboard.state.reset",
                    message: isPersistenceCleanupPending
                        ? "Clipboard state was reset, but protected storage cleanup remains pending."
                        : "Clipboard state was reset."
                )
            )
        }
        await publishPersistenceAvailabilityChange()
        return isPersistenceCleanupPending ? .resetCleanupPending : .reset
    }

    var confirmedPersistenceAvailability: ClipboardPersistenceAvailability {
        isPersistenceCleanupPending ? .cleanupPending : .available
    }

    private func beginPersistenceReset() async {
        while isHistoryMaintenanceActive || isPersistenceResetActive {
            await withCheckedContinuation { continuation in
                historyMaintenanceWaiters.append(continuation)
            }
        }
        isPersistenceResetActive = true
    }

    private func endPersistenceReset() {
        isPersistenceResetActive = false
        let waiters = historyMaintenanceWaiters
        historyMaintenanceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    struct PreparedClipboardPersistenceWrite {
        let snapshot: ClipboardPersistenceWriteSnapshot
        let persistedBlobIDs: Set<UUID>
    }

    func preparedPersistenceWrite(
        excluding excludedItemIDs: Set<UUID> = []
    ) throws -> PreparedClipboardPersistenceWrite {
        if let rejection = currentMetadataStorageRejectionReason() {
            throw PersistedClipboardStateLoadError.storageLimitExceeded(rejection)
        }
        for itemID in rawOversizedLegacyItemIDs where !excludedItemIDs.contains(itemID) {
            guard let item = itemsByID[itemID] else { continue }
            throw PersistedClipboardStateLoadError.storageLimitExceeded(
                rawItemStorageRejectionReason(for: item) ?? .itemTooLarge
            )
        }
        let includedItems = historyIDs.compactMap { itemID -> ClipboardHistoryItem? in
            guard !excludedItemIDs.contains(itemID) else { return nil }
            return itemsByID[itemID]
        }
        let includedReferences: [UUID: PersistedClipboardState.ImageBlobReference] = Dictionary(
            uniqueKeysWithValues: includedItems.compactMap {
                item -> (UUID, PersistedClipboardState.ImageBlobReference)? in
                guard let reference = blobReferencesByItemID[item.id] else { return nil }
                return (item.id, reference)
            }
        )
        let state = PersistedClipboardState(
            schemaVersion: PersistedClipboardState.currentSchemaVersion,
            items: historyIDs.compactMap { itemID in
                guard !excludedItemIDs.contains(itemID) else { return nil }
                return itemsByID[itemID]
            },
            imageBlobReferencesByItemID: includedReferences,
            groups: groupOrder
                .filter { $0 != ClipboardGroup.defaultGroup.id }
                .compactMap { groupsByID[$0] },
            groupEntries: groupOrder
                .filter { $0 != ClipboardGroup.defaultGroup.id }
                .map { groupID in
                PersistedClipboardState.GroupEntry(
                    groupID: groupID,
                    itemIDs: groupEntries[groupID, default: []].filter { !excludedItemIDs.contains($0) }
                )
            },
            defaultGroupEntries: groupEntries[ClipboardGroup.defaultGroup.id, default: []]
                .filter { !excludedItemIDs.contains($0) },
            defaultGroupMode: groupsByID[ClipboardGroup.defaultGroup.id]?.mode,
            appAssignments: sortedAppAssignments()
        )
        try validatePersistedState(in: state)
        try validateCurrentSchemaStorageLimits(in: state)
        let data = try encoder.encode(state)
        guard data.count <= storageLimits.maximumPersistedStateUTF8ByteCount else {
            throw PersistedClipboardStateLoadError.persistedStateTooLarge
        }
        let references = try includedItems.compactMap { item -> ClipboardPersistenceBlobReference? in
            guard let imageData = item.imagePNGData else {
                guard includedReferences[item.id] == nil else {
                    throw PersistedClipboardStateLoadError.unavailable
                }
                return nil
            }
            guard let reference = includedReferences[item.id],
                  reference.byteCount == imageData.count else {
                throw PersistedClipboardStateLoadError.unavailable
            }
            return ClipboardPersistenceBlobReference(
                blobID: reference.blobID,
                itemID: item.id,
                byteCount: reference.byteCount
            )
        }
        let persistedIDs = Set(references.map { $0.blobID })
        let retainedReferences = references.filter { persistedBlobIDs.contains($0.blobID) }
        let newBlobs = try references.compactMap { reference -> ClipboardPersistenceImageBlob? in
            guard !persistedBlobIDs.contains(reference.blobID) else { return nil }
            guard let payload = itemsByID[reference.itemID]?.imagePNGData,
                  payload.count == reference.byteCount else {
                throw PersistedClipboardStateLoadError.unavailable
            }
            return ClipboardPersistenceImageBlob(reference: reference, payload: payload)
        }
        return PreparedClipboardPersistenceWrite(
            snapshot: ClipboardPersistenceWriteSnapshot(
                expectedRevision: repositoryRevision,
                metadata: data,
                newImageBlobs: newBlobs,
                retainedImageBlobReferences: retainedReferences
            ),
            persistedBlobIDs: persistedIDs
        )
    }

    func publishAndSchedulePersistence() async {
        stateRevision &+= 1
        let revision = stateRevision
        let snapshot = buildClipboardSnapshot()
        let descriptors = pendingGroupEventDescriptors.map { descriptor in
            var descriptor = descriptor
            descriptor.storeRevision = revision
            return descriptor
        }
        pendingGroupEventDescriptors.removeAll()
        let events = pendingGroupEvents.map { event in
            var event = event
            event.storeRevision = revision
            return event
        }
        pendingGroupEvents.removeAll()

        let previousPublication = publicationTailTask
        let eventBus = self.eventBus
        let diagnostics = self.diagnostics
        let clipboardGroupEventSink = self.clipboardGroupEventSink
        publicationGeneration &+= 1
        let generation = publicationGeneration
        let publicationTask = Task {
            if let previousPublication {
                await previousPublication.value
            }
            await Self.publishSnapshotPayload(
                snapshot,
                eventBus: eventBus,
                diagnostics: diagnostics
            )
            if let clipboardGroupEventSink {
                for descriptor in descriptors {
                    _ = await clipboardGroupEventSink.submit(descriptor)
                }
            }
            for event in events {
                await eventBus.publish(.clipboardGroupEvent(event))
            }
        }
        publicationTailTask = publicationTask
        lastCapturedPublicationRevision = revision
        let readyWaiters = publicationRevisionWaiters.filter {
            $0.revision <= revision
        }
        publicationRevisionWaiters.removeAll {
            $0.revision <= revision
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        await publicationTask.value
        if generation == publicationGeneration {
            publicationTailTask = nil
        }
        schedulePersistence()
    }

    func notePersistedStateMutation() {
        stateRevision &+= 1
        schedulePersistence()
    }

    func publishSnapshot() async {
        let snapshot = buildClipboardSnapshot()
        await Self.publishSnapshotPayload(
            snapshot,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
    }

    /// Orders availability-only snapshots behind every already-captured
    /// clipboard publication so an older mutation snapshot cannot make a later
    /// persistence failure or recovery disappear in the UI projection.
    private func publishPersistenceAvailabilityChange() async {
        let snapshot = buildClipboardSnapshot()
        let previousPublication = publicationTailTask
        let eventBus = self.eventBus
        let diagnostics = self.diagnostics
        publicationGeneration &+= 1
        let generation = publicationGeneration
        let publicationTask = Task {
            if let previousPublication {
                await previousPublication.value
            }
            await Self.publishSnapshotPayload(
                snapshot,
                eventBus: eventBus,
                diagnostics: diagnostics
            )
        }
        publicationTailTask = publicationTask
        await publicationTask.value
        if generation == publicationGeneration {
            publicationTailTask = nil
        }
    }

    private static func publishSnapshotPayload(
        _ snapshot: ClipboardStoreSnapshot,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder?
    ) async {
        await eventBus.publish(.clipboardUpdated(snapshot))
        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: .debug,
                    event: "clipboard.snapshot",
                    message: "Clipboard store updated.",
                    metadata: [
                        "historyCount": String(snapshot.items.count),
                        "groupCount": String(snapshot.groups.count),
                    ]
                )
            )
        }
    }

    func schedulePersistence() {
        guard clipboardPersistenceStore != nil else { return }
        hasPendingPersistence = true
        persistenceRetryAttempt = 0
        guard persistenceAvailability != .loadUnavailable,
              !isHistoryMaintenanceActive,
              !hasLegacyOverCapacityState else { return }

        schedulePersistenceAttempt(after: Self.persistenceDebounceInterval)
    }

    private func schedulePersistenceRetry() {
        guard clipboardPersistenceStore != nil,
              persistenceAvailability != .loadUnavailable,
              !isHistoryMaintenanceActive else { return }
        hasPendingPersistence = true
        let delayIndex = min(
            persistenceRetryAttempt,
            persistenceRetryDelays.count - 1
        )
        let delay = persistenceRetryDelays[delayIndex]
        persistenceRetryAttempt &+= 1
        schedulePersistenceAttempt(after: delay)
    }

    private func schedulePersistenceAttempt(after delay: Duration) {
        let previousTask = pendingPersistenceTask
        let persistenceSleep = self.persistenceSleep
        previousTask?.cancel()
        pendingPersistenceGeneration &+= 1
        let generation = pendingPersistenceGeneration
        pendingPersistenceTask = Task {
            if let previousTask {
                await previousTask.value
            }
            do {
                try await persistenceSleep(delay)
            } catch is CancellationError {
                return
            } catch {
                if let diagnostics = self.diagnostics {
                    await diagnostics.record(
                        DiagnosticEvent(
                            subsystem: .clipboard,
                            level: .warning,
                            event: "clipboard.persistence.schedule-failed",
                            message: "Persistence scheduling interrupted unexpectedly."
                        )
                    )
                }
                return
            }

            await self.persistStateIfCurrent(generation: generation)
        }
    }

    /// Persists the latest clipboard state without waiting for the debounce window.
    ///
    /// Application shutdown calls this only after clipboard producers and the
    /// group-event scheduler have stopped. The revision loop also keeps the
    /// method correct if a final in-flight mutation resumes while the settings
    /// store is being written.
    @discardableResult
    public func flushPendingPersistenceWrites() async -> ClipboardPersistenceFlushResult {
        await ensureInitialized()
        guard clipboardPersistenceStore != nil else { return .notConfigured }
        guard persistenceAvailability != .loadUnavailable else {
            return .loadUnavailable
        }
        if hasLegacyOverCapacityState {
            return hasPendingPersistence ? .saveFailed : .persisted
        }

        while true {
            await waitForHistoryMaintenanceIfNeeded()

            pendingPersistenceGeneration &+= 1
            let flushGeneration = pendingPersistenceGeneration
            let pendingTask = pendingPersistenceTask
            pendingPersistenceTask = nil
            pendingTask?.cancel()
            if let pendingTask {
                await pendingTask.value
            }

            guard !isHistoryMaintenanceActive else { continue }
            let revision = stateRevision
            guard await persistState() else {
                hasPendingPersistence = true
                schedulePersistenceRetry()
                return .saveFailed
            }

            guard !isHistoryMaintenanceActive,
                  revision == stateRevision,
                  flushGeneration == pendingPersistenceGeneration else {
                continue
            }
            pendingPersistenceTask = nil
            hasPendingPersistence = false
            persistenceRetryAttempt = 0
            return .persisted
        }
    }

    /// Drains the latest clipboard revision for application shutdown. Transient
    /// save failures follow the same capped backoff as background persistence,
    /// so the application termination timeout can reject quitting instead of
    /// falsely reporting cleanup completion. A load-unavailable row is never
    /// rewritten and is returned as an explicit terminal session outcome.
    @discardableResult
    public func drainPersistenceForApplicationShutdown() async -> ClipboardPersistenceFlushResult {
        let initialResult = await flushPendingPersistenceWrites()
        switch initialResult {
        case .persisted, .notConfigured, .loadUnavailable:
            return initialResult
        case .saveFailed:
            break
        }

        while true {
            if persistenceAvailability == .loadUnavailable {
                return .loadUnavailable
            }
            if persistenceAvailability == confirmedPersistenceAvailability,
               !hasPendingPersistence {
                return .persisted
            }
            if pendingPersistenceTask == nil {
                schedulePersistenceRetry()
            }
            guard let retryTask = pendingPersistenceTask else {
                return persistenceAvailability == .loadUnavailable
                    ? .loadUnavailable
                    : .saveFailed
            }
            await retryTask.value
        }
    }

    func nextAvailableFallbackPriority() -> Int {
        let used = Set(groupsByID.values.compactMap { group in
            group.fallbackPriority.flatMap { $0 > 0 ? $0 : nil }
        })
        return (1...(used.count + 1)).first(where: { !used.contains($0) }) ?? 1
    }

    func isFallbackPriorityAvailable(_ priority: Int, excluding groupID: UUID) -> Bool {
        !groupsByID.values.contains { group in
            group.id != groupID && group.fallbackPriority == priority
        }
    }

    func persistStateIfCurrent(generation: UInt64) async {
        guard persistenceAvailability != .loadUnavailable,
              generation == pendingPersistenceGeneration else { return }
        let didPersist = await persistState()
        if generation == pendingPersistenceGeneration {
            pendingPersistenceTask = nil
            if didPersist {
                hasPendingPersistence = false
                persistenceRetryAttempt = 0
            } else {
                schedulePersistenceRetry()
            }
        }
    }

    private func validatePersistedState(
        in state: PersistedClipboardState
    ) throws {
        var itemIDs: Set<UUID> = []
        for item in state.items where !itemIDs.insert(item.id).inserted {
            throw PersistedClipboardStateLoadError.duplicateItemID
        }

        if (state.schemaVersion ?? 0) >= PersistedClipboardState.currentSchemaVersion {
            guard Set(state.imageBlobReferencesByItemID.keys).isSubset(of: itemIDs) else {
                throw PersistedClipboardStateLoadError.unavailable
            }
            var blobIDs: Set<UUID> = []
            for item in state.items {
                let reference = state.imageBlobReferencesByItemID[item.id]
                guard (item.imagePNGData == nil) == (reference == nil),
                      reference?.byteCount == item.imagePNGData?.count else {
                    throw PersistedClipboardStateLoadError.unavailable
                }
                if let reference,
                   !blobIDs.insert(reference.blobID).inserted {
                    throw PersistedClipboardStateLoadError.unavailable
                }
            }
        } else if !state.imageBlobReferencesByItemID.isEmpty {
            throw PersistedClipboardStateLoadError.unavailable
        }

        var groupIDs: Set<UUID> = []
        for group in state.groups where !groupIDs.insert(group.id).inserted {
            throw PersistedClipboardStateLoadError.duplicateGroupID
        }

        var groupEntryIDs: Set<UUID> = []
        for entry in state.groupEntries {
            guard groupEntryIDs.insert(entry.groupID).inserted else {
                throw PersistedClipboardStateLoadError.duplicateGroupEntryID
            }
            var entryItemIDs: Set<UUID> = []
            for itemID in entry.itemIDs where !entryItemIDs.insert(itemID).inserted {
                throw PersistedClipboardStateLoadError.duplicateGroupItemID
            }
        }

        if let defaultGroupEntries = state.defaultGroupEntries {
            var defaultItemIDs: Set<UUID> = []
            for itemID in defaultGroupEntries where !defaultItemIDs.insert(itemID).inserted {
                throw PersistedClipboardStateLoadError.duplicateGroupItemID
            }
        }

        var bundleIdentifiers: Set<String> = []
        for assignment in state.appAssignments
        where !bundleIdentifiers.insert(assignment.bundleIdentifier).inserted {
            throw PersistedClipboardStateLoadError.duplicateApplicationBundleIdentifier
        }

        let knownGroupIDs = Set(state.groups.map(\.id)).union(ClipboardGroup.reservedGroupIDs)
        guard state.items.allSatisfy({ knownGroupIDs.contains($0.groupID) }) else {
            throw PersistedClipboardStateLoadError.unknownItemGroupID
        }

        var fallbackPriorities: Set<Int> = []
        for group in state.groups {
            guard let priority = group.fallbackPriority else { continue }
            guard priority > 0 else {
                throw PersistedClipboardStateLoadError.nonPositiveFallbackPriority
            }
            guard fallbackPriorities.insert(priority).inserted else {
                throw PersistedClipboardStateLoadError.duplicateFallbackPriority
            }
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })
        var referencedItemIDs: Set<UUID> = []
        let isCurrentSchema = (state.schemaVersion ?? 0) >= PersistedClipboardState.currentSchemaVersion

        for entry in state.groupEntries {
            guard knownGroupIDs.contains(entry.groupID) else {
                throw PersistedClipboardStateLoadError.unknownGroupEntryID
            }

            // Before `defaultGroupEntries` became authoritative, the default
            // group could also be represented inside `groupEntries`. If both
            // encodings exist in a legacy row, validate only the representation
            // the loader will actually use. Current rows must remain a single,
            // closed graph and therefore validate every supplied coordinate.
            if !isCurrentSchema,
               state.defaultGroupEntries != nil,
               entry.groupID == ClipboardGroup.defaultGroupID {
                continue
            }
            try validatePersistedMembership(
                itemIDs: entry.itemIDs,
                groupID: entry.groupID,
                itemsByID: itemsByID,
                referencedItemIDs: &referencedItemIDs
            )
        }

        if let defaultGroupEntries = state.defaultGroupEntries {
            try validatePersistedMembership(
                itemIDs: defaultGroupEntries,
                groupID: ClipboardGroup.defaultGroupID,
                itemsByID: itemsByID,
                referencedItemIDs: &referencedItemIDs
            )
        }

        for assignment in state.appAssignments {
            guard let groupID = assignment.groupID else { continue }
            guard knownGroupIDs.contains(groupID) else {
                throw PersistedClipboardStateLoadError.unknownApplicationAssignmentGroupID
            }
        }
    }

    private func validateCurrentSchemaStorageLimits(
        in state: PersistedClipboardState
    ) throws {
        var totalEncodedByteCount = 0
        for item in state.items {
            if let rejection = rawItemStorageRejectionReason(for: item) {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(rejection)
            }
            let encodedByteCount = try accountedEncodedItemByteCount(for: item)
            if let rejection = itemStorageRejectionReason(
                for: item,
                encodedItemByteCount: encodedByteCount
            ) {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(rejection)
            }
            let (nextTotal, overflowed) = totalEncodedByteCount.addingReportingOverflow(
                encodedByteCount
            )
            guard !overflowed else {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(
                    .totalByteLimitReached
                )
            }
            totalEncodedByteCount = nextTotal
        }
        guard totalEncodedByteCount <= storageLimits.maximumTotalEncodedItemByteCount else {
            throw PersistedClipboardStateLoadError.storageLimitExceeded(
                .totalByteLimitReached
            )
        }

        var activeItemIDs: Set<UUID> = []
        for entry in state.groupEntries {
            if entry.groupID == ClipboardGroup.defaultGroupID,
               state.defaultGroupEntries != nil {
                continue
            }
            guard entry.itemIDs.count <= storageLimits.maximumActiveItemCountPerGroup else {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(
                    .activeItemLimitReached
                )
            }
            activeItemIDs.formUnion(entry.itemIDs)
        }
        if let defaultGroupEntries = state.defaultGroupEntries {
            guard defaultGroupEntries.count <= storageLimits.maximumActiveItemCountPerGroup else {
                throw PersistedClipboardStateLoadError.storageLimitExceeded(
                    .activeItemLimitReached
                )
            }
            activeItemIDs.formUnion(defaultGroupEntries)
        }
        guard activeItemIDs.count <= storageLimits.maximumActiveItemCount,
              state.items.count - activeItemIDs.count
                <= storageLimits.maximumHistoryOnlyItemCount else {
            let reason: ClipboardStorageRejectionReason = activeItemIDs.count
                > storageLimits.maximumActiveItemCount
                ? .activeItemLimitReached
                : .historyItemLimitReached
            throw PersistedClipboardStateLoadError.storageLimitExceeded(reason)
        }
    }

    private func validatePersistedMembership(
        itemIDs: [UUID],
        groupID: UUID,
        itemsByID: [UUID: ClipboardHistoryItem],
        referencedItemIDs: inout Set<UUID>
    ) throws {
        for itemID in itemIDs {
            guard let item = itemsByID[itemID] else {
                throw PersistedClipboardStateLoadError.missingGroupEntryItemID
            }
            guard referencedItemIDs.insert(itemID).inserted else {
                throw PersistedClipboardStateLoadError.itemReferencedByMultipleGroupEntries
            }
            guard item.groupID == groupID else {
                throw PersistedClipboardStateLoadError.itemGroupIDMismatch
            }
        }
    }
}
