import Foundation
import RillCore
import RillRuntime

public extension AppModel {
    func failedAudioRecoveryReceipt(
        for runID: UUID?
    ) -> FailedAudioRecoveryReceipt? {
        guard let runID else { return nil }
        return failedAudioRecoveryReceipts.first { $0.originalRunID == runID }
    }

    func failedAudioRecoveryUnavailableMessage(
        _ reason: FailedAudioRecoveryError
    ) -> String {
        let detail = localizedRecoveryErrorDetail(reason)
        return String(
            format: L10n.runText(.failedRecordingNotRetainedFormat, language: language),
            detail
        )
    }

    func setFailedAudioRecoveryEnabled(_ isEnabled: Bool) {
        guard !hasBegunApplicationShutdown,
              !isLoadingSettings,
              isEnabled != failedAudioRecoveryEnabled,
              !isUpdatingFailedAudioRecovery else {
            return
        }
        guard let settingsStore else {
            failedAudioRecoveryError = L10n.runText(
                .recoveryStorageUnavailable,
                language: language
            )
            return
        }

        isUpdatingFailedAudioRecovery = true
        failedAudioRecoveryError = nil
        let refreshAction = refreshFailedAudioRecoveryAction
        let task = Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(
                    isEnabled ? "true" : "false",
                    forKey: .failedAudioRecoveryEnabled
                )
                await MainActor.run {
                    self?.failedAudioRecoveryEnabled = isEnabled
                }
                do {
                    try await refreshAction(isEnabled)
                } catch let refreshError {
                    if isEnabled {
                        // Do not leave the queue opted in when its protected
                        // storage cannot be reconciled.
                        do {
                            try await settingsStore.setString(
                                "false",
                                forKey: .failedAudioRecoveryEnabled
                            )
                            await MainActor.run {
                                self?.failedAudioRecoveryEnabled = false
                            }
                        } catch {
                            // The durable opt-in remains true, so the UI must
                            // not claim it was rolled back. The runtime actor
                            // still stays fail-closed for this session.
                            await MainActor.run {
                                guard let self else { return }
                                self.isUpdatingFailedAudioRecovery = false
                                self.failedAudioRecoveryEnabled = true
                                self.failedAudioRecoveryError = L10n.runText(
                                    .recoveryEnabledStorageUnavailable,
                                    language: self.language
                                )
                            }
                            return
                        }
                    }
                    throw refreshError
                }
                await MainActor.run {
                    self?.failedAudioRecoveryError = nil
                    self?.isUpdatingFailedAudioRecovery = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isUpdatingFailedAudioRecovery = false
                    self.failedAudioRecoveryError = String(
                        format: L10n.runText(.recoveryUpdateFailedFormat, language: self.language),
                        self.localizedRecoveryErrorDetail(error)
                    )
                }
            }
        }
        registerPersistenceWrite(task)
    }

    func loadFailedAudioRecoveryReceipts() {
        guard !hasBegunApplicationShutdown else { return }
        failedAudioRecoveryLoadGeneration &+= 1
        let generation = failedAudioRecoveryLoadGeneration
        failedAudioRecoveryLoadTask?.cancel()
        guard failedAudioRecoveryEnabled else {
            failedAudioRecoveryReceipts = []
            failedAudioRecoveryLoadTask = nil
            return
        }
        let loadAction = loadFailedAudioRecoveryReceiptsAction
        let task = Task { @MainActor [weak self, loadAction] in
            guard let self else { return }
            defer {
                if self.failedAudioRecoveryLoadGeneration == generation {
                    self.failedAudioRecoveryLoadTask = nil
                }
            }
            do {
                let receipts = try await loadAction()
                try Task.checkCancellation()
                guard !self.hasBegunApplicationShutdown,
                      self.failedAudioRecoveryLoadGeneration == generation else { return }
                self.failedAudioRecoveryReceipts = receipts
                self.failedAudioRecoveryError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !self.hasBegunApplicationShutdown,
                      self.failedAudioRecoveryLoadGeneration == generation else { return }
                self.failedAudioRecoveryReceipts = []
                self.failedAudioRecoveryError = String(
                    format: L10n.runText(.recoveryLoadFailedFormat, language: self.language),
                    self.localizedRecoveryErrorDetail(error)
                )
            }
        }
        failedAudioRecoveryLoadTask = task
    }

    func waitForFailedAudioRecoveryLoad() async {
        while let task = failedAudioRecoveryLoadTask {
            await task.value
        }
    }

    func waitForFailedAudioRecoveryRetries() async {
        while !failedAudioRecoveryRetryTasks.isEmpty {
            let tasks = Array(failedAudioRecoveryRetryTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    func retryFailedAudioRecovery(_ receipt: FailedAudioRecoveryReceipt) {
        guard !hasBegunApplicationShutdown,
              !retryingFailedAudioRecoveryIDs.contains(receipt.id) else {
            return
        }
        guard receipt.status.canRetry else {
            failedAudioRecoveryError = L10n.runText(
                .recoveryRetryDuplicateWarning,
                language: language
            )
            return
        }
        guard let workflow = workflows.first(where: { $0.id == receipt.workflowID }) else {
            failedAudioRecoveryError = L10n.runText(
                .recoveryWorkflowUnavailable,
                language: language
            )
            return
        }

        failedAudioRecoveryError = nil
        retryingFailedAudioRecoveryIDs.insert(receipt.id)
        let retryAction = retryFailedAudioRecoveryAction
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.retryingFailedAudioRecoveryIDs.remove(receipt.id)
                self.failedAudioRecoveryRetryTasks.removeValue(forKey: receipt.id)
            }
            do {
                try Task.checkCancellation()
                let outcome = try await retryAction(receipt.id, workflow)
                try Task.checkCancellation()
                self.failedAudioRecoveryReceipts.removeAll { $0.id == receipt.id }
                switch outcome {
                case .completed:
                    self.failedAudioRecoveryError = nil
                case .completedCleanupPending:
                    self.failedAudioRecoveryError = L10n.runText(
                        .recoveryCleanupPending,
                        language: self.language
                    )
                }
            } catch is CancellationError {
                // Cancellation is the expected application-shutdown path. The
                // runtime controller restores the retryable receipt and removes
                // any decrypted temporary audio before returning.
            } catch {
                self.failedAudioRecoveryError = String(
                    format: L10n.runText(.recoveryRetryFailedFormat, language: self.language),
                    self.localizedRecoveryErrorDetail(error)
                )
            }
        }
        failedAudioRecoveryRetryTasks[receipt.id] = task
    }

    /// Prevents new operations, cancels the active index load and every retry,
    /// and waits until the runtime has restored durable state and cleaned any
    /// decrypted audio.
    /// Call this before draining events or flushing persistence during quit.
    func stopFailedAudioRecoveryRetriesForApplicationShutdown() async {
        hasBegunApplicationShutdown = true
        failedAudioRecoveryLoadGeneration &+= 1
        let loadTask = failedAudioRecoveryLoadTask
        failedAudioRecoveryLoadTask = nil
        loadTask?.cancel()
        await loadTask?.value
        let tasks = Array(failedAudioRecoveryRetryTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        failedAudioRecoveryRetryTasks.removeAll()
        retryingFailedAudioRecoveryIDs.removeAll()
    }

    func deleteFailedAudioRecovery(_ receipt: FailedAudioRecoveryReceipt) {
        guard !hasBegunApplicationShutdown,
              !retryingFailedAudioRecoveryIDs.contains(receipt.id) else {
            return
        }
        isUpdatingFailedAudioRecovery = true
        failedAudioRecoveryError = nil
        let deleteAction = deleteFailedAudioRecoveryAction
        Task { [weak self] in
            do {
                try await deleteAction(receipt.id)
                await MainActor.run {
                    self?.isUpdatingFailedAudioRecovery = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isUpdatingFailedAudioRecovery = false
                    self.failedAudioRecoveryError = String(
                        format: L10n.runText(.recoveryDeleteFailedFormat, language: self.language),
                        self.localizedRecoveryErrorDetail(error)
                    )
                }
            }
        }
    }

    func clearFailedAudioRecoveries() {
        guard !hasBegunApplicationShutdown,
              !isUpdatingFailedAudioRecovery,
              retryingFailedAudioRecoveryIDs.isEmpty else {
            return
        }
        isUpdatingFailedAudioRecovery = true
        failedAudioRecoveryError = nil
        let clearAction = clearFailedAudioRecoveryAction
        Task { [weak self] in
            do {
                try await clearAction()
                await MainActor.run {
                    self?.isUpdatingFailedAudioRecovery = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isUpdatingFailedAudioRecovery = false
                    self.failedAudioRecoveryError = String(
                        format: L10n.runText(.recoveryClearFailedFormat, language: self.language),
                        self.localizedRecoveryErrorDetail(error)
                    )
                }
            }
        }
    }
}

extension AppModel {
    func localizedRecoveryMessage(
        english: String,
        simplifiedChinese: String
    ) -> String {
        language == .english ? english : simplifiedChinese
    }

    func localizedRecoveryErrorDetail(_ error: Error) -> String {
        if let controllerError = error as? FailedAudioRecoveryController.ControllerError {
            let simplifiedChinese: String
            switch controllerError {
            case .retryAlreadyRunning:
                simplifiedChinese = "已有一条失败录音正在重试。"
            case .recoveryDisabled:
                simplifiedChinese = "失败录音恢复已关闭。"
            case .retryFailed:
                simplifiedChinese = "无法重新处理失败录音。"
            case .retryFailedCleanupPending:
                simplifiedChinese = "识别失败，且无法安全恢复重试状态。"
            case .plaintextCleanupPending:
                simplifiedChinese = "未加密的恢复临时录音可能仍待清理，暂时无法开始新的重试。"
            }
            return localizedRecoveryMessage(
                english: controllerError.errorDescription
                    ?? "Failed recording recovery is unavailable.",
                simplifiedChinese: simplifiedChinese
            )
        }
        guard let recoveryError = error as? FailedAudioRecoveryError else {
            return L10n.runText(.recoveryTemporarilyUnavailable, language: language)
        }
        let simplifiedChinese: String
        switch recoveryError {
        case .entryTooLarge:
            simplifiedChinese = "失败录音超过恢复大小上限。"
        case .expired:
            simplifiedChinese = "失败录音已过期。"
        case .invalidEntry:
            simplifiedChinese = "无法验证失败录音的完整性。"
        case .notFound:
            simplifiedChinese = "失败录音已不可用。"
        case .protectionUnavailable:
            simplifiedChinese = "无法保护或打开失败录音。"
        case .retryOutcomeUnknown:
            simplifiedChinese = "上一次重试结果未知，无法安全地重复请求。"
        case .storageUnavailable:
            simplifiedChinese = "失败录音恢复存储不可用。"
        case .unsupportedPayload:
            simplifiedChinese = "只有文件形式的录音可保留用于恢复。"
        }
        return localizedRecoveryMessage(
            english: recoveryError.errorDescription ?? "Failed recording recovery is unavailable.",
            simplifiedChinese: simplifiedChinese
        )
    }
}
