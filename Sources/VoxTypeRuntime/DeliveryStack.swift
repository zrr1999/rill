import Foundation
import VoxTypeCore

public actor DeliveryStack: DeliveryStackSink, ClipboardCaptureSink {
    private struct DeliveryLease: Sendable {
        let id: UUID
        let itemID: UUID
        let groupID: UUID
        let consumesItem: Bool
    }

    private struct PersistedClipboardState: Codable {
        struct GroupEntry: Codable {
            var groupID: UUID
            var itemIDs: [UUID]
        }

        var items: [ClipboardHistoryItem]
        var groups: [ClipboardGroup]
        var groupEntries: [GroupEntry]
        var appAssignments: [ClipboardAppAssignment]
    }

    private static let maxHistoryItems = 500
    private static let groupPreviewItemLimit = 3
    private static let persistenceDebounceInterval = Duration.milliseconds(250)

    private var historyIDs: [UUID] = []
    private var itemsByID: [UUID: ClipboardHistoryItem] = [:]
    private var groupsByID: [UUID: ClipboardGroup] = [ClipboardGroup.defaultGroup.id: .defaultGroup]
    private var groupOrder: [UUID] = [ClipboardGroup.defaultGroup.id]
    private var groupEntries: [UUID: [UUID]] = [ClipboardGroup.defaultGroup.id: []]
    private var appAssignments: [String: ClipboardAppAssignment] = [:]
    private var pendingLeases: [UUID: DeliveryLease] = [:]
    private var compatibilityLeaseIDsByItemID: [UUID: UUID] = [:]
    private var pendingPersistenceTask: Task<Void, Never>?
    private var pendingPersistenceGeneration: UInt64 = 0
    private var isInitialized = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let settingsStore: (any SettingsStore)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        settingsStore: (any SettingsStore)? = nil
    ) {
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.settingsStore = settingsStore

        if settingsStore != nil {
            Task {
                await self.loadPersistedState()
                await self.markInitialized()
            }
        } else {
            isInitialized = true
        }
    }

    private func ensureInitialized() async {
        if isInitialized { return }
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    private func markInitialized() {
        isInitialized = true
        for continuation in pendingContinuations {
            continuation.resume()
        }
        pendingContinuations.removeAll()
    }

    public func push(_ item: DeliveryItem) async {
        await ensureInitialized()
        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        let targetGroupID = ensureAssignedGroup(for: routeContext)
        let clipboardItem = ClipboardHistoryItem(
            id: item.id,
            groupID: targetGroupID,
            workflowID: item.workflowID,
            workflow: item.workflow,
            contentKind: .text,
            text: item.text,
            captureTags: item.captureTags,
            alternatives: item.alternatives,
            createdAt: item.createdAt,
            sourceKind: .voxtypeWorkflow,
            sourceApplicationName: item.sourceApplicationName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            latestError: item.latestError,
            tags: tags(for: item.text)
        )
        store(clipboardItem, inGroup: targetGroupID)
        await publishAndSchedulePersistence()
    }

    public func captureSystemClipboard(
        snapshot: ClipboardSnapshot,
        context: ClipboardRouteContext,
        alternatives: [String] = []
    ) async {
        await ensureInitialized()
        guard snapshot.hasTransferableContent, !snapshot.excludesWorkflowCapture else {
            return
        }
        let targetGroupID = ensureAssignedGroup(for: context)
        let clipboardItem = systemClipboardItem(
            from: snapshot,
            groupID: targetGroupID,
            context: context,
            alternatives: alternatives
        )
        store(clipboardItem, inGroup: targetGroupID)
        await publishAndSchedulePersistence()
    }

    public func captureWorkflowClipboardCopy(
        text: String,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        context: ClipboardRouteContext,
        alternatives: [String],
        captureTags: [ClipboardCaptureTag],
        replacing sourceItemID: UUID?
    ) async {
        await ensureInitialized()
        if let sourceItemID {
            replaceWorkflowItem(
                id: sourceItemID,
                workflowID: workflowID,
                workflow: workflow,
                text: text,
                captureTags: captureTags,
                alternatives: alternatives,
                context: context
            )
            await publishAndSchedulePersistence()
            return
        }

        let targetGroupID = ensureAssignedGroup(for: context)
        let clipboardItem = ClipboardHistoryItem(
            groupID: targetGroupID,
            workflowID: workflowID,
            workflow: workflow,
            contentKind: .text,
            text: text,
            captureTags: captureTags,
            alternatives: alternatives,
            sourceKind: .voxtypeWorkflow,
            sourceApplicationName: context.applicationName,
            sourceBundleIdentifier: context.bundleIdentifier,
            tags: tags(for: text)
        )
        store(clipboardItem, inGroup: targetGroupID)
        await publishAndSchedulePersistence()
    }

    public func replace(_ item: DeliveryItem, replacing itemID: UUID) async {
        await ensureInitialized()
        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        replaceWorkflowItem(
            id: itemID,
            workflowID: item.workflowID,
            workflow: item.workflow,
            text: item.text,
            captureTags: item.captureTags,
            alternatives: item.alternatives,
            context: routeContext
        )
        await publishAndSchedulePersistence()
    }

    public func popNext() async -> DeliveryItem? {
        await ensureInitialized()
        guard let lease = beginLease(for: ClipboardRouteContext()) else {
            return nil
        }
        compatibilityLeaseIDsByItemID[lease.itemID] = lease.id
        if lease.consumesItem {
            await publishAndSchedulePersistence()
        }
        guard let item = itemsByID[lease.itemID] else {
            compatibilityLeaseIDsByItemID.removeValue(forKey: lease.itemID)
            pendingLeases.removeValue(forKey: lease.id)
            return nil
        }
        return deliveryItem(from: item, state: lease.consumesItem ? .delivering : .pending)
    }

    public func returnToFront(_ item: DeliveryItem, error: String? = nil) async {
        await ensureInitialized()
        if let leaseID = compatibilityLeaseIDsByItemID.removeValue(forKey: item.id) {
            await failDelivery(leaseID: leaseID, error: error)
            return
        }

        let routeContext = ClipboardRouteContext(
            applicationName: item.sourceApplicationName,
            bundleIdentifier: item.sourceBundleIdentifier
        )
        let targetGroupID = itemsByID[item.id]?.groupID ?? ensureAssignedGroup(for: routeContext)
        var restored = ClipboardHistoryItem(
            id: item.id,
            groupID: targetGroupID,
            workflowID: item.workflowID,
            workflow: item.workflow,
            contentKind: .text,
            text: item.text,
            captureTags: item.captureTags,
            alternatives: item.alternatives,
            createdAt: item.createdAt,
            sourceKind: .voxtypeWorkflow,
            sourceApplicationName: item.sourceApplicationName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            latestError: error,
            tags: tags(for: item.text)
        )
        restored.latestError = error
        store(restored, inGroup: targetGroupID)
        await publishAndSchedulePersistence()
    }

    public func snapshot() async -> DeliveryStackSnapshot {
        await ensureInitialized()
        let summary = summary(for: ClipboardGroup.defaultGroup.id)
        return DeliveryStackSnapshot(count: summary.count, topPreview: summary.previewText)
    }

    public func allItems() async -> [DeliveryItem] {
        await ensureInitialized()
        return groupEntries[ClipboardGroup.defaultGroup.id, default: []].compactMap { itemID in
            guard let item = itemsByID[itemID] else { return nil }
            return deliveryItem(from: item, state: .pending)
        }
    }

    public func clipboardSnapshot() async -> ClipboardStoreSnapshot {
        await ensureInitialized()
        return buildClipboardSnapshot()
    }

    private func buildClipboardSnapshot() -> ClipboardStoreSnapshot {
        ClipboardStoreSnapshot(
            items: historyIDs.compactMap { itemsByID[$0] },
            groups: groupSummaries(),
            appAssignments: sortedAppAssignments()
        )
    }

    public func routeSnapshot(for context: ClipboardRouteContext) async -> ClipboardRouteSnapshot {
        await ensureInitialized()
        let groupID = ensureAssignedGroup(for: context)
        let summary = summary(for: groupID)
        let ids = groupEntries[groupID, default: []]
        let previewID = candidateItemID(in: ids, mode: currentMode(forGroup: groupID))
        let previewItem = previewID.flatMap { itemsByID[$0] }
        return ClipboardRouteSnapshot(
            activeGroup: summary,
            count: summary.count,
            previewText: summary.previewText,
            previewCaptureTags: previewItem?.captureTags ?? [],
            previewContentKind: previewItem?.contentKind,
            previewSnapshot: previewItem?.clipboardSnapshot
        )
    }

    public func beginDeliveryLease(for context: ClipboardRouteContext) async -> (leaseID: UUID, item: ClipboardHistoryItem)? {
        await ensureInitialized()
        guard let lease = beginLease(for: context), let item = itemsByID[lease.itemID] else {
            return nil
        }
        if lease.consumesItem {
            await publishAndSchedulePersistence()
        }
        return (lease.id, item)
    }

    public func completeDelivery(leaseID: UUID) async {
        await ensureInitialized()
        guard let lease = pendingLeases.removeValue(forKey: leaseID), var item = itemsByID[lease.itemID] else {
            return
        }

        item.latestError = nil
        item.lastUsedAt = Date()
        item.useCount += 1
        itemsByID[item.id] = item
        compatibilityLeaseIDsByItemID.removeValue(forKey: item.id)
        await publishAndSchedulePersistence()
    }

    public func failDelivery(leaseID: UUID, error: String?) async {
        await ensureInitialized()
        guard let lease = pendingLeases.removeValue(forKey: leaseID), var item = itemsByID[lease.itemID] else {
            return
        }

        if lease.consumesItem {
            place(itemID: item.id, intoGroup: lease.groupID)
        }

        item.latestError = error
        itemsByID[item.id] = item
        compatibilityLeaseIDsByItemID.removeValue(forKey: item.id)
        await publishAndSchedulePersistence()
    }

    public func item(id: UUID) async -> ClipboardHistoryItem? {
        await ensureInitialized()
        return itemsByID[id]
    }

    public func markUsed(itemID: UUID) async {
        await ensureInitialized()
        guard var item = itemsByID[itemID] else { return }
        item.latestError = nil
        item.lastUsedAt = Date()
        item.useCount += 1
        itemsByID[itemID] = item
        await publishAndSchedulePersistence()
    }

    public func deleteItem(id itemID: UUID) async {
        await ensureInitialized()
        await deleteItems(ids: [itemID])
    }

    public func deleteItems(ids itemIDs: [UUID]) async {
        await ensureInitialized()
        let uniqueIDs = Set(itemIDs)
        guard !uniqueIDs.isEmpty else { return }

        var didDeleteAnyItem = false
        for itemID in uniqueIDs {
            guard let item = itemsByID.removeValue(forKey: itemID) else { continue }
            didDeleteAnyItem = true
            remove(itemID: itemID, fromGroup: item.groupID)
            compatibilityLeaseIDsByItemID.removeValue(forKey: itemID)
        }

        guard didDeleteAnyItem else { return }

        historyIDs.removeAll { uniqueIDs.contains($0) }
        pendingLeases = pendingLeases.filter { !uniqueIDs.contains($0.value.itemID) }
        await publishAndSchedulePersistence()
    }

    public func createGroup(named name: String) async -> ClipboardGroup {
        await ensureInitialized()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = ClipboardGroup(name: trimmedName.isEmpty ? "New Group" : trimmedName)
        groupsByID[group.id] = group
        groupOrder.append(group.id)
        groupEntries[group.id] = []
        await publishAndSchedulePersistence()
        return group
    }

    public func setMode(_ mode: ClipboardPasteMode, forGroup groupID: UUID) async {
        await ensureInitialized()
        ensureGroupExists(id: groupID)
        groupsByID[groupID]?.mode = mode
        await publishAndSchedulePersistence()
    }

    public func assignApplication(
        bundleIdentifier: String,
        applicationName: String,
        toGroup groupID: UUID
    ) async {
        await ensureInitialized()
        ensureGroupExists(id: groupID)
        appAssignments[bundleIdentifier] = ClipboardAppAssignment(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            groupID: groupID
        )
        moveItems(forBundleIdentifier: bundleIdentifier, toGroup: groupID)
        await publishAndSchedulePersistence()
    }

    private func beginLease(for context: ClipboardRouteContext) -> DeliveryLease? {
        let groupID = ensureAssignedGroup(for: context)
        let ids = groupEntries[groupID, default: []]
        let mode = currentMode(forGroup: groupID)
        guard let nextItemID = candidateItemID(in: ids, mode: mode) else { return nil }

        let consumesItem = mode != .list
        let lease = DeliveryLease(
            id: UUID(),
            itemID: nextItemID,
            groupID: groupID,
            consumesItem: consumesItem
        )
        pendingLeases[lease.id] = lease
        if consumesItem {
            remove(itemID: nextItemID, fromGroup: groupID)
        }
        return lease
    }

    private func candidateItemID(in ids: [UUID], mode: ClipboardPasteMode) -> UUID? {
        switch mode {
        case .stack, .list:
            return ids.first
        case .queue:
            return ids.last
        }
    }

    private func ensureAssignedGroup(for context: ClipboardRouteContext) -> UUID {
        guard let bundleIdentifier = context.bundleIdentifier else {
            return ClipboardGroup.defaultGroup.id
        }

        if let applicationName = context.applicationName {
            if let existing = appAssignments[bundleIdentifier] {
                if existing.applicationName != applicationName {
                    appAssignments[bundleIdentifier]?.applicationName = applicationName
                }
                return existing.groupID
            }
            appAssignments[bundleIdentifier] = ClipboardAppAssignment(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                groupID: ClipboardGroup.defaultGroup.id
            )
        }

        return appAssignments[bundleIdentifier]?.groupID ?? ClipboardGroup.defaultGroup.id
    }

    private func currentMode(forGroup groupID: UUID) -> ClipboardPasteMode {
        groupsByID[groupID]?.mode ?? ClipboardGroup.defaultGroup.mode
    }

    private func summary(for groupID: UUID) -> ClipboardGroupSummary {
        ensureGroupExists(id: groupID)
        let ids = groupEntries[groupID, default: []]
        let mode = currentMode(forGroup: groupID)
        let previewID = candidateItemID(in: ids, mode: mode)
        let previewItemIDs = groupPreviewItemIDs(in: ids, mode: mode)
        return ClipboardGroupSummary(
            group: groupsByID[groupID] ?? .defaultGroup,
            count: ids.count,
            previewText: previewID.flatMap { itemsByID[$0]?.text },
            previewItemIDs: previewItemIDs
        )
    }

    private func groupSummaries() -> [ClipboardGroupSummary] {
        groupOrder.compactMap { groupID in
            groupsByID[groupID].map { _ in summary(for: groupID) }
        }
    }

    private func sortedAppAssignments() -> [ClipboardAppAssignment] {
        appAssignments.values.sorted {
            $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
        }
    }

    private func ensureGroupExists(id: UUID) {
        guard groupsByID[id] == nil else { return }
        groupsByID[id] = ClipboardGroup(id: id, name: "Recovered Group")
        if !groupOrder.contains(id) {
            groupOrder.append(id)
        }
        if groupEntries[id] == nil {
            groupEntries[id] = []
        }
    }

    private func store(_ item: ClipboardHistoryItem, inGroup groupID: UUID) {
        ensureGroupExists(id: groupID)
        var storedItem = item
        storedItem.groupID = groupID
        upsertHistoryItem(storedItem)
        updatePendingPlacement(for: storedItem)
        trimHistoryIfNeeded()
    }

    private func upsertHistoryItem(_ item: ClipboardHistoryItem) {
        let previousGroupID = itemsByID[item.id]?.groupID
        itemsByID[item.id] = item

        if let previousGroupID, previousGroupID != item.groupID {
            remove(itemID: item.id, fromGroup: previousGroupID)
        }

        if let existingIndex = historyIDs.firstIndex(of: item.id) {
            historyIDs.remove(at: existingIndex)
        }
        historyIDs.insert(item.id, at: 0)
    }

    private func place(itemID: UUID, intoGroup groupID: UUID) {
        ensureGroupExists(id: groupID)
        remove(itemID: itemID, fromGroup: groupID)
        groupEntries[groupID, default: []].insert(itemID, at: 0)
    }

    private func remove(itemID: UUID, fromGroup groupID: UUID) {
        guard var ids = groupEntries[groupID] else { return }
        ids.removeAll { $0 == itemID }
        groupEntries[groupID] = ids
    }

    private func moveItems(forBundleIdentifier bundleIdentifier: String, toGroup groupID: UUID) {
        ensureGroupExists(id: groupID)
        for itemID in historyIDs {
            guard var item = itemsByID[itemID], item.sourceBundleIdentifier == bundleIdentifier else { continue }
            remove(itemID: itemID, fromGroup: item.groupID)
            item.groupID = groupID
            itemsByID[itemID] = item
            updatePendingPlacement(for: item)
        }
    }

    private func updatePendingPlacement(for item: ClipboardHistoryItem) {
        remove(itemID: item.id, fromGroup: item.groupID)
        guard shouldQueue(item) else { return }
        place(itemID: item.id, intoGroup: item.groupID)
    }

    private func shouldQueue(_ item: ClipboardHistoryItem) -> Bool {
        switch item.contentKind {
        case .text:
            return !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            return item.imagePNGData != nil
        case .files:
            return false
        }
    }

    private func groupPreviewItemIDs(in ids: [UUID], mode: ClipboardPasteMode) -> [UUID] {
        switch mode {
        case .stack, .list:
            return Array(ids.prefix(Self.groupPreviewItemLimit))
        case .queue:
            return Array(ids.reversed().prefix(Self.groupPreviewItemLimit))
        }
    }

    private func replaceWorkflowItem(
        id itemID: UUID,
        workflowID: UUID,
        workflow: WorkflowPresentation?,
        text: String,
        captureTags: [ClipboardCaptureTag],
        alternatives: [String],
        context: ClipboardRouteContext
    ) {
        guard var existingItem = itemsByID[itemID] else {
            let fallbackGroupID = ensureAssignedGroup(for: context)
            let replacement = ClipboardHistoryItem(
                id: itemID,
                groupID: fallbackGroupID,
                workflowID: workflowID,
                workflow: workflow,
                contentKind: .text,
                text: text,
                captureTags: captureTags,
                alternatives: alternatives,
                sourceKind: .voxtypeWorkflow,
                sourceApplicationName: context.applicationName,
                sourceBundleIdentifier: context.bundleIdentifier,
                tags: tags(for: text)
            )
            store(replacement, inGroup: fallbackGroupID)
            return
        }

        existingItem.workflowID = workflowID
        existingItem.workflow = workflow
        existingItem.contentKind = .text
        existingItem.text = text
        existingItem.imagePNGData = nil
        existingItem.fileURLs = []
        existingItem.captureTags = captureTags
        existingItem.alternatives = alternatives
        existingItem.sourceKind = .voxtypeWorkflow
        existingItem.sourceApplicationName = context.applicationName ?? existingItem.sourceApplicationName
        existingItem.sourceBundleIdentifier = context.bundleIdentifier ?? existingItem.sourceBundleIdentifier
        existingItem.latestError = nil
        existingItem.tags = tags(for: text)
        itemsByID[itemID] = existingItem
        updatePendingPlacement(for: existingItem)
    }

    private func systemClipboardItem(
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

        if let imagePNGData = snapshot.imagePNGData {
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

    private func trimHistoryIfNeeded() {
        guard historyIDs.count > Self.maxHistoryItems else { return }

        while historyIDs.count > Self.maxHistoryItems {
            let removedID = historyIDs.removeLast()
            if let removedItem = itemsByID.removeValue(forKey: removedID) {
                remove(itemID: removedID, fromGroup: removedItem.groupID)
            }
            compatibilityLeaseIDsByItemID.removeValue(forKey: removedID)
            pendingLeases = pendingLeases.filter { $0.value.itemID != removedID }
        }
    }

    private func deliveryItem(from item: ClipboardHistoryItem, state: DeliveryItemState) -> DeliveryItem {
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
            captureTags: item.captureTags
        )
    }

    private func tags(for text: String) -> [String] {
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

    private func loadPersistedState() async {
        guard let settingsStore else { return }
        do {
            guard
                let rawState = try await settingsStore.string(forKey: .clipboardPersistedState),
                let stateData = rawState.data(using: .utf8)
            else {
                await publishSnapshot()
                return
            }

            let state = try decoder.decode(PersistedClipboardState.self, from: stateData)
            historyIDs = state.items.map(\.id)
            itemsByID = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })
            groupsByID = Dictionary(uniqueKeysWithValues: state.groups.map { ($0.id, $0) })
            groupsByID[ClipboardGroup.defaultGroup.id] = groupsByID[ClipboardGroup.defaultGroup.id] ?? .defaultGroup
            groupOrder = state.groups.map(\.id)
            if !groupOrder.contains(ClipboardGroup.defaultGroup.id) {
                groupOrder.insert(ClipboardGroup.defaultGroup.id, at: 0)
            }
            groupEntries = Dictionary(uniqueKeysWithValues: state.groupEntries.map { ($0.groupID, $0.itemIDs) })
            groupEntries[ClipboardGroup.defaultGroup.id] = groupEntries[ClipboardGroup.defaultGroup.id] ?? []
            appAssignments = Dictionary(uniqueKeysWithValues: state.appAssignments.map { ($0.bundleIdentifier, $0) })
            trimHistoryIfNeeded()
        } catch {
            if let diagnostics {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .clipboard,
                        level: .warning,
                        event: "clipboard.state.load-failed",
                        message: "Clipboard state could not be restored.",
                        metadata: ["error": error.localizedDescription]
                    )
                )
            }
        }

        await publishSnapshot()
    }

    private func persistState() async {
        guard let settingsStore else { return }
        do {
            let state = PersistedClipboardState(
                items: historyIDs.compactMap { itemsByID[$0] },
                groups: groupOrder.compactMap { groupsByID[$0] },
                groupEntries: groupOrder.map { groupID in
                    PersistedClipboardState.GroupEntry(
                        groupID: groupID,
                        itemIDs: groupEntries[groupID, default: []]
                    )
                },
                appAssignments: sortedAppAssignments()
            )
            let data = try encoder.encode(state)
            try await settingsStore.setString(
                String(decoding: data, as: UTF8.self),
                forKey: .clipboardPersistedState
            )
        } catch {
            if let diagnostics {
                await diagnostics.record(
                    DiagnosticEvent(
                        subsystem: .clipboard,
                        level: .warning,
                        event: "clipboard.state.persist-failed",
                        message: "Clipboard state could not be persisted.",
                        metadata: ["error": error.localizedDescription]
                    )
                )
            }
        }
    }

    private func publishAndSchedulePersistence() async {
        await publishSnapshot()
        schedulePersistence()
    }

    private func publishSnapshot() async {
        let snapshot = buildClipboardSnapshot()
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

    private func schedulePersistence() {
        guard settingsStore != nil else { return }

        pendingPersistenceTask?.cancel()
        pendingPersistenceGeneration &+= 1
        let generation = pendingPersistenceGeneration
        pendingPersistenceTask = Task {
            do {
                try await Task.sleep(for: Self.persistenceDebounceInterval)
            } catch is CancellationError {
                return
            } catch {
                if let diagnostics = self.diagnostics {
                    await diagnostics.record(
                        DiagnosticEvent(
                            subsystem: .clipboard,
                            level: .warning,
                            event: "clipboard.persistence.schedule-failed",
                            message: "Persistence scheduling interrupted unexpectedly.",
                            metadata: ["error": error.localizedDescription]
                        )
                    )
                }
                return
            }

            await self.persistStateIfCurrent(generation: generation)
        }
    }

    private func persistStateIfCurrent(generation: UInt64) async {
        guard generation == pendingPersistenceGeneration else { return }
        pendingPersistenceTask = nil
        await persistState()
    }
}
