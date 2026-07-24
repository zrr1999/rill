import Foundation
import RillCore
import RillRuntime

extension AppModel {
    public func setClipboardHistoryRetentionPeriod(_ period: HistoryRetentionPeriod) {
        updateHistoryRetentionPeriod(
            period,
            currentPeriod: clipboardHistoryRetentionPeriod,
            key: .clipboardHistoryRetentionPeriod,
            isClipboardSetting: true
        )
    }

    public func setRunHistoryRetentionPeriod(_ period: HistoryRetentionPeriod) {
        updateHistoryRetentionPeriod(
            period,
            currentPeriod: runHistoryRetentionPeriod,
            key: .runHistoryRetentionPeriod,
            isClipboardSetting: false
        )
    }

    public func clearClipboardHistory() {
        guard beginLocalHistoryMaintenance() else { return }
        guard let localHistoryMaintenance else {
            finishWithUnavailableMaintenanceService()
            return
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self, localHistoryMaintenance] in
            let result = await localHistoryMaintenance.clearClipboardHistory()
            guard let self else { return }
            defer { self.finishLocalHistoryMaintenanceTask(id: taskID) }
            await self.finishLocalHistoryMaintenance(
                result,
                refreshClipboard: true,
                refreshRunHistory: false,
                refreshDiagnostics: false
            )
        }
        localHistoryMaintenanceTasks[taskID] = task
    }

    public func clearRunHistory() {
        guard !hasActiveOrQueuedVoiceRun else {
            localHistoryMaintenanceBlockedReason = language == .english
                ? "Finish the active or queued voice run before clearing run and diagnostic history."
                : "请先完成当前或排队中的语音运行，再清除运行与诊断历史。"
            return
        }
        guard canClearRunHistory else { return }
        guard beginLocalHistoryMaintenance() else { return }
        guard let localHistoryMaintenance else {
            finishWithUnavailableMaintenanceService()
            return
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self, localHistoryMaintenance] in
            guard let self else { return }
            defer { self.finishLocalHistoryMaintenanceTask(id: taskID) }
            await self.flushPendingPersistenceWrites()
            let result = await localHistoryMaintenance.clearRunHistory()
            await self.finishLocalHistoryMaintenance(
                result,
                refreshClipboard: false,
                refreshRunHistory: true,
                refreshDiagnostics: true,
                clearDiagnosticCacheBeforeRefresh: true,
                clearRunReceiptCacheBeforeRefresh: true,
                reconcileRunPresentationAfterRefresh: true
            )
            if case .blocked = result {
                return
            }
            guard self.failedAudioRecoveryEnabled
                || !self.failedAudioRecoveryReceipts.isEmpty else {
                return
            }
            self.clearFailedAudioRecoveries()
        }
        localHistoryMaintenanceTasks[taskID] = task
    }

    public func retryPendingLocalHistoryMaintenance() {
        guard beginLocalHistoryMaintenance() else { return }
        guard let localHistoryMaintenance else {
            finishWithUnavailableMaintenanceService()
            return
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self, localHistoryMaintenance] in
            let result = await localHistoryMaintenance.retryPendingMaintenance()
            guard let self else { return }
            defer { self.finishLocalHistoryMaintenanceTask(id: taskID) }
            await self.finishLocalHistoryMaintenance(
                result,
                refreshClipboard: true,
                refreshRunHistory: true,
                refreshDiagnostics: true,
                clearRunReceiptCacheBeforeRefresh: true
            )
        }
        localHistoryMaintenanceTasks[taskID] = task
    }

    func performLocalHistoryRetention(
        now: Date = Date(),
        startPeriodicMaintenanceAfterCompletion: Bool = false
    ) {
        guard !hasBegunApplicationShutdown else {
            historyRetentionRerunRequested = false
            shouldStartPeriodicHistoryRetentionMaintenance = false
            return
        }
        if startPeriodicMaintenanceAfterCompletion {
            shouldStartPeriodicHistoryRetentionMaintenance = true
        }
        guard areHistoryRetentionSettingsAvailable else {
            shouldStartPeriodicHistoryRetentionMaintenance = false
            localHistoryMaintenanceBlockedReason = language == .english
                ? "Automatic history cleanup is paused because saved retention settings could not be loaded."
                : "无法加载已保存的留存设置，自动历史清理保持暂停。"
            return
        }
        guard let localHistoryMaintenance else {
            shouldStartPeriodicHistoryRetentionMaintenance = false
            guard clipboardHistoryRetentionPeriod != .forever ||
                runHistoryRetentionPeriod != .forever else {
                return
            }
            localHistoryMaintenanceBlockedReason = language == .english
                ? "The retention setting was saved, but cleanup is unavailable. Cleanup will be retried after the maintenance service is restored or Rill restarts."
                : "留存设置已保存，但清理服务不可用；维护服务恢复或 Rill 重启后将再次尝试。"
            return
        }
        guard !isLocalHistoryMaintenanceRunning else {
            historyRetentionRerunRequested = true
            return
        }
        guard beginLocalHistoryMaintenance() else { return }
        let clipboardRetention = clipboardHistoryRetentionPeriod
        let runRetention = runHistoryRetentionPeriod

        let taskID = UUID()
        let task = Task { @MainActor [weak self, localHistoryMaintenance] in
            let result = await localHistoryMaintenance.performRetention(
                clipboardRetention: clipboardRetention,
                runRetention: runRetention,
                now: now
            )
            guard let self else { return }
            defer { self.finishLocalHistoryMaintenanceTask(id: taskID) }
            await self.finishLocalHistoryMaintenance(
                result,
                refreshClipboard: true,
                refreshRunHistory: true,
                refreshDiagnostics: true
            )
        }
        localHistoryMaintenanceTasks[taskID] = task
    }

    /// Closes every history-maintenance entry point, stops the periodic timer,
    /// and waits for an already-started destructive operation plus its cache
    /// projection reads to finish. The active operation is deliberately not
    /// cancelled: its durable transition must reach a stable completed, pending,
    /// or blocked result before quit.
    public func stopLocalHistoryMaintenanceForApplicationShutdown() async {
        hasBegunApplicationShutdown = true
        historyRetentionRerunRequested = false
        shouldStartPeriodicHistoryRetentionMaintenance = false
        historyLoadGeneration += 1
        runReceiptLoadGeneration += 1
        diagnosticsLoadGeneration += 1
        runHistoryBrowseGeneration += 1
        runHistoryBrowseTask?.cancel()
        runHistoryBrowseTask = nil
        for task in historyProjectionLoadTasks.values {
            task.cancel()
        }

        let periodicTask = periodicHistoryRetentionMaintenanceTask
        periodicHistoryRetentionMaintenanceTask = nil
        periodicTask?.cancel()
        await periodicTask?.value

        let activeTasks = Array(localHistoryMaintenanceTasks.values)
        for task in activeTasks {
            await task.value
        }
        localHistoryMaintenanceTasks.removeAll()

        // A maintenance completion may have started projection reads before the
        // terminal flag was set. No new reads can register after that flag, so
        // draining this owner to empty closes the final read/publish boundary.
        while !historyProjectionLoadTasks.isEmpty {
            let projectionTasks = Array(historyProjectionLoadTasks.values)
            for task in projectionTasks {
                task.cancel()
            }
            for task in projectionTasks {
                await task.value
            }
        }
    }

    private func updateHistoryRetentionPeriod(
        _ period: HistoryRetentionPeriod,
        currentPeriod: HistoryRetentionPeriod,
        key: AppSettingKey,
        isClipboardSetting: Bool
    ) {
        let settingIsInvalid = isClipboardSetting
            ? clipboardHistoryRetentionSettingIsInvalid
            : runHistoryRetentionSettingIsInvalid
        guard !hasBegunApplicationShutdown else { return }
        guard period != currentPeriod || settingIsInvalid else { return }
        // Initial settings restore owns the authoritative retention snapshot.
        // Accepting a user mutation before that snapshot settles can let the
        // late read overwrite a newer, longer period and start irreversible
        // cleanup with stale policy. The Settings UI mirrors this guard.
        guard !isLoadingSettings else { return }
        guard !isUpdatingHistoryRetentionSettings, !isLocalHistoryMaintenanceRunning else { return }
        guard !isRestoringSettings else { return }
        guard let settingsStore else {
            historyRetentionSettingsWriteError = language == .english
                ? "Retention settings cannot be saved because settings storage is unavailable."
                : "设置存储不可用，无法保存留存设置。"
            refreshHistoryRetentionSettingsErrorPresentation()
            return
        }

        historyRetentionSettingsWriteError = nil
        refreshHistoryRetentionSettingsErrorPresentation()
        isUpdatingHistoryRetentionSettings = true
        let task = Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(period.rawValue, forKey: key)
                guard let self else { return }
                guard !self.hasBegunApplicationShutdown else {
                    self.isUpdatingHistoryRetentionSettings = false
                    return
                }
                let shouldPrune = Self.isShorterRetention(period, than: currentPeriod)
                if isClipboardSetting {
                    self.clipboardHistoryRetentionPeriod = period
                    self.clipboardHistoryRetentionSettingIsInvalid = false
                } else {
                    self.runHistoryRetentionPeriod = period
                    self.runHistoryRetentionSettingIsInvalid = false
                }
                self.refreshHistoryRetentionSettingsErrorPresentation()
                self.isUpdatingHistoryRetentionSettings = false

                if shouldPrune {
                    self.performLocalHistoryRetention()
                } else if !isClipboardSetting {
                    self.loadHistory()
                }
            } catch {
                guard let self else { return }
                self.isUpdatingHistoryRetentionSettings = false
                guard !self.hasBegunApplicationShutdown else { return }
                self.historyRetentionSettingsWriteError = self.language == .english
                    ? "Retention setting was not saved; no history was removed. Repair configuration storage, then retry."
                    : "留存设置未能保存，因此没有移除任何历史记录。请修复配置存储后重试。"
                self.refreshHistoryRetentionSettingsErrorPresentation()
                self.append(
                    english: "History retention settings could not be saved. Cleanup was not started.",
                    simplifiedChinese: "历史留存设置无法保存，未启动清理。"
                )
            }
        }
        registerPersistenceWrite(task)
    }

    private static func isShorterRetention(
        _ candidate: HistoryRetentionPeriod,
        than current: HistoryRetentionPeriod
    ) -> Bool {
        switch (candidate.duration, current.duration) {
        case (nil, _):
            return false
        case (.some, nil):
            return true
        case (.some(let candidateDuration), .some(let currentDuration)):
            return candidateDuration < currentDuration
        }
    }

    private func beginLocalHistoryMaintenance() -> Bool {
        guard !hasBegunApplicationShutdown,
              !isLocalHistoryMaintenanceRunning else {
            return false
        }
        isLocalHistoryMaintenanceRunning = true
        localHistoryMaintenancePendingReason = nil
        localHistoryMaintenanceBlockedReason = nil
        return true
    }

    private func finishWithUnavailableMaintenanceService() {
        isLocalHistoryMaintenanceRunning = false
        localHistoryMaintenanceBlockedReason = language == .english
            ? "Local history maintenance is unavailable. No history was removed."
            : "本地历史维护服务不可用，没有移除任何历史记录。"
    }

    private func finishLocalHistoryMaintenance(
        _ result: LocalHistoryMaintenanceResult,
        refreshClipboard: Bool,
        refreshRunHistory: Bool,
        refreshDiagnostics: Bool,
        clearDiagnosticCacheBeforeRefresh: Bool = false,
        clearRunReceiptCacheBeforeRefresh: Bool = false,
        reconcileRunPresentationAfterRefresh: Bool = false
    ) async {
        switch result {
        case .completed(let counts):
            applyLocalHistoryMaintenanceCounts(counts)
            localHistoryMaintenancePendingReason = nil
            localHistoryMaintenanceBlockedReason = nil
            if counts.totalRemovedCount > 0 || counts.preservedActiveClipboardCount > 0 {
                append(
                    english: "Local history updated: removed \(counts.totalRemovedCount), preserved \(counts.preservedActiveClipboardCount) active clipboard item(s).",
                    simplifiedChinese: "本地历史已更新：移除 \(counts.totalRemovedCount) 条，保留 \(counts.preservedActiveClipboardCount) 条仍在使用的剪贴板内容。"
                )
            }
        case .pending(let counts, let reason):
            applyLocalHistoryMaintenanceCounts(counts)
            localHistoryMaintenancePendingReason = localizedPendingReason(reason)
            localHistoryMaintenanceBlockedReason = nil
        case .blocked(let reason):
            lastLocalHistoryRemovedCount = 0
            lastPreservedActiveClipboardCount = 0
            localHistoryMaintenancePendingReason = nil
            localHistoryMaintenanceBlockedReason = localizedBlockReason(reason)
        }

        isLocalHistoryMaintenanceRunning = false
        let shouldRerunRetention = historyRetentionRerunRequested
        historyRetentionRerunRequested = false
        let shouldStartPeriodicMaintenance = shouldStartPeriodicHistoryRetentionMaintenance
        shouldStartPeriodicHistoryRetentionMaintenance = false

        guard !hasBegunApplicationShutdown else {
            historyRetentionRerunRequested = false
            shouldStartPeriodicHistoryRetentionMaintenance = false
            return
        }

        if case .blocked = result {
            // A blocked result did not mutate history, so there are no caches to refresh.
        } else {
            await refreshHistoryCaches(
                clipboard: refreshClipboard,
                runHistory: refreshRunHistory,
                diagnostics: refreshDiagnostics,
                clearDiagnosticCacheBeforeRefresh: clearDiagnosticCacheBeforeRefresh,
                clearRunReceiptCacheBeforeRefresh: clearRunReceiptCacheBeforeRefresh,
                reconcileRunPresentation: reconcileRunPresentationAfterRefresh
            )
        }

        guard !hasBegunApplicationShutdown else { return }

        if shouldStartPeriodicMaintenance {
            startPeriodicHistoryRetentionMaintenanceIfNeeded()
        }
        if shouldRerunRetention {
            performLocalHistoryRetention()
        }
    }

    private func startPeriodicHistoryRetentionMaintenanceIfNeeded() {
        guard !hasBegunApplicationShutdown else { return }
        guard periodicHistoryRetentionMaintenanceTask == nil else { return }
        guard localHistoryMaintenance != nil else { return }
        guard let interval = historyRetentionMaintenanceInterval else { return }
        guard interval > .zero else { return }

        periodicHistoryRetentionMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                let modelStillExists = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    self.performLocalHistoryRetention()
                    return true
                }
                guard modelStillExists else { return }
            }
        }
    }

    private func finishLocalHistoryMaintenanceTask(id: UUID) {
        localHistoryMaintenanceTasks.removeValue(forKey: id)
    }

    private func applyLocalHistoryMaintenanceCounts(_ counts: LocalHistoryMaintenanceCounts) {
        lastLocalHistoryRemovedCount = counts.totalRemovedCount
        lastPreservedActiveClipboardCount = counts.preservedActiveClipboardCount
    }

    private func refreshHistoryCaches(
        clipboard: Bool,
        runHistory: Bool,
        diagnostics: Bool,
        clearDiagnosticCacheBeforeRefresh: Bool,
        clearRunReceiptCacheBeforeRefresh: Bool,
        reconcileRunPresentation: Bool
    ) async {
        guard !hasBegunApplicationShutdown else { return }
        if clipboard, let deliveryStack {
            let snapshot = await deliveryStack.clipboardSnapshot()
            guard !hasBegunApplicationShutdown else { return }
            applyClipboardStoreSnapshot(snapshot)
        }
        guard !hasBegunApplicationShutdown else { return }
        if runHistory {
            // Invalidate an older read before changing the local projection.
            // A logical clear remains visible even if the follow-up repository
            // read fails; retention removes only locally known expired rows.
            runReceiptLoadGeneration += 1
            if clearRunReceiptCacheBeforeRefresh {
                workflowRunReceiptsByRunID.removeAll()
            } else if let cutoff = runHistoryRetentionPeriod.cutoffDate(relativeTo: Date()) {
                workflowRunReceiptsByRunID = workflowRunReceiptsByRunID.filter {
                    $0.value.timestamp >= cutoff
                }
            }
            loadHistory(reconcileRunPresentation: reconcileRunPresentation)
            resetRunHistoryBrowsing()
        }
        guard !hasBegunApplicationShutdown else { return }
        if diagnostics {
            if clearDiagnosticCacheBeforeRefresh {
                diagnosticEvents.removeAll()
            }
            loadDiagnostics()
        }
    }

    private func localizedPendingReason(_ reason: LocalHistoryMaintenancePendingReason) -> String {
        switch (reason, language) {
        case (.logicalDeletionFailed, .english):
            return "Some local history could not be removed. Retry cleanup."
        case (.logicalDeletionFailed, .simplifiedChinese):
            return "部分本地历史未能移除，请重试清理。"
        case (.stateWriteFailed, .english):
            return "Cleanup progress could not be saved. Retry cleanup."
        case (.stateWriteFailed, .simplifiedChinese):
            return "无法保存清理进度，请重试。"
        case (.physicalPurgeFailed, .english):
            return "Logical cleanup completed, but storage residue cleanup is pending."
        case (.physicalPurgeFailed, .simplifiedChinese):
            return "逻辑清理已完成，但存储残留清理仍待重试。"
        case (.stateRemovalFailed, .english):
            return "Cleanup completed, but its pending marker could not be removed. Retry cleanup."
        case (.stateRemovalFailed, .simplifiedChinese):
            return "清理已完成，但待处理标记未能移除，请重试。"
        }
    }

    private func localizedBlockReason(_ reason: LocalHistoryMaintenanceBlockReason) -> String {
        switch (reason, language) {
        case (.stateReadFailed, .english):
            return "Cleanup state could not be read. History was left unchanged."
        case (.stateReadFailed, .simplifiedChinese):
            return "无法读取清理状态，历史记录保持不变。"
        case (.invalidPendingState, .english):
            return "Cleanup is blocked by an invalid pending state. History was left unchanged."
        case (.invalidPendingState, .simplifiedChinese):
            return "待处理清理状态无效，清理已阻断且历史记录保持不变。"
        case (.stateWriteFailed, .english):
            return "Cleanup intent could not be saved. History was left unchanged."
        case (.stateWriteFailed, .simplifiedChinese):
            return "无法保存清理意图，历史记录保持不变。"
        }
    }
}
