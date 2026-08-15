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
        return localizedRecoveryMessage(
            english: "The failed recording could not be retained. \(detail)",
            simplifiedChinese: "无法保留失败录音。\(detail)"
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
            failedAudioRecoveryError = localizedRecoveryMessage(
                english: "Encrypted failed recording recovery is unavailable because persistent settings storage is unavailable.",
                simplifiedChinese: "持久化设置存储不可用，因此无法使用加密的失败录音恢复。"
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
                                self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                                    english: "Recovery is saved as enabled, but protected storage is unavailable in this session. No new failed audio will be retained until storage recovers.",
                                    simplifiedChinese: "恢复设置已保存为开启，但本次会话的受保护存储不可用。在存储恢复前，不会保留新的失败录音。"
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
                    self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                        english: "Failed recording recovery could not be updated. \(self.localizedRecoveryErrorDetail(error))",
                        simplifiedChinese: "无法更新失败录音恢复。\(self.localizedRecoveryErrorDetail(error))"
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
                self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                    english: "Failed recordings could not be loaded. \(self.localizedRecoveryErrorDetail(error))",
                    simplifiedChinese: "无法加载失败录音。\(self.localizedRecoveryErrorDetail(error))"
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
            failedAudioRecoveryError = localizedRecoveryMessage(
                english: "A previous retry may have reached the speech provider. Delete this recording to avoid a duplicate request.",
                simplifiedChinese: "上一次重试可能已到达语音服务。为避免重复请求，请删除这条录音。"
            )
            return
        }
        guard let workflow = workflows.first(where: { $0.id == receipt.workflowID }) else {
            failedAudioRecoveryError = localizedRecoveryMessage(
                english: "The original workflow is no longer available. Delete this failed recording or restore the workflow first.",
                simplifiedChinese: "原工作流已不可用。请删除此失败录音，或先恢复该工作流。"
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
                    self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                        english: "Transcription completed, but recovery cleanup is pending; this can include an unencrypted temporary recording. Rill will keep retrying cleanup and will not repeat the provider request.",
                        simplifiedChinese: "转写已完成，但恢复清理仍待完成，其中可能包含未加密的临时录音。Rill 会继续重试清理，也不会重复请求语音服务。"
                    )
                }
            } catch is CancellationError {
                // Cancellation is the expected application-shutdown path. The
                // runtime controller restores the retryable receipt and removes
                // any decrypted temporary audio before returning.
            } catch {
                self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                    english: "The failed recording could not be retried. \(self.localizedRecoveryErrorDetail(error))",
                    simplifiedChinese: "无法重试失败录音。\(self.localizedRecoveryErrorDetail(error))"
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
                    self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                        english: "The failed recording could not be deleted. \(self.localizedRecoveryErrorDetail(error))",
                        simplifiedChinese: "无法删除失败录音。\(self.localizedRecoveryErrorDetail(error))"
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
                    self.failedAudioRecoveryError = self.localizedRecoveryMessage(
                        english: "Failed recordings could not be cleared. \(self.localizedRecoveryErrorDetail(error))",
                        simplifiedChinese: "无法清除失败录音。\(self.localizedRecoveryErrorDetail(error))"
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
            return localizedRecoveryMessage(
                english: "Failed recording recovery is temporarily unavailable. Retry the operation.",
                simplifiedChinese: "失败录音恢复暂时不可用。请重试此操作。"
            )
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
