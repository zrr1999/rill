import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

extension AppModel {
  /// Starts the irreversible clipboard-mutation shutdown boundary.
  public func sealRecordMutationsForApplicationShutdown() {
    beginApplicationShutdown()
    recordWorkspace.sealMutations()
    cancelResidentSpeechModelSynchronizationForApplicationShutdown()
  }

  /// Waits for mutations accepted before the shutdown boundary. Accepted
  /// writes are never cancelled because they may already own durable state.
  public func drainRecordMutationsForApplicationShutdown() async {
    beginApplicationShutdown()
    await recordWorkspace.shutdown()
  }

    public func setRecordRetentionPeriod(_ period: HistoryRetentionPeriod) {
        updateHistoryRetentionPeriod(
            period,
            currentPeriod: recordRetentionPeriod,
            key: .recordRetentionPeriod,
            isRecordSetting: true
        )
    }

    public func setRunHistoryRetentionPeriod(_ period: HistoryRetentionPeriod) {
        updateHistoryRetentionPeriod(
            period,
            currentPeriod: history.runHistoryRetentionPeriod,
            key: .runHistoryRetentionPeriod,
            isRecordSetting: false
        )
    }

    public func clearRecordHistory() {
        guard !hasBegunApplicationShutdown else { return }
        let task = Task { [recordWorkspace] in await recordWorkspace.cleanup.request() }
        persistenceWrites.track(task)
    }

    public func clearRunHistory() {
        guard !hasActiveOrQueuedVoiceRun else {
            self.history.localHistoryMaintenanceBlockedReason = L10n.runText(
                .clearRunHistoryBlockedActiveRun,
                language: self.settings.language
            )
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
                refreshRecords: false,
                refreshRunHistory: true,
                refreshDiagnostics: true,
                clearDiagnosticCacheBeforeRefresh: true,
                clearRunReceiptCacheBeforeRefresh: true,
                reconcileRunPresentationAfterRefresh: true
            )
            if case .blocked = result {
                return
            }
            guard self.voice.failedAudioRecoveryEnabled
                || !self.voice.failedAudioRecoveryReceipts.isEmpty else {
                return
            }
            self.clearFailedAudioRecoveries()
        }
        self.history.localHistoryMaintenanceTasks[taskID] = task
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
                refreshRecords: true,
                refreshRunHistory: true,
                refreshDiagnostics: true,
                clearRunReceiptCacheBeforeRefresh: true
            )
        }
        self.history.localHistoryMaintenanceTasks[taskID] = task
    }

    func performLocalHistoryRetention(
        now: Date = Date(),
        startPeriodicMaintenanceAfterCompletion: Bool = false
    ) {
        guard !hasBegunApplicationShutdown else {
            self.history.historyRetentionRerunRequested = false
            self.history.shouldStartPeriodicHistoryRetentionMaintenance = false
            return
        }
        if startPeriodicMaintenanceAfterCompletion {
            self.history.shouldStartPeriodicHistoryRetentionMaintenance = true
        }
        guard self.history.areHistoryRetentionSettingsAvailable else {
            self.history.shouldStartPeriodicHistoryRetentionMaintenance = false
            self.history.localHistoryMaintenanceBlockedReason = L10n.runText(
                .retentionCleanupPausedLoadFailed,
                language: self.settings.language
            )
            return
        }
        guard let localHistoryMaintenance else {
            self.history.shouldStartPeriodicHistoryRetentionMaintenance = false
            guard recordRetentionPeriod != .forever ||
                history.runHistoryRetentionPeriod != .forever else {
                return
            }
            self.history.localHistoryMaintenanceBlockedReason = L10n.runText(
                .retentionCleanupServiceUnavailable,
                language: self.settings.language
            )
            return
        }
        guard !self.history.isLocalHistoryMaintenanceRunning else {
            self.history.historyRetentionRerunRequested = true
            return
        }
        guard beginLocalHistoryMaintenance() else { return }
        let recordRetention = recordRetentionPeriod
        let runRetention = history.runHistoryRetentionPeriod

        let taskID = UUID()
        let task = Task { @MainActor [weak self, localHistoryMaintenance] in
            await self?.recordWorkspace.refreshRetentionSuggestion(olderThan: recordRetention.cutoffDate(relativeTo: now))
            let result = await localHistoryMaintenance.performRetention(
                recordRetention: .forever,
                runRetention: runRetention,
                now: now
            )
            guard let self else { return }
            defer { self.finishLocalHistoryMaintenanceTask(id: taskID) }
            await self.finishLocalHistoryMaintenance(
                result,
                refreshRecords: true,
                refreshRunHistory: true,
                refreshDiagnostics: true
            )
        }
        self.history.localHistoryMaintenanceTasks[taskID] = task
    }

    /// Closes every history-maintenance entry point, stops the periodic timer,
    /// and waits for an already-started destructive operation plus its cache
    /// projection reads to finish. The active operation is deliberately not
    /// cancelled: its durable transition must reach a stable completed, pending,
    /// or blocked result before quit.
    public func stopLocalHistoryMaintenanceForApplicationShutdown() async {
        beginApplicationShutdown()
        self.history.historyRetentionRerunRequested = false
        self.history.shouldStartPeriodicHistoryRetentionMaintenance = false
        self.history.historyLoadGeneration += 1
        self.history.runReceiptLoadGeneration += 1
        self.history.diagnosticsLoadGeneration += 1
        self.history.runHistoryBrowseGeneration += 1
        self.history.runHistoryBrowseTask?.cancel()
        self.history.runHistoryBrowseTask = nil
        for task in self.history.historyProjectionLoadTasks.values {
            task.cancel()
        }

        await history.stopPeriodicMaintenance()

        let activeTasks = Array(self.history.localHistoryMaintenanceTasks.values)
        for task in activeTasks {
            await task.value
        }
        self.history.localHistoryMaintenanceTasks.removeAll()

        // A maintenance completion may have started projection reads before the
        // terminal flag was set. No new reads can register after that flag, so
        // draining this owner to empty closes the final read/publish boundary.
        while !self.history.historyProjectionLoadTasks.isEmpty {
            let projectionTasks = Array(self.history.historyProjectionLoadTasks.values)
            for task in projectionTasks {
                task.cancel()
            }
            for task in projectionTasks {
                await task.value
            }
        }
    }

    /// Waits for the current maintenance generation to reach a stable result
    /// without disabling future maintenance or the periodic scheduler.
    func waitForLocalHistoryMaintenance() async {
        while !self.history.localHistoryMaintenanceTasks.isEmpty {
            let tasks = Array(self.history.localHistoryMaintenanceTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func updateHistoryRetentionPeriod(
        _ period: HistoryRetentionPeriod,
        currentPeriod: HistoryRetentionPeriod,
        key: AppSettingKey,
        isRecordSetting: Bool
    ) {
        let settingIsInvalid = isRecordSetting
            ? self.history.clipboardHistoryRetentionSettingIsInvalid
            : self.history.runHistoryRetentionSettingIsInvalid
        guard !hasBegunApplicationShutdown else { return }
        guard period != currentPeriod || settingIsInvalid else { return }
        // Initial settings restore owns the authoritative retention snapshot.
        // Accepting a user mutation before that snapshot settles can let the
        // late read overwrite a newer, longer period and start irreversible
        // cleanup with stale policy. The Settings UI mirrors this guard.
        guard !self.settings.isLoading else { return }
        guard !self.history.isUpdatingHistoryRetentionSettings, !self.history.isLocalHistoryMaintenanceRunning else { return }
        guard !self.settings.isRestoringSettings else { return }
        guard let settingsStore else {
            self.history.historyRetentionSettingsWriteError = L10n.runText(
                .retentionSaveStorageUnavailable,
                language: self.settings.language
            )
            refreshHistoryRetentionSettingsErrorPresentation()
            return
        }

        self.history.historyRetentionSettingsWriteError = nil
        refreshHistoryRetentionSettingsErrorPresentation()
        self.history.isUpdatingHistoryRetentionSettings = true
        let task = Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(period.rawValue, forKey: key)
                guard let self else { return }
                guard !self.hasBegunApplicationShutdown else {
                    self.history.isUpdatingHistoryRetentionSettings = false
                    return
                }
                let shouldPrune = Self.isShorterRetention(period, than: currentPeriod)
                if isRecordSetting {
                    self.recordRetentionPeriod = period
                    self.history.clipboardHistoryRetentionSettingIsInvalid = false
                } else {
                    self.history.applyRunHistoryRetentionPeriod(period)
                    self.history.runHistoryRetentionSettingIsInvalid = false
                }
                self.refreshHistoryRetentionSettingsErrorPresentation()
                self.history.isUpdatingHistoryRetentionSettings = false

                if shouldPrune {
                    self.performLocalHistoryRetention()
                } else if !isRecordSetting {
                    self.loadHistory()
                }
            } catch {
                guard let self else { return }
                self.history.isUpdatingHistoryRetentionSettings = false
                guard !self.hasBegunApplicationShutdown else { return }
                self.history.historyRetentionSettingsWriteError = L10n.runText(
                    .retentionSaveFailedRepair,
                    language: self.settings.language
                )
                self.refreshHistoryRetentionSettingsErrorPresentation()
                self.append(
                    english: L10n.runText(.retentionSaveFailedNotice, language: .english),
                    simplifiedChinese: L10n.runText(
                        .retentionSaveFailedNotice,
                        language: .simplifiedChinese
                    )
                )
            }
        }
        persistenceWrites.track(task)
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
              !self.history.isLocalHistoryMaintenanceRunning else {
            return false
        }
        self.history.isLocalHistoryMaintenanceRunning = true
        self.history.localHistoryMaintenancePendingReason = nil
        self.history.localHistoryMaintenanceBlockedReason = nil
        return true
    }

    private func finishWithUnavailableMaintenanceService() {
        self.history.isLocalHistoryMaintenanceRunning = false
        self.history.localHistoryMaintenanceBlockedReason = L10n.runText(
            .maintenanceServiceUnavailable,
            language: self.settings.language
        )
    }

    private func finishLocalHistoryMaintenance(
        _ result: LocalHistoryMaintenanceResult,
        refreshRecords: Bool,
        refreshRunHistory: Bool,
        refreshDiagnostics: Bool,
        clearDiagnosticCacheBeforeRefresh: Bool = false,
        clearRunReceiptCacheBeforeRefresh: Bool = false,
        reconcileRunPresentationAfterRefresh: Bool = false
    ) async {
        switch result {
        case .completed(let counts):
            applyLocalHistoryMaintenanceCounts(counts)
            self.history.localHistoryMaintenancePendingReason = nil
            self.history.localHistoryMaintenanceBlockedReason = nil
            if counts.totalRemovedCount > 0 || counts.preservedActiveRecordCount > 0 {
                append(
                    english: String(
                        format: L10n.runText(.localHistoryUpdatedFormat, language: .english),
                        counts.totalRemovedCount,
                        counts.preservedActiveRecordCount
                    ),
                    simplifiedChinese: String(
                        format: L10n.runText(
                            .localHistoryUpdatedFormat,
                            language: .simplifiedChinese
                        ),
                        counts.totalRemovedCount,
                        counts.preservedActiveRecordCount
                    )
                )
            }
        case .pending(let counts, let reason):
            applyLocalHistoryMaintenanceCounts(counts)
            self.history.localHistoryMaintenancePendingReason = localizedPendingReason(reason)
            self.history.localHistoryMaintenanceBlockedReason = nil
        case .blocked(let reason):
            self.history.lastLocalHistoryRemovedCount = 0
            self.history.lastPreservedActiveRecordCount = 0
            self.history.localHistoryMaintenancePendingReason = nil
            self.history.localHistoryMaintenanceBlockedReason = localizedBlockReason(reason)
        }

        self.history.isLocalHistoryMaintenanceRunning = false
        let shouldRerunRetention = self.history.historyRetentionRerunRequested
        self.history.historyRetentionRerunRequested = false
        let shouldStartPeriodicMaintenance = self.history.shouldStartPeriodicHistoryRetentionMaintenance
        self.history.shouldStartPeriodicHistoryRetentionMaintenance = false

        guard !hasBegunApplicationShutdown else {
            self.history.historyRetentionRerunRequested = false
            self.history.shouldStartPeriodicHistoryRetentionMaintenance = false
            return
        }

        if case .blocked = result {
            // A blocked result did not mutate history, so there are no caches to refresh.
        } else {
            await refreshHistoryCaches(
                clipboard: refreshRecords,
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
        guard self.history.periodicHistoryRetentionMaintenanceTask == nil else { return }
        guard localHistoryMaintenance != nil else { return }
        guard let interval = historyRetentionMaintenanceInterval else { return }
        guard interval > .zero else { return }

        history.startPeriodicMaintenance(interval: interval) { [weak self] in
            self?.performLocalHistoryRetention()
        }
    }

    private func finishLocalHistoryMaintenanceTask(id: UUID) {
        self.history.localHistoryMaintenanceTasks.removeValue(forKey: id)
    }

    private func applyLocalHistoryMaintenanceCounts(_ counts: LocalHistoryMaintenanceCounts) {
        self.history.lastLocalHistoryRemovedCount = counts.totalRemovedCount
        self.history.lastPreservedActiveRecordCount = counts.preservedActiveRecordCount
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
        _ = clipboard
        guard !hasBegunApplicationShutdown else { return }
        if runHistory {
            // Invalidate an older read before changing the local projection.
            // A logical clear remains visible even if the follow-up repository
            // read fails; retention removes only locally known expired rows.
            self.history.runReceiptLoadGeneration += 1
            if clearRunReceiptCacheBeforeRefresh {
                self.history.workflowRunReceiptsByRunID.removeAll()
            } else if let cutoff = history.runHistoryRetentionPeriod.cutoffDate(relativeTo: Date()) {
                self.history.workflowRunReceiptsByRunID = self.history.workflowRunReceiptsByRunID.filter {
                    $0.value.timestamp >= cutoff
                }
            }
            loadHistory(reconcileRunPresentation: reconcileRunPresentation)
            history.resetRunHistoryBrowsing()
        }
        guard !hasBegunApplicationShutdown else { return }
        if diagnostics {
            if clearDiagnosticCacheBeforeRefresh {
                self.history.diagnosticEvents.removeAll()
            }
            loadDiagnostics()
        }
    }

    private func localizedPendingReason(_ reason: LocalHistoryMaintenancePendingReason) -> String {
        switch (reason, self.settings.language) {
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
        switch (reason, self.settings.language) {
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
