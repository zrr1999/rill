import Foundation
import RillCore

extension DeliveryStack {
    private static let encodedItemAccountingReserve = 1_024

    private struct StorageAdmissionPlan {
        let encodedItemByteCount: Int
        let evictedHistoryItemIDs: Set<UUID>
    }

    struct ApplicationAssignmentMovePlan {
        let targetGroupID: UUID
        let projectedItemsByID: [UUID: ClipboardHistoryItem]
        let encodedItemByteCountsByID: [UUID: Int]
        let activeItemIDs: Set<UUID>
    }

    func ensureGroupExists(id: UUID) {
        guard groupsByID[id] == nil else { return }
        if !ClipboardGroup.reservedGroupIDs.contains(id) {
            let customGroupCount = groupOrder.filter {
                !ClipboardGroup.reservedGroupIDs.contains($0)
            }.count
            guard customGroupCount < storageLimits.maximumCustomGroupCount else {
                lastStorageRejection = .metadataLimitReached
                if !hasLegacyOverCapacityState && !hasPersistedStateCapacityRejection {
                    storagePressureContext = .mutationRejected
                }
                return
            }
        }
        groupsByID[id] = id == ClipboardGroup.voiceGroup.id
            ? .voiceGroup
            : ClipboardGroup(id: id, name: "Recovered Group")
        if !groupOrder.contains(id) {
            groupOrder.append(id)
        }
        if groupEntries[id] == nil {
            groupEntries[id] = []
        }
        notePersistedStateMutation()
    }

    func store(
        _ item: ClipboardHistoryItem,
        inGroup groupID: UUID,
        emitsGroupEvent: Bool = true
    ) -> ClipboardStorageMutationResult {
        let isNew = itemsByID[item.id] == nil
        var storedItem = item
        storedItem.groupID = groupID
        storedItem.latestError = ClipboardDeliveryFailureCode.sanitizedStoredValue(
            storedItem.latestError
        )
        let admission: StorageAdmissionPlan
        switch storageAdmissionPlan(for: storedItem) {
        case .success(let plan):
            admission = plan
        case .failure(let reason):
            lastStorageRejection = reason
            if !hasLegacyOverCapacityState && !hasPersistedStateCapacityRejection {
                storagePressureContext = .mutationRejected
            }
            return .rejected(reason)
        }

        removeHistoryOnlyItems(ids: admission.evictedHistoryItemIDs)
        ensureGroupExists(id: groupID)
        storedItem = upsertHistoryItem(
            storedItem,
            encodedItemByteCount: admission.encodedItemByteCount
        )
        updatePendingPlacement(for: storedItem)
        updateStoragePressureAfterCurrentStateChange()
        let finalItem = itemsByID[storedItem.id] ?? storedItem
        if emitsGroupEvent {
            queueGroupEvent(
                kind: isNew ? .itemCreated : .itemEdited,
                item: finalItem
            )
        }
        return .accepted(evictedHistoryItemCount: admission.evictedHistoryItemIDs.count)
    }

    private func storageAdmissionPlan(
        for item: ClipboardHistoryItem
    ) -> Result<StorageAdmissionPlan, ClipboardStorageRejectionReason> {
        // Reject oversized shapes before JSONEncoder can duplicate text. Image
        // bytes are accounted separately below and are never Base64-expanded.
        if let rejection = rawItemStorageRejectionReason(for: item) {
            return .failure(rejection)
        }
        if groupsByID[item.groupID] == nil,
           !ClipboardGroup.reservedGroupIDs.contains(item.groupID) {
            let projectedGroups = groupOrder.compactMap { groupID in
                guard !ClipboardGroup.reservedGroupIDs.contains(groupID) else { return nil }
                return groupsByID[groupID]
            } + [ClipboardGroup(id: item.groupID, name: "Recovered Group")]
            if let rejection = metadataStorageRejectionReason(
                groups: projectedGroups,
                appAssignments: Array(appAssignments.values)
            ) {
                return .failure(rejection)
            }
        }
        let encodedItemByteCount: Int
        do {
            encodedItemByteCount = try accountedEncodedItemByteCount(for: item)
        } catch {
            return .failure(.itemEncodingFailed)
        }
        if let rejection = itemStorageRejectionReason(
            for: item,
            encodedItemByteCount: encodedItemByteCount
        ) {
            return .failure(rejection)
        }

        let existingItemIDs = Set(itemsByID.keys)
        var projectedItemIDs = existingItemIDs
        projectedItemIDs.insert(item.id)

        var projectedActiveIDs = activeItemIDs()
        projectedActiveIDs.remove(item.id)
        let itemHasLease = pendingLeases.values.contains { $0.itemID == item.id }
            || compatibilityLeaseIDsByItemID[item.id] != nil
        if shouldQueue(item) || itemHasLease {
            projectedActiveIDs.insert(item.id)
        }
        guard projectedActiveIDs.count <= storageLimits.maximumActiveItemCount else {
            return .failure(.activeItemLimitReached)
        }

        var projectedGroupActiveIDs = Set(groupEntries[item.groupID, default: []])
        projectedGroupActiveIDs.remove(item.id)
        projectedGroupActiveIDs.formUnion(
            pendingLeases.values
                .filter { $0.groupID == item.groupID }
                .map(\.itemID)
        )
        if shouldQueue(item) || itemHasLease {
            projectedGroupActiveIDs.insert(item.id)
        }
        guard projectedGroupActiveIDs.count <= storageLimits.maximumActiveItemCountPerGroup else {
            return .failure(.activeItemLimitReached)
        }

        var projectedRawOversizedItemIDs = rawOversizedLegacyItemIDs
        projectedRawOversizedItemIDs.remove(item.id)
        var projectedEncodedByteCount = knownEncodedItemByteCount(excluding: item.id)
        let (nextByteCount, overflowed) = projectedEncodedByteCount.addingReportingOverflow(
            encodedItemByteCount
        )
        projectedEncodedByteCount = overflowed ? Int.max : nextByteCount
        var projectedHistoryOnlyCount = projectedItemIDs.count - projectedActiveIDs.count
        var evictedHistoryItemIDs: Set<UUID> = []
        let currentActiveIDs = activeItemIDs()
        let evictionCandidates = historyIDs.reversed().filter {
            $0 != item.id && !currentActiveIDs.contains($0)
        }

        for candidateID in evictionCandidates {
            guard projectedHistoryOnlyCount > storageLimits.maximumHistoryOnlyItemCount
                    || !projectedRawOversizedItemIDs.isEmpty
                    || projectedEncodedByteCount > storageLimits.maximumTotalEncodedItemByteCount
            else {
                break
            }
            guard projectedItemIDs.remove(candidateID) != nil else { continue }
            evictedHistoryItemIDs.insert(candidateID)
            projectedHistoryOnlyCount -= 1
            if projectedRawOversizedItemIDs.remove(candidateID) != nil {
                continue
            }
            let candidateByteCount = encodedItemByteCountsByID[candidateID]
                ?? encodedItemByteCountForExistingItem(candidateID)
            projectedEncodedByteCount = max(0, projectedEncodedByteCount - candidateByteCount)
        }

        guard projectedHistoryOnlyCount <= storageLimits.maximumHistoryOnlyItemCount else {
            return .failure(.historyItemLimitReached)
        }
        guard projectedRawOversizedItemIDs.isEmpty,
              projectedEncodedByteCount <= storageLimits.maximumTotalEncodedItemByteCount else {
            return .failure(.totalByteLimitReached)
        }
        return .success(
            StorageAdmissionPlan(
                encodedItemByteCount: encodedItemByteCount,
                evictedHistoryItemIDs: evictedHistoryItemIDs
            )
        )
    }

    func itemStorageRejectionReason(
        for item: ClipboardHistoryItem,
        encodedItemByteCount: Int
    ) -> ClipboardStorageRejectionReason? {
        if let rejection = rawItemStorageRejectionReason(for: item) {
            return rejection
        }
        guard encodedItemByteCount <= storageLimits.maximumEncodedItemByteCount else {
            return .itemTooLarge
        }
        return nil
    }

    func rawItemStorageRejectionReason(
        for item: ClipboardHistoryItem
    ) -> ClipboardStorageRejectionReason? {
        if item.imagePNGData?.isEmpty == true {
            return .imageRepresentationInvalid
        }
        guard item.text.utf8.count <= storageLimits.maximumTextUTF8ByteCount,
              (item.imagePNGData?.count ?? 0) <= storageLimits.maximumImageByteCount,
              item.fileURLs.count <= storageLimits.maximumFileURLCount,
              item.captureTags.count <= storageLimits.maximumCaptureTagCount,
              Set(item.captureTags).count == item.captureTags.count,
              item.alternatives.count <= storageLimits.maximumAlternativeCount,
              item.tags.count <= storageLimits.maximumTagCount,
              optionalStringFits(
                  item.workflow?.fallbackName,
                  limit: storageLimits.maximumWorkflowNameUTF8ByteCount
              ),
              optionalStringFits(
                  item.sourceApplicationName,
                  limit: storageLimits.maximumSourceApplicationNameUTF8ByteCount
              ),
              optionalStringFits(
                  item.sourceBundleIdentifier,
                  limit: storageLimits.maximumSourceBundleIdentifierUTF8ByteCount
              ),
              stringsFit(
                  item.fileURLs.map(\.absoluteString),
                  perValueLimit: storageLimits.maximumFileURLUTF8ByteCount,
                  totalLimit: storageLimits.maximumTotalFileURLUTF8ByteCount
              ),
              stringsFit(
                  item.alternatives,
                  perValueLimit: storageLimits.maximumAlternativeUTF8ByteCount,
                  totalLimit: storageLimits.maximumTotalAlternativeUTF8ByteCount
              ),
              stringsFit(
                  item.tags,
                  perValueLimit: storageLimits.maximumTagUTF8ByteCount,
                  totalLimit: storageLimits.maximumTotalTagUTF8ByteCount
              ) else {
            return .itemTooLarge
        }
        return nil
    }

    func optionalStringFits(_ value: String?, limit: Int) -> Bool {
        (value?.utf8.count ?? 0) <= limit
    }

    func metadataStorageRejectionReason(
        groups: [ClipboardGroup],
        appAssignments: [ClipboardAppAssignment]
    ) -> ClipboardStorageRejectionReason? {
        guard groups.count <= storageLimits.maximumCustomGroupCount,
              groups.allSatisfy({
                  $0.name.utf8.count <= storageLimits.maximumGroupNameUTF8ByteCount
              }),
              appAssignments.count <= storageLimits.maximumApplicationAssignmentCount,
              appAssignments.allSatisfy({ assignment in
                  assignment.applicationName.utf8.count
                      <= storageLimits.maximumAssignmentApplicationNameUTF8ByteCount
                      && assignment.bundleIdentifier.utf8.count
                          <= storageLimits.maximumAssignmentBundleIdentifierUTF8ByteCount
              }) else {
            return .metadataLimitReached
        }
        return nil
    }

    func currentMetadataStorageRejectionReason() -> ClipboardStorageRejectionReason? {
        metadataStorageRejectionReason(
            groups: groupOrder.compactMap { groupID in
                guard !ClipboardGroup.reservedGroupIDs.contains(groupID) else { return nil }
                return groupsByID[groupID]
            },
            appAssignments: Array(appAssignments.values)
        )
    }

    func stringsFit(
        _ values: [String],
        perValueLimit: Int,
        totalLimit: Int
    ) -> Bool {
        var total = 0
        for value in values {
            let count = value.utf8.count
            guard count <= perValueLimit else { return false }
            let (nextTotal, overflowed) = total.addingReportingOverflow(count)
            guard !overflowed, nextTotal <= totalLimit else { return false }
            total = nextTotal
        }
        return true
    }

    func accountedEncodedItemByteCount(
        for item: ClipboardHistoryItem
    ) throws -> Int {
        var metadataOnlyItem = item
        let imageByteCount = metadataOnlyItem.imagePNGData?.count ?? 0
        metadataOnlyItem.imagePNGData = nil
        let encodedMetadataByteCount = try encoder.encode(metadataOnlyItem).count
        let (contentByteCount, contentOverflowed) = encodedMetadataByteCount
            .addingReportingOverflow(imageByteCount)
        guard !contentOverflowed else { throw CocoaError(.coderInvalidValue) }
        let (accountedByteCount, overflowed) = contentByteCount.addingReportingOverflow(
            Self.encodedItemAccountingReserve
        )
        guard !overflowed else { throw CocoaError(.coderInvalidValue) }
        return accountedByteCount
    }

    func refreshEncodedItemByteCount(for item: ClipboardHistoryItem) {
        if rawItemStorageRejectionReason(for: item) != nil {
            rawOversizedLegacyItemIDs.insert(item.id)
            encodedItemByteCountsByID[item.id] = 0
            return
        }
        rawOversizedLegacyItemIDs.remove(item.id)
        if let byteCount = try? accountedEncodedItemByteCount(for: item) {
            encodedItemByteCountsByID[item.id] = byteCount
        }
    }

    private func encodedItemByteCountForExistingItem(_ itemID: UUID) -> Int {
        if rawOversizedLegacyItemIDs.contains(itemID) {
            return 0
        }
        guard let item = itemsByID[itemID],
              let byteCount = try? accountedEncodedItemByteCount(for: item) else {
            return Int.max
        }
        encodedItemByteCountsByID[itemID] = byteCount
        return byteCount
    }

    func totalEncodedItemByteCount(excluding excludedItemID: UUID? = nil) -> Int {
        if rawOversizedLegacyItemIDs.contains(where: { $0 != excludedItemID }) {
            return Int.max
        }
        return knownEncodedItemByteCount(excluding: excludedItemID)
    }

    private func knownEncodedItemByteCount(excluding excludedItemID: UUID? = nil) -> Int {
        var total = 0
        for itemID in historyIDs
        where itemID != excludedItemID && !rawOversizedLegacyItemIDs.contains(itemID) {
            let byteCount = encodedItemByteCountsByID[itemID]
                ?? encodedItemByteCountForExistingItem(itemID)
            let (nextTotal, overflowed) = total.addingReportingOverflow(byteCount)
            if overflowed { return Int.max }
            total = nextTotal
        }
        return total
    }

    func currentStorageLimitViolation() -> ClipboardStorageRejectionReason? {
        if let rejection = currentMetadataStorageRejectionReason() {
            return rejection
        }
        for itemID in historyIDs {
            guard let item = itemsByID[itemID] else { continue }
            let byteCount = encodedItemByteCountsByID[itemID]
                ?? encodedItemByteCountForExistingItem(itemID)
            if let rejection = itemStorageRejectionReason(
                for: item,
                encodedItemByteCount: byteCount
            ) {
                return rejection
            }
        }

        let activeIDs = activeItemIDs()
        if activeIDs.count > storageLimits.maximumActiveItemCount {
            return .activeItemLimitReached
        }
        for groupID in groupOrder {
            var groupActiveIDs = Set(groupEntries[groupID, default: []])
            groupActiveIDs.formUnion(
                pendingLeases.values.filter { $0.groupID == groupID }.map(\.itemID)
            )
            if groupActiveIDs.count > storageLimits.maximumActiveItemCountPerGroup {
                return .activeItemLimitReached
            }
        }
        if historyIDs.count - activeIDs.count > storageLimits.maximumHistoryOnlyItemCount {
            return .historyItemLimitReached
        }
        if totalEncodedItemByteCount() > storageLimits.maximumTotalEncodedItemByteCount {
            return .totalByteLimitReached
        }
        return nil
    }

    func updateStoragePressureAfterCurrentStateChange() {
        if hasPersistedStateCapacityRejection {
            storagePressureContext = .persistedStateRejected
            return
        }
        let violation = currentStorageLimitViolation()
        lastStorageRejection = violation
        if violation != nil {
            hasLegacyOverCapacityState = true
            storagePressureContext = .legacyOverCapacity
        } else {
            hasLegacyOverCapacityState = false
            storagePressureContext = nil
        }
    }

    /// Queues a content-free scheduler descriptor for every workflow-visible
    /// mutation, while retaining the transient descriptor fan-out only when the
    /// item permits workflow capture.
    func queueGroupEvent(
        kind: ClipboardGroupEventKind,
        item: ClipboardHistoryItem
    ) {
        let descriptor = ClipboardGroupEventDescriptor(
            kind: kind,
            groupID: item.groupID,
            itemID: item.id,
            itemVersion: item.version,
            captureTags: item.captureTags
        )
        pendingGroupEventDescriptors.append(descriptor)
        if shouldPublishGroupEvent(for: item) {
            pendingGroupEvents.append(descriptor)
        }
    }

    func shouldPublishGroupEvent(for item: ClipboardHistoryItem) -> Bool {
        !item.captureTags.contains(.excludeFromWorkflowCapture)
    }

    @discardableResult
    func upsertHistoryItem(
        _ item: ClipboardHistoryItem,
        encodedItemByteCount: Int
    ) -> ClipboardHistoryItem {
        let previousItem = itemsByID[item.id]
        let previousGroupID = previousItem?.groupID
        var storedItem = item
        if let previousItem {
            storedItem.version = previousItem.version.advanced()
        }
        reconcileImageBlobReference(
            for: storedItem,
            previousItem: previousItem
        )
        itemsByID[storedItem.id] = storedItem
        encodedItemByteCountsByID[storedItem.id] = encodedItemByteCount
        rawOversizedLegacyItemIDs.remove(storedItem.id)

        if let previousGroupID, previousGroupID != storedItem.groupID {
            remove(itemID: storedItem.id, fromGroup: previousGroupID)
        }

        if let existingIndex = historyIDs.firstIndex(of: storedItem.id) {
            historyIDs.remove(at: existingIndex)
        }
        historyIDs.insert(storedItem.id, at: 0)
        return storedItem
    }

    private func reconcileImageBlobReference(
        for item: ClipboardHistoryItem,
        previousItem: ClipboardHistoryItem?
    ) {
        guard let imageData = item.imagePNGData else {
            blobReferencesByItemID.removeValue(forKey: item.id)
            return
        }
        if previousItem?.imagePNGData == imageData,
           let reference = blobReferencesByItemID[item.id],
           reference.byteCount == imageData.count {
            return
        }
        // Blob identities are immutable. Replacing image bytes always creates
        // a fresh random coordinate so a stale commit can never mutate the
        // payload referenced by a newer in-memory item.
        blobReferencesByItemID[item.id] = PersistedClipboardState.ImageBlobReference(
            byteCount: imageData.count
        )
    }

    func place(itemID: UUID, intoGroup groupID: UUID) {
        ensureGroupExists(id: groupID)
        remove(itemID: itemID, fromGroup: groupID)
        groupEntries[groupID, default: []].insert(itemID, at: 0)
    }

    func remove(itemID: UUID, fromGroup groupID: UUID) {
        guard var ids = groupEntries[groupID] else { return }
        ids.removeAll { $0 == itemID }
        groupEntries[groupID] = ids
    }

    func applicationAssignmentMovePlan(
        forBundleIdentifier bundleIdentifier: String,
        toGroup groupID: UUID?
    ) -> Result<ApplicationAssignmentMovePlan, ClipboardStorageRejectionReason> {
        guard rawOversizedLegacyItemIDs.isEmpty else {
            return .failure(.itemTooLarge)
        }
        let targetGroupID = groupID ?? ClipboardGroup.defaultGroup.id
        if groupsByID[targetGroupID] == nil,
           !ClipboardGroup.reservedGroupIDs.contains(targetGroupID) {
            let projectedGroups = groupOrder.compactMap { currentGroupID in
                guard !ClipboardGroup.reservedGroupIDs.contains(currentGroupID) else { return nil }
                return groupsByID[currentGroupID]
            } + [ClipboardGroup(id: targetGroupID, name: "Recovered Group")]
            if let rejection = metadataStorageRejectionReason(
                groups: projectedGroups,
                appAssignments: Array(appAssignments.values)
            ) {
                return .failure(rejection)
            }
        }
        let matchingItemIDs = historyIDs.filter {
            itemsByID[$0]?.sourceBundleIdentifier == bundleIdentifier
        }
        let matchingItemIDSet = Set(matchingItemIDs)
        let matchingActiveItemIDs = activeItemIDs().intersection(matchingItemIDSet)
        let leasedItemIDs = Set(pendingLeases.values.map(\.itemID))
            .union(compatibilityLeaseIDsByItemID.keys)
        guard matchingItemIDs.allSatisfy({ !leasedItemIDs.contains($0) }) else {
            return .failure(.activeItemInUse)
        }

        var projectedItemsByID: [UUID: ClipboardHistoryItem] = [:]
        var projectedEncodedItemByteCountsByID: [UUID: Int] = [:]
        for itemID in matchingItemIDs {
            guard var item = itemsByID[itemID] else { continue }
            item.groupID = targetGroupID
            item.advanceVersion()
            if let rejection = rawItemStorageRejectionReason(for: item) {
                return .failure(rejection)
            }
            let encodedItemByteCount: Int
            do {
                encodedItemByteCount = try accountedEncodedItemByteCount(for: item)
            } catch {
                return .failure(.itemEncodingFailed)
            }
            if let rejection = itemStorageRejectionReason(
                for: item,
                encodedItemByteCount: encodedItemByteCount
            ) {
                return .failure(rejection)
            }
            projectedItemsByID[itemID] = item
            projectedEncodedItemByteCountsByID[itemID] = encodedItemByteCount
        }

        var projectedTargetActiveIDs = Set(groupEntries[targetGroupID, default: []])
        projectedTargetActiveIDs.subtract(matchingItemIDs)
        projectedTargetActiveIDs.formUnion(
            pendingLeases.values
                .filter { $0.groupID == targetGroupID }
                .map(\.itemID)
        )
        projectedTargetActiveIDs.formUnion(matchingActiveItemIDs)
        guard projectedTargetActiveIDs.count <= storageLimits.maximumActiveItemCountPerGroup else {
            return .failure(.activeItemLimitReached)
        }

        var projectedTotalEncodedItemByteCount = 0
        for itemID in historyIDs {
            let byteCount = projectedEncodedItemByteCountsByID[itemID]
                ?? encodedItemByteCountsByID[itemID]
                ?? encodedItemByteCountForExistingItem(itemID)
            let (nextTotal, overflowed) = projectedTotalEncodedItemByteCount.addingReportingOverflow(
                byteCount
            )
            guard !overflowed else { return .failure(.totalByteLimitReached) }
            projectedTotalEncodedItemByteCount = nextTotal
        }
        guard projectedTotalEncodedItemByteCount <= storageLimits.maximumTotalEncodedItemByteCount else {
            return .failure(.totalByteLimitReached)
        }

        return .success(
            ApplicationAssignmentMovePlan(
                targetGroupID: targetGroupID,
                projectedItemsByID: projectedItemsByID,
                encodedItemByteCountsByID: projectedEncodedItemByteCountsByID,
                activeItemIDs: matchingActiveItemIDs
            )
        )
    }

    func applyApplicationAssignmentMovePlan(
        _ plan: ApplicationAssignmentMovePlan
    ) {
        ensureGroupExists(id: plan.targetGroupID)
        // `historyIDs` and every group's pending entries share the same
        // newest-first storage contract. Placement inserts at the front, so
        // replay matching history from oldest to newest to preserve that
        // contract while moving a batch.
        for itemID in historyIDs.reversed() {
            guard let item = plan.projectedItemsByID[itemID] else { continue }
            if let previousGroupID = itemsByID[itemID]?.groupID {
                remove(itemID: itemID, fromGroup: previousGroupID)
            }
            itemsByID[itemID] = item
            encodedItemByteCountsByID[itemID] = plan.encodedItemByteCountsByID[itemID]
            if plan.activeItemIDs.contains(itemID) {
                place(itemID: itemID, intoGroup: plan.targetGroupID)
            }
        }
        updateStoragePressureAfterCurrentStateChange()
    }

    func updatePendingPlacement(for item: ClipboardHistoryItem) {
        remove(itemID: item.id, fromGroup: item.groupID)
        guard shouldQueue(item) else { return }
        place(itemID: item.id, intoGroup: item.groupID)
    }

    func shouldQueue(_ item: ClipboardHistoryItem) -> Bool {
        switch item.contentKind {
        case .text:
            return !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            return item.imagePNGData != nil
        case .files:
            return false
        }
    }

    func groupPreviewItemIDs(in ids: [UUID], mode: ClipboardPasteMode) -> [UUID] {
        switch mode {
        case .stack, .list:
            return Array(ids.prefix(Self.groupPreviewItemLimit))
        case .queue:
            return Array(ids.reversed().prefix(Self.groupPreviewItemLimit))
        }
    }

    func replaceWorkflowItem(
        id itemID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation?,
        text: String,
        captureTags: [ClipboardCaptureTag],
        alternatives: [String],
        context: ClipboardRouteContext,
        targetGroupID: UUID? = nil
    ) -> ClipboardStorageMutationResult {
        guard var existingItem = itemsByID[itemID] else {
            let fallbackGroupID = targetGroupID ?? storageGroupID(for: context)
            let replacement = ClipboardHistoryItem(
                id: itemID,
                groupID: fallbackGroupID,
                workflowID: workflowID,
                workflow: workflow,
                contentKind: .text,
                text: text,
                captureTags: captureTags,
                alternatives: alternatives,
                sourceKind: .rillWorkflow,
                sourceApplicationName: context.applicationName,
                sourceBundleIdentifier: context.bundleIdentifier,
                tags: tags(for: text)
            )
            return store(replacement, inGroup: fallbackGroupID)
        }

        existingItem.workflowID = workflowID
        existingItem.workflow = workflow
        existingItem.contentKind = .text
        existingItem.text = text
        existingItem.imagePNGData = nil
        existingItem.fileURLs = []
        existingItem.captureTags = captureTags
        existingItem.alternatives = alternatives
        existingItem.sourceKind = .rillWorkflow
        existingItem.sourceApplicationName = context.applicationName ?? existingItem.sourceApplicationName
        existingItem.sourceBundleIdentifier = context.bundleIdentifier ?? existingItem.sourceBundleIdentifier
        existingItem.latestError = nil
        existingItem.tags = tags(for: text)
        existingItem.groupID = targetGroupID ?? existingItem.groupID
        return store(existingItem, inGroup: existingItem.groupID)
    }

    func replaceWorkflowItem(
        matching subject: ClipboardItemDryRunSubject,
        workflowID: UUID,
        workflow: WorkflowPresentation?,
        text: String,
        captureTags: [ClipboardCaptureTag],
        alternatives: [String],
        context: ClipboardRouteContext,
        targetGroupID: UUID? = nil
    ) -> ClipboardItemReplacementResult {
        guard let currentItem = itemsByID[subject.itemID] else {
            return .sourceUnavailable
        }
        guard dryRunSubject(for: currentItem) == subject else {
            return .sourceChanged
        }
        let storageResult = replaceWorkflowItem(
            id: subject.itemID,
            workflowID: workflowID,
            workflow: workflow,
            text: text,
            captureTags: captureTags,
            alternatives: alternatives,
            context: context,
            targetGroupID: targetGroupID
        )
        switch storageResult {
        case .accepted:
            return .replaced
        case .rejected(let reason):
            return .storageRejected(reason)
        }
    }

    func systemClipboardItem(
        from snapshot: ClipboardSnapshot,
        groupID: UUID,
        context: ClipboardRouteContext,
        alternatives: [String]
    ) -> ClipboardHistoryItem {
        if !snapshot.fileURLs.isEmpty {
            let fileNames = snapshot.fileURLs.map(\.lastPathComponent)
            let summary = fileNames.joined(separator: ", ")
            return ClipboardHistoryItem(
                groupID: groupID,
                contentKind: .files,
                text: summary.isEmpty ? "Copied files" : summary,
                fileURLs: snapshot.fileURLs,
                captureTags: snapshot.captureTags,
                alternatives: alternatives,
                sourceKind: .system,
                sourceApplicationName: context.applicationName,
                sourceBundleIdentifier: context.bundleIdentifier,
                tags: ["files"]
            )
        }

        if let imagePNGData = snapshot.imagePNGData, !imagePNGData.isEmpty {
            return ClipboardHistoryItem(
                groupID: groupID,
                contentKind: .image,
                text: "Copied image",
                imagePNGData: imagePNGData,
                captureTags: snapshot.captureTags,
                alternatives: alternatives,
                sourceKind: .system,
                sourceApplicationName: context.applicationName,
                sourceBundleIdentifier: context.bundleIdentifier,
                tags: ["image"]
            )
        }

        return ClipboardHistoryItem(
            groupID: groupID,
            contentKind: .text,
            text: snapshot.plainText,
            captureTags: snapshot.captureTags,
            alternatives: alternatives,
            sourceKind: .system,
            sourceApplicationName: context.applicationName,
            sourceBundleIdentifier: context.bundleIdentifier,
            tags: tags(for: snapshot.plainText)
        )
    }

    func trimHistoryIfNeeded() {
        let activeIDs = activeItemIDs()
        let historyOnlyIDs = historyIDs.filter { !activeIDs.contains($0) }
        var historyOnlyCount = historyOnlyIDs.count
        var remainingRawOversizedItemIDs = rawOversizedLegacyItemIDs
        var totalByteCount = knownEncodedItemByteCount()
        var removalIDs: Set<UUID> = []
        for itemID in historyOnlyIDs.reversed() {
            guard historyOnlyCount > storageLimits.maximumHistoryOnlyItemCount
                    || !remainingRawOversizedItemIDs.isEmpty
                    || totalByteCount > storageLimits.maximumTotalEncodedItemByteCount
            else {
                break
            }
            removalIDs.insert(itemID)
            historyOnlyCount -= 1
            if remainingRawOversizedItemIDs.remove(itemID) != nil {
                continue
            }
            totalByteCount = max(
                0,
                totalByteCount - (encodedItemByteCountsByID[itemID]
                    ?? encodedItemByteCountForExistingItem(itemID))
            )
        }
        removeHistoryOnlyItems(ids: removalIDs)
        updateStoragePressureAfterCurrentStateChange()
    }

    func activeItemIDs() -> Set<UUID> {
        var activeIDs = Set(groupEntries.values.flatMap { $0 })
        activeIDs.formUnion(pendingLeases.values.map(\.itemID))
        activeIDs.formUnion(compatibilityLeaseIDsByItemID.keys)
        return activeIDs
    }

    func removeHistoryOnlyItems(ids itemIDs: Set<UUID>) {
        historyIDs.removeAll { itemIDs.contains($0) }
        for itemID in itemIDs {
            itemsByID.removeValue(forKey: itemID)
            encodedItemByteCountsByID.removeValue(forKey: itemID)
            rawOversizedLegacyItemIDs.remove(itemID)
            blobReferencesByItemID.removeValue(forKey: itemID)
        }
    }

    func deliveryItem(from item: ClipboardHistoryItem, state: DeliveryItemState) -> DeliveryItem {
        DeliveryItem(
            id: item.id,
            workflowID: item.workflowID ?? UUID(),
            workflow: item.workflow,
            text: item.text,
            alternatives: item.alternatives,
            createdAt: item.createdAt,
            state: state,
            latestError: item.latestError,
            sourceApplicationName: item.sourceApplicationName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            targetGroupID: item.groupID,
            captureTags: item.captureTags
        )
    }

    func tags(for text: String) -> [String] {
        var resolvedTags: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            resolvedTags.append("url")
        }
        if trimmed.contains("\n") {
            resolvedTags.append("multiline")
        }
        return resolvedTags
    }

}
