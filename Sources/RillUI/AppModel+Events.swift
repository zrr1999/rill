import AppKit
import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

private enum EventFeedPrivacyBodyKind {
    case recognition
    case resolution
    case transformation
    case processingStep(WorkflowTextStep)
    case action(String)
    case runCompleted
    case failure

    var fullPrefix: LocalizedText {
        switch self {
        case .processingStep(let step):
            return LocalizedText(
                english: HistoryTextStepPresentation.logHeader(step, language: .english),
                simplifiedChinese: HistoryTextStepPresentation.logHeader(step, language: .simplifiedChinese)
            )
        case .recognition:
            return LocalizedText(english: "Recognition: ", simplifiedChinese: "识别结果：")
        case .resolution:
            return LocalizedText(english: "Resolution completed: ", simplifiedChinese: "消歧完成：")
        case .transformation:
            return LocalizedText(english: "Transformation applied: ", simplifiedChinese: "文本处理完成：")
        case .action(let actionID):
            return LocalizedText(
                english: "Action \(actionID): ",
                simplifiedChinese: "动作 \(actionID)："
            )
        case .runCompleted:
            return LocalizedText(english: "Run completed: ", simplifiedChinese: "工作流完成：")
        case .failure:
            return LocalizedText(english: "Failure: ", simplifiedChinese: "失败：")
        }
    }

    var summaryPrefix: LocalizedText {
        switch self {
        case .processingStep:
            return fullPrefix
        case .recognition:
            return LocalizedText(english: "Recognition summary: ", simplifiedChinese: "识别摘要：")
        case .resolution:
            return LocalizedText(english: "Resolution summary: ", simplifiedChinese: "消歧摘要：")
        case .transformation:
            return LocalizedText(english: "Transformation summary: ", simplifiedChinese: "文本处理摘要：")
        case .action(let actionID):
            return LocalizedText(
                english: "Action \(actionID) result summary: ",
                simplifiedChinese: "动作 \(actionID) 结果摘要："
            )
        case .runCompleted:
            return LocalizedText(english: "Run result summary: ", simplifiedChinese: "运行结果摘要：")
        case .failure:
            return LocalizedText(english: "Failure summary: ", simplifiedChinese: "失败摘要：")
        }
    }

    var hiddenSummary: LocalizedText {
        switch self {
        case .processingStep:
            return fullPrefix
        case .recognition:
            return LocalizedText(english: "Recognition completed.", simplifiedChinese: "识别已完成。")
        case .resolution:
            return LocalizedText(english: "Resolution completed.", simplifiedChinese: "消歧已完成。")
        case .transformation:
            return LocalizedText(
                english: "Text transformation completed.",
                simplifiedChinese: "文本处理已完成。"
            )
        case .action(let actionID):
            return LocalizedText(
                english: "Action \(actionID) finished.",
                simplifiedChinese: "动作 \(actionID) 已结束。"
            )
        case .runCompleted:
            return LocalizedText(english: "Run completed.", simplifiedChinese: "工作流已完成。")
        case .failure:
            return LocalizedText(english: "Run failed.", simplifiedChinese: "工作流失败。")
        }
    }
}

private func actionResultPresentation(_ result: ActionResult) -> LocalizedText {
    switch result {
    case .injected:
        LocalizedText(english: "Text was inserted.", simplifiedChinese: "文本已输入。")
    case .copiedToClipboard:
        LocalizedText(english: "Text was copied to the clipboard.", simplifiedChinese: "文本已复制到剪贴板。")
    case .storedRecord:
        LocalizedText(english: "Text was stored as a record.", simplifiedChinese: "文本已存为记录。")
    case .externalOutput:
        LocalizedText(english: "External output completed.", simplifiedChinese: "外部输出已完成。")
    case .skipped:
        LocalizedText(
            english: "An output action was skipped. Review the workflow, then retry if needed.",
            simplifiedChinese: "一个输出动作已跳过。请检查工作流，必要时重试。"
        )
    case .failed:
        LocalizedText(
            english: "An output action failed. Open Diagnostics for a safe summary, then retry.",
            simplifiedChinese: "一个输出动作失败。请在诊断中查看安全摘要后重试。"
        )
    }
}

extension AppModel {
  public func refreshDiagnostics() {
    loadDiagnostics()
  }

  func diagnostics(for runID: UUID) async throws -> [DiagnosticEvent] {
    let generation = self.history.diagnosticsLoadGeneration
    let events: [DiagnosticEvent]
    if let diagnosticRepository {
      events = try await diagnosticRepository.events(matching: DiagnosticQuery(runID: runID, limit: 20))
    } else {
      events = Array(Self.sortedDiagnosticEvents(self.history.diagnosticEvents.filter { $0.runID == runID }).prefix(20))
    }
    try Task.checkCancellation()
    guard !hasBegunApplicationShutdown, self.history.diagnosticsLoadGeneration == generation else {
      throw CancellationError()
    }
    return events.map(DiagnosticEventSanitizer.sanitize)
  }

  func applyDiagnosticEvents(_ events: [DiagnosticEvent]) {
    guard !events.isEmpty else { return }
    self.history.diagnosticEvents = Array(
      Self.sortedDiagnosticEvents(self.history.diagnosticEvents + events).prefix(200)
    )
    for event in events {
      if event.name == .sessionTransformFallback {
        append(
          english: "Text cleanup was skipped; the complete text before cleanup was retained.",
          simplifiedChinese: "未完成智能整理，已保留整理前的完整文本。"
        )
        continue
      }
      append(
        english: "[\(L10n.subsystem(event.subsystem, language: .english))] \(event.message)",
        simplifiedChinese:
          "[\(L10n.subsystem(event.subsystem, language: .simplifiedChinese))] \(event.message)"
      )
    }
  }

  static func sortedDiagnosticEvents(_ events: [DiagnosticEvent]) -> [DiagnosticEvent] {
    events.sorted { $0.timestamp > $1.timestamp }
  }

    /// Applies the immediate UI side of an explicit stop request. The runtime
    /// cancellation remains run-scoped; this method only clears presentation
    /// when the requested run still owns the manual capture, including after
    /// its final hidden presentation update.
    public func markLiveAudioRunStoppedByUser(runID: UUID) {
        let matchesWorkflowAudioCapture = voice.workflowAudioCaptureRunID == runID
        let matchesUntrackedVisibleCapture = voice.workflowAudioCaptureRunID == nil
            && voice.currentCaptureLiveSubtitleSnapshot?.runID == runID
        guard matchesWorkflowAudioCapture || matchesUntrackedVisibleCapture else { return }
        if self.voice.activeRunID == runID {
            self.voice.activeRunID = nil
        }
        voice.finish(runID)
        self.voice.isRunning = !pendingRuns.isEmpty
        self.voice.workflowAudioRunState = .idle
        if matchesWorkflowAudioCapture {
            voice.workflowAudioCaptureRunID = nil
        }
        if voice.currentCaptureLiveSubtitleSnapshot?.runID == runID {
            voice.applyCurrentCaptureLiveSubtitleSnapshot(nil)
            voice.lastLiveSubtitleMeterRefreshAt = nil
        }
        voice.refreshLiveSubtitlePresentation()
        append(
            english: "Recording stopped.",
            simplifiedChinese: "录音已停止。"
        )
    }

    func startListening() {
        listenerTask?.cancel()
        let diagnosticEventRelay = DiagnosticEventRelay { [weak self] events in
            await MainActor.run {
                self?.applyDiagnosticEvents(events)
            }
        }
        let stream = eventBus.lifecycleDeliveryStream
        listenerTask = Task { [weak self, diagnosticEventRelay, stream] in
            for await delivery in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                switch delivery {
                case .event(let event):
                    if case .diagnostic(let diagnosticEvent) = event {
                        await diagnosticEventRelay.enqueue(diagnosticEvent)
                        continue
                    }

                    let shouldContinue = await MainActor.run { () -> Bool in
                        self.handle(event)
                        return true
                    }
                    guard shouldContinue else { break }
                case .barrier(let barrierID):
                    await diagnosticEventRelay.drain()
                    await MainActor.run {
                        self.finishEventListenerBarrier(barrierID)
                    }
                }
            }
            await diagnosticEventRelay.drain()
            await diagnosticEventRelay.cancel()
        }
    }

    /// Waits until the UI projection has handled every event accepted by the
    /// lifecycle stream before this call. This is a synchronization contract,
    /// not a time-based readiness guess, and is also useful to callers that
    /// need a consistent presentation snapshot without stopping the listener.
    public func synchronizeEventListener() async {
        guard listenerTask != nil, !hasStoppedEventListener else { return }

        let barrierID = UUID()
        await withCheckedContinuation { continuation in
            eventListenerBarrierContinuations[barrierID] = continuation
            Task { [eventBus] in
                await eventBus.publishBarrier(barrierID)
            }
        }
    }

    /// Stops the UI event projection only after every event accepted before
    /// the barrier has been handled. Call this after all runtime producers have
    /// stopped and before flushing tracked persistence writes.
    public func drainAndStopEventListenerForApplicationShutdown() async {
        beginApplicationShutdown()
        guard !hasStoppedEventListener else { return }
        if let eventListenerShutdownTask {
            await eventListenerShutdownTask.value
            return
        }

        let shutdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performEventListenerShutdown()
        }
        eventListenerShutdownTask = shutdownTask
        await shutdownTask.value
    }

    private func performEventListenerShutdown() async {
        guard let listenerTask else {
            hasStoppedEventListener = true
            eventListenerShutdownTask = nil
            return
        }

        await synchronizeEventListener()

        listenerTask.cancel()
        await listenerTask.value
        self.listenerTask = nil
        hasStoppedEventListener = true
        eventListenerShutdownTask = nil
    }

    private func finishEventListenerBarrier(_ barrierID: UUID) {
        eventListenerBarrierContinuations.removeValue(forKey: barrierID)?.resume()
    }

    func handle(_ event: RillEvent) {
        switch event {
        case .runStarted(let run):
            voice.begin(run)
            self.voice.workflowAudioRunState = .idle
            lastFailure = nil
            append(
                english: "Run started: \(L10n.workflowName(run.workflow, language: .english))",
                simplifiedChinese: "工作流开始：\(L10n.workflowName(run.workflow, language: .simplifiedChinese))"
            )
        case .runReceiptRepositoryChanged(let change):
            history.noteNewRunAvailableForHistoryBrowsing()
            // The event is only an invalidation edge. A clear may have removed
            // the receipt after its insert returned but before event delivery,
            // so discard the old projection and admit only a fresh repository
            // snapshot. A failed reload therefore remains fail-closed.
            self.history.workflowRunReceiptsByRunID.removeValue(forKey: change.runID)
            loadRunReceipts(requiredRunIDs: [change.runID])
        case .runStageChanged(let identity, let stage):
            voice.updateStage(stage, from: identity)
        case .contextCaptured(_, let context):
            let appName = context.focus.applicationName ?? "Unknown"
            append(
                english: "Context captured from \(appName)",
                simplifiedChinese: "已捕获上下文：\(appName)"
            )
        case .recognitionCompleted(let identity, let recognition):
            voice.updateText(recognition.bestText, from: identity)
            guard pendingRuns.isEmpty else { break }
            appendPrivacyProtectedBody(
                english: recognition.bestText,
                simplifiedChinese: recognition.bestText,
                kind: .recognition
            )
        case .liveSubtitleUpdated(let snapshot):
            voice.applyLiveSubtitleUpdate(snapshot)
        case .audioProcessingQueueUpdated(let snapshot):
            voice.audioProcessingQueueSnapshot = snapshot.isVisible ? snapshot : nil
            voice.refreshLiveSubtitlePresentation()
        case .failedAudioRecoveryUpdated(let receipts):
            self.voice.failedAudioRecoveryReceipts = receipts
            let recoveredRunIDs = Set(receipts.map(\.originalRunID))
            self.voice.failedAudioRecoveryUnavailableReasonsByRunID =
                self.voice.failedAudioRecoveryUnavailableReasonsByRunID.filter {
                    !recoveredRunIDs.contains($0.key)
                }
        case .failedAudioRecoveryUnavailable(let runID, let reason):
            self.voice.failedAudioRecoveryUnavailableReasonsByRunID[runID] = reason
            let retainedRunIDs = Set(self.history.historyRecords.compactMap(\.runID)).union([runID])
            self.voice.failedAudioRecoveryUnavailableReasonsByRunID =
                self.voice.failedAudioRecoveryUnavailableReasonsByRunID.filter {
                    retainedRunIDs.contains($0.key)
                }
            self.voice.failedAudioRecoveryError = failedAudioRecoveryUnavailableMessage(reason)
        case .candidateResolutionRequested(let candidateCase):
            self.voice.pendingResolution = candidateCase
            append(
                english: "Candidate resolution requested",
                simplifiedChinese: "已请求候选词消歧"
            )
        case .candidateResolutionFinished(let identity, _, let resolvedText):
            if self.voice.pendingResolution?.runID == identity.runID { self.voice.pendingResolution = nil }
            voice.updateText(resolvedText, from: identity)
            guard pendingRuns.isEmpty else { break }
            appendPrivacyProtectedBody(
                english: resolvedText,
                simplifiedChinese: resolvedText,
                kind: .resolution
            )
        case .runTextStepRecorded(let runID, let step):
            guard pendingRuns[runID]?.trigger.isVoiceCapture == true else { return }
            if let text = step.outputText {
                appendPrivacyProtectedBody(
                    english: text, simplifiedChinese: text, kind: .processingStep(step)
                )
            } else {
                let summary = EventFeedPrivacyBodyKind.processingStep(step).hiddenSummary
                append(english: summary.english, simplifiedChinese: summary.simplifiedChinese)
            }
        case .transformationApplied(let identity, _, let text):
            voice.updateText(text, from: identity)
            guard pendingRuns.isEmpty else { break }
            appendPrivacyProtectedBody(
                english: text,
                simplifiedChinese: text,
                kind: .transformation
            )
        case .actionExecuted(_, _, let result):
            let presentation = actionResultPresentation(result)
            append(
                english: presentation.english,
                simplifiedChinese: presentation.simplifiedChinese
            )
        case .recordPanelRequested:
            showRecordPanel()
        case .runHistoryUpdated(let update):
            switch update {
            case .persisted:
                loadHistory()
            case .sessionOnly(let record):
                cacheHistoryRecord(record)
                append(
                    english: "History persistence is unavailable. This run is visible only for the current session.",
                    simplifiedChinese: "历史记录持久化不可用；这次运行仅在当前会话中可见。"
                )
            }
        case .runCompleted(let summary):
            let ownsPresentation = self.voice.activeRunID == summary.runID
            voice.complete(summary)
            let completedWorkflowAudioCapture = retireWorkflowAudioCapture(
                matching: summary.runID
            )
            if (ownsPresentation || completedWorkflowAudioCapture) && pendingRuns.isEmpty {
                self.voice.isRunning = false
                if self.voice.activeRunID == summary.runID {
                    self.voice.activeRunID = nil
                }
            }
            if ownsPresentation { lastFailure = nil }
            if summary.trigger.isVoiceCapture {
                appendPrivacyProtectedBody(
                    english: summary.finalText,
                    simplifiedChinese: summary.finalText,
                    kind: .runCompleted
                )
            } else {
                // Record payloads already have their own store.
                // Their closed invocation kind is authoritative even when the
                // selected workflow happens to declare a speech recognizer.
                append(
                    english: "Non-voice run completed.",
                    simplifiedChinese: "非语音工作流已完成。"
                )
            }
            voice.scheduleLiveSubtitleHide()
        case .runCancelled(let summary):
            let cancelledCurrentCapture = voice.currentCaptureLiveSubtitleSnapshot?.runID == summary.runID
            let cancelledWorkflowAudioCapture = retireWorkflowAudioCapture(
                matching: summary.runID
            )
            if self.voice.activeRunID == summary.runID
                || cancelledCurrentCapture
                || cancelledWorkflowAudioCapture
            {
                self.voice.isRunning = false
                if self.voice.activeRunID == summary.runID {
                    self.voice.activeRunID = nil
                }
            }
            voice.finish(summary.runID)
            if self.voice.pendingResolution?.runID == summary.runID {
                self.voice.pendingResolution = nil
            }
            append(
                english: summary.wasPartiallyCompleted
                    ? "Run cancelled after partial completion."
                    : "Run cancelled.",
                simplifiedChinese: summary.wasPartiallyCompleted
                    ? "工作流在部分完成后已取消。"
                    : "工作流已取消。"
            )
            voice.scheduleLiveSubtitleHide()
        case .runFailed(let failedRunID, _, let message):
            let failurePresentation = RunFailurePresentation.localizedText(for: message)
            if failedRunID == self.voice.activeRunID || self.voice.activeRunID == nil {
                lastFailure = failurePresentation.string(for: self.settings.language)
            }
            let failedCurrentCapture = failedRunID != nil
                && voice.currentCaptureLiveSubtitleSnapshot?.runID == failedRunID
            let failedActiveRun = failedRunID.map { self.voice.activeRunID == $0 } ?? false
            let failedWorkflowAudioCapture = retireWorkflowAudioCapture(
                matching: failedRunID
            )
            if failedActiveRun || failedCurrentCapture || failedWorkflowAudioCapture {
                self.voice.isRunning = false
                if failedActiveRun {
                    self.voice.activeRunID = nil
                }
            }
            if let failedRunID { voice.finish(failedRunID) }
            append(
                english: failurePresentation.english,
                simplifiedChinese: failurePresentation.simplifiedChinese
            )
            voice.scheduleLiveSubtitleHide()
        case .diagnostic(let event):
            applyDiagnosticEvents([event])
        }
    }

    @discardableResult
    private func retireWorkflowAudioCapture(matching runID: UUID?) -> Bool {
        guard let runID else { return false }
        let matchesTrackedCapture = voice.workflowAudioCaptureRunID == runID
        let matchesUntrackedVisibleCapture = voice.workflowAudioCaptureRunID == nil
            && voice.currentCaptureLiveSubtitleSnapshot?.runID == runID
            && self.voice.workflowAudioRunState != .idle
        guard matchesTrackedCapture || matchesUntrackedVisibleCapture else { return false }
        voice.workflowAudioCaptureRunID = nil
        self.voice.workflowAudioRunState = .idle
        return true
    }

    func append(english: String, simplifiedChinese: String) {
        append(EventFeedEntry(english: english, simplifiedChinese: simplifiedChinese))
    }

    private func appendPrivacyProtectedBody(
        english: String,
        simplifiedChinese: String,
        kind: EventFeedPrivacyBodyKind
    ) {
        append(
            EventFeedEntry(
                privacyProtectedBody: LocalizedText(
                    english: english,
                    simplifiedChinese: simplifiedChinese
                ),
                fullPrefix: kind.fullPrefix,
                summaryPrefix: kind.summaryPrefix,
                hiddenSummary: kind.hiddenSummary
            )
        )
    }

    private func append(_ entry: EventFeedEntry) {
        history.append(entry)
    }

    private func cacheHistoryRecord(_ record: WorkflowResultRecord) {
        history.noteNewRunAvailableForHistoryBrowsing()
        self.history.historyRecords.removeAll { $0.id == record.id }
        self.history.historyRecords.insert(record, at: 0)
        if self.history.historyRecords.count > 50 {
            self.history.historyRecords.removeLast(self.history.historyRecords.count - 50)
        }
    }

    func loadHistory(reconcileRunPresentation: Bool = false) {
        guard !hasBegunApplicationShutdown else { return }
        loadRunReceipts()
        guard let historyRepository else {
            self.history.historyLoadState = .loaded
            if reconcileRunPresentation {
                self.history.historyRecords.removeAll()
                reconcileRunDerivedPresentation(with: [])
            }
            return
        }
        self.history.historyLoadState = .loading
        self.history.historyLoadGeneration += 1
        let generation = self.history.historyLoadGeneration
        let since = history.runHistoryRetentionPeriod.cutoffDate(relativeTo: Date())
        let taskID = UUID()
        let task = Task { @MainActor [weak self, historyRepository] in
            guard let self else { return }
            defer { self.finishHistoryProjectionLoadTask(id: taskID) }
            guard !Task.isCancelled,
                  !self.hasBegunApplicationShutdown,
                  self.history.historyLoadGeneration == generation else {
                return
            }
            do {
                let stored = try await historyRepository.records(
                    matching: HistoryQuery(since: since, limit: 50)
                ).map(HistoryRecordSanitizer.sanitize)
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.history.historyLoadGeneration == generation else {
                    return
                }
                self.history.historyRecords = stored
                self.history.historyLoadState = .loaded
                self.loadRunReceipts(
                    requiredRunIDs: Set(stored.compactMap(\.runID))
                )
                let retainedRunIDs = Set(stored.compactMap(\.runID))
                self.voice.failedAudioRecoveryUnavailableReasonsByRunID =
                    self.voice.failedAudioRecoveryUnavailableReasonsByRunID.filter {
                        retainedRunIDs.contains($0.key)
                    }
                if reconcileRunPresentation {
                    self.reconcileRunDerivedPresentation(with: stored)
                }
            } catch {
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.history.historyLoadGeneration == generation else {
                    return
                }
                if reconcileRunPresentation {
                    self.history.historyRecords.removeAll()
                    self.reconcileRunDerivedPresentation(with: [])
                }
                self.history.historyLoadState = .failed(.repositoryUnavailable)
                self.append(
                    english: "History repository is unavailable.",
                    simplifiedChinese: "历史记录仓库不可用。"
                )
            }
        }
        self.history.historyProjectionLoadTasks[taskID] = task
    }

    public func retryHistoryLoad() {
        loadHistory()
    }

    func loadRunReceipts(requiredRunIDs additionalRunIDs: Set<UUID> = []) {
        guard !hasBegunApplicationShutdown else { return }
        guard let runReceiptRepository else {
            self.history.workflowRunReceiptsByRunID.removeAll()
            return
        }
        self.history.runReceiptLoadGeneration += 1
        let generation = self.history.runReceiptLoadGeneration
        let since = history.runHistoryRetentionPeriod.cutoffDate(relativeTo: Date())
        let requiredRunIDs = additionalRunIDs.union(
            self.history.historyRecords.compactMap(\.runID)
        )
        let taskID = UUID()
        let task = Task { @MainActor [weak self, runReceiptRepository] in
            guard let self else { return }
            defer { self.finishHistoryProjectionLoadTask(id: taskID) }
            guard !Task.isCancelled,
                  !self.hasBegunApplicationShutdown,
                  self.history.runReceiptLoadGeneration == generation else {
                return
            }
            do {
                async let recentReceipts = runReceiptRepository.receipts(
                    matching: WorkflowRunReceiptQuery(since: since, limit: 100)
                )
                async let requiredReceipts = runReceiptRepository.receipts(
                    matching: WorkflowRunReceiptQuery(runIDs: requiredRunIDs)
                )
                let (recent, required) = try await (recentReceipts, requiredReceipts)
                let receipts = recent + required
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.history.runReceiptLoadGeneration == generation else {
                    return
                }
                self.history.workflowRunReceiptsByRunID = Dictionary(
                    receipts.map { ($0.runID, $0) },
                    uniquingKeysWith: { existing, _ in existing }
                )
            } catch {
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.history.runReceiptLoadGeneration == generation else {
                    return
                }
                self.append(
                    english: "Run receipt repository is unavailable.",
                    simplifiedChinese: "运行收据仓库不可用。"
                )
            }
        }
        self.history.historyProjectionLoadTasks[taskID] = task
    }

    func finishHistoryProjectionLoadTask(id: UUID) {
        self.history.historyProjectionLoadTasks.removeValue(forKey: id)
    }

    /// Waits until history, receipt, and diagnostic projections have reached
    /// a stable state. A completed history read may enqueue a receipt read, so
    /// the owner is checked again after every batch.
    func waitForHistoryProjectionLoads() async {
        while !self.history.historyProjectionLoadTasks.isEmpty {
            let tasks = Array(self.history.historyProjectionLoadTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    public func workflowRunReceipt(for runID: UUID?) -> WorkflowRunReceipt? {
        guard let runID else { return nil }
        return self.history.workflowRunReceiptsByRunID[runID]
    }

    private func reconcileRunDerivedPresentation(with records: [WorkflowResultRecord]) {
        self.voice.lastCompletedText = records.first(where: { record in
            record.outcome == .completed &&
                !(record.finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        })?.finalText
        lastFailure = records.first(where: { $0.outcome == .failed })
            .map {
                RunFailurePresentation.text(
                    for: $0.failureMessage,
                    language: self.settings.language
                )
            }
        self.voice.pendingResolution = nil
        self.history.eventFeed.removeAll()
        voice.reset()
        voice.applyCurrentCaptureLiveSubtitleSnapshot(nil)
        voice.workflowAudioCaptureRunID = nil
        voice.liveSubtitleSnapshot = nil
        voice.lastLiveSubtitleMeterRefreshAt = nil
        voice.pendingLiveSubtitleHideTask?.cancel()
        voice.pendingLiveSubtitleHideTask = nil
    }

    func isVoiceHistoryRecord(_ record: WorkflowResultRecord) -> Bool { history.isVoiceHistoryRecord(record) }

}
