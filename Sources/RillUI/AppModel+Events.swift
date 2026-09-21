import AppKit
import Foundation
import RillCore
import RillRuntime

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

  func applyDiagnosticEvents(_ events: [DiagnosticEvent]) {
    guard !events.isEmpty else { return }
    diagnosticEvents = Array(
      Self.sortedDiagnosticEvents(diagnosticEvents + events).prefix(200)
    )
    for event in events {
      if event.event == "session.transform.fallback" {
        append(
          english: "Text cleanup was skipped; the complete text before cleanup was retained.",
          simplifiedChinese: "未完成智能整理，已保留整理前的完整文本。"
        )
        continue
      }
      append(
        english: "[\(UIStrings.subsystem(event.subsystem, language: .english))] \(event.message)",
        simplifiedChinese:
          "[\(UIStrings.subsystem(event.subsystem, language: .simplifiedChinese))] \(event.message)"
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
        let matchesWorkflowAudioCapture = workflowAudioCaptureRunID == runID
        let matchesUntrackedVisibleCapture = workflowAudioCaptureRunID == nil
            && currentCaptureLiveSubtitleSnapshot?.runID == runID
        guard matchesWorkflowAudioCapture || matchesUntrackedVisibleCapture else { return }
        if activeRunID == runID {
            activeRunID = nil
        }
        isRunning = false
        workflowAudioRunState = .idle
        if matchesWorkflowAudioCapture {
            workflowAudioCaptureRunID = nil
        }
        if currentCaptureLiveSubtitleSnapshot?.runID == runID {
            currentCaptureLiveSubtitleSnapshot = nil
            lastLiveSubtitleMeterRefreshAt = nil
        }
        refreshLiveSubtitlePresentation()
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
        hasBegunApplicationShutdown = true
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
            activeRunID = run.runID
            isRunning = true
            workflowAudioRunState = .idle
            lastFailure = nil
            let wf = workflows.first(where: { $0.id == run.workflowID })
            let isStack = wf?.plan.output.deliveryPolicy.strategy == .collectionFirst
            pendingRuns[run.runID] = PendingRunInfo(
                workflowID: run.workflowID,
                workflow: run.workflow,
                trigger: run.trigger,
                isRecordRelated: isStack
            )
            append(
                english: "Run started: \(UIStrings.workflowName(run.workflow, language: .english))",
                simplifiedChinese: "工作流开始：\(UIStrings.workflowName(run.workflow, language: .simplifiedChinese))"
            )
        case .runReceiptRepositoryChanged(let change):
            noteNewRunAvailableForHistoryBrowsing()
            rememberTerminalReceiptTimestamp(
                change.terminalTimestamp,
                runID: change.runID,
                writeGeneration: change.writeGeneration
            )
            // The event is only an invalidation edge. A clear may have removed
            // the receipt after its insert returned but before event delivery,
            // so discard the old projection and admit only a fresh repository
            // snapshot. A failed reload therefore remains fail-closed.
            workflowRunReceiptsByRunID.removeValue(forKey: change.runID)
            loadRunReceipts(requiredRunIDs: [change.runID])
        case .contextCaptured(let context):
            let appName = context.focus.applicationName ?? "Unknown"
            append(
                english: "Context captured from \(appName)",
                simplifiedChinese: "已捕获上下文：\(appName)"
            )
        case .recognitionCompleted(let recognition):
            if !recognition.bestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastCompletedText = recognition.bestText
            }
            guard pendingRuns.isEmpty else { break }
            appendPrivacyProtectedBody(
                english: recognition.bestText,
                simplifiedChinese: recognition.bestText,
                kind: .recognition
            )
        case .liveSubtitleUpdated(let snapshot):
            applyLiveSubtitleUpdate(snapshot)
        case .audioProcessingQueueUpdated(let snapshot):
            audioProcessingQueueSnapshot = snapshot.isVisible ? snapshot : nil
            refreshLiveSubtitlePresentation()
        case .failedAudioRecoveryUpdated(let receipts):
            failedAudioRecoveryReceipts = receipts
            let recoveredRunIDs = Set(receipts.map(\.originalRunID))
            failedAudioRecoveryUnavailableReasonsByRunID =
                failedAudioRecoveryUnavailableReasonsByRunID.filter {
                    !recoveredRunIDs.contains($0.key)
                }
        case .failedAudioRecoveryUnavailable(let runID, let reason):
            failedAudioRecoveryUnavailableReasonsByRunID[runID] = reason
            let retainedRunIDs = Set(historyRecords.compactMap(\.runID)).union([runID])
            failedAudioRecoveryUnavailableReasonsByRunID =
                failedAudioRecoveryUnavailableReasonsByRunID.filter {
                    retainedRunIDs.contains($0.key)
                }
            failedAudioRecoveryError = failedAudioRecoveryUnavailableMessage(reason)
        case .candidateResolutionRequested(let candidateCase):
            pendingResolution = candidateCase
            append(
                english: "Candidate resolution requested",
                simplifiedChinese: "已请求候选词消歧"
            )
        case .candidateResolutionFinished(_, let resolvedText):
            pendingResolution = nil
            lastCompletedText = resolvedText
            guard pendingRuns.isEmpty else { break }
            appendPrivacyProtectedBody(
                english: resolvedText,
                simplifiedChinese: resolvedText,
                kind: .resolution
            )
        case .runTextStepRecorded(let runID, let step):
            guard pendingRuns[runID]?.trigger.isVoiceCapture == true else { return }
            pendingRuns[runID]?.processingSteps.append(step)
            if let text = step.outputText {
                appendPrivacyProtectedBody(
                    english: text, simplifiedChinese: text, kind: .processingStep(step)
                )
            } else {
                let summary = EventFeedPrivacyBodyKind.processingStep(step).hiddenSummary
                append(english: summary.english, simplifiedChinese: summary.simplifiedChinese)
            }
        case .transformationApplied(_, let text):
            lastCompletedText = text
            guard pendingRuns.isEmpty else { break }
            appendPrivacyProtectedBody(
                english: text,
                simplifiedChinese: text,
                kind: .transformation
            )
        case .actionExecuted(_, let result):
            let presentation = actionResultPresentation(result)
            append(
                english: presentation.english,
                simplifiedChinese: presentation.simplifiedChinese
            )
        case .recordPanelRequested:
            showRecordPanel()
        case .runCompleted(let summary):
            let completedWorkflowAudioCapture = retireWorkflowAudioCapture(
                matching: summary.runID
            )
            if activeRunID == summary.runID || completedWorkflowAudioCapture {
                isRunning = false
                if activeRunID == summary.runID {
                    activeRunID = nil
                }
            }
            lastFailure = nil
            let completedPending = pendingRuns.removeValue(forKey: summary.runID)
            if summary.trigger.isVoiceCapture {
                lastCompletedText = summary.finalText
                let isRecordRelated =
                    completedPending?.isRecordRelated
                    ?? (
                        summary.workflow.titleKey == .recordDelivery
                            || (workflows.first(where: { $0.id == summary.workflowID })?.plan.output.deliveryPolicy.strategy == .collectionFirst)
                    )
                recordHistory(WorkflowResultRecord(
                    runID: summary.runID,
                    workflowID: summary.workflowID,
                    workflow: summary.workflow,
                    finalText: summary.finalText,
                    timestamp: runHistoryTimestamp(
                        for: summary.runID,
                        fallback: summary.finishedAt
                    ),
                    isRecordRelated: isRecordRelated,
                    outcome: .completed,
                    correctionSource: summary.correctionSource,
                    trigger: summary.trigger
                ))
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
            scheduleLiveSubtitleHide()
        case .runCancelled(let summary):
            let cancelledCurrentCapture = currentCaptureLiveSubtitleSnapshot?.runID == summary.runID
            let cancelledWorkflowAudioCapture = retireWorkflowAudioCapture(
                matching: summary.runID
            )
            if activeRunID == summary.runID
                || cancelledCurrentCapture
                || cancelledWorkflowAudioCapture
            {
                isRunning = false
                if activeRunID == summary.runID {
                    activeRunID = nil
                }
            }
            pendingRuns.removeValue(forKey: summary.runID)
            if pendingResolution?.runID == summary.runID {
                pendingResolution = nil
            }
            append(
                english: summary.wasPartiallyCompleted
                    ? "Run cancelled after partial completion."
                    : "Run cancelled.",
                simplifiedChinese: summary.wasPartiallyCompleted
                    ? "工作流在部分完成后已取消。"
                    : "工作流已取消。"
            )
            scheduleLiveSubtitleHide()
        case .runFailed(let failedRunID, let workflow, let message):
            let failurePresentation = RunFailurePresentation.localizedText(for: message)
            lastFailure = failurePresentation.string(for: language)
            let failedCurrentCapture = failedRunID != nil
                && currentCaptureLiveSubtitleSnapshot?.runID == failedRunID
            let failedActiveRun = failedRunID.map { activeRunID == $0 } ?? false
            let failedWorkflowAudioCapture = retireWorkflowAudioCapture(
                matching: failedRunID
            )
            if failedActiveRun || failedCurrentCapture || failedWorkflowAudioCapture {
                isRunning = false
                if failedActiveRun {
                    activeRunID = nil
                }
            }
            if let failedRunID, let failedPending = pendingRuns.removeValue(forKey: failedRunID) {
                recordHistory(WorkflowResultRecord(
                    runID: failedRunID,
                    workflowID: failedPending.workflowID,
                    workflow: workflow ?? failedPending.workflow,
                    failureMessage: message,
                    timestamp: runHistoryTimestamp(
                        for: failedRunID,
                        fallback: Date()
                    ),
                    isRecordRelated: failedPending.isRecordRelated,
                    outcome: .failed,
                    correctionSource: failedPending.processingSteps.isEmpty ? nil : RecognitionCorrectionSource(
                        preMappingText: failedPending.processingSteps.first?.outputText ?? "",
                        context: VocabularyRuleContext(),
                        processingSteps: failedPending.processingSteps
                    ),
                    trigger: failedPending.trigger
                ))
            } else if let failedRunID, let workflow {
                recordHistory(WorkflowResultRecord(
                    runID: failedRunID,
                    workflow: workflow,
                    failureMessage: message,
                    timestamp: runHistoryTimestamp(
                        for: failedRunID,
                        fallback: Date()
                    ),
                    isRecordRelated: workflow.titleKey == .recordDelivery,
                    outcome: .failed
                ))
            }
            append(
                english: failurePresentation.english,
                simplifiedChinese: failurePresentation.simplifiedChinese
            )
            scheduleLiveSubtitleHide()
        case .diagnostic(let event):
            applyDiagnosticEvents([event])
        }
    }

    @discardableResult
    private func retireWorkflowAudioCapture(matching runID: UUID?) -> Bool {
        guard let runID else { return false }
        let matchesTrackedCapture = workflowAudioCaptureRunID == runID
        let matchesUntrackedVisibleCapture = workflowAudioCaptureRunID == nil
            && currentCaptureLiveSubtitleSnapshot?.runID == runID
            && workflowAudioRunState != .idle
        guard matchesTrackedCapture || matchesUntrackedVisibleCapture else { return false }
        workflowAudioCaptureRunID = nil
        workflowAudioRunState = .idle
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
        eventFeed.append(entry)
        if eventFeed.count > 200 {
            eventFeed.removeFirst(eventFeed.count - 200)
        }
    }

    func scheduleLiveSubtitleHide(after delay: Duration = .seconds(1)) {
        guard currentCaptureLiveSubtitleSnapshot != nil else { return }
        let currentRunID = currentCaptureLiveSubtitleSnapshot?.runID
        pendingLiveSubtitleHideTask?.cancel()
        pendingLiveSubtitleHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.currentCaptureLiveSubtitleSnapshot?.runID == currentRunID else { return }
            self.currentCaptureLiveSubtitleSnapshot = nil
            self.lastLiveSubtitleMeterRefreshAt = nil
            self.refreshLiveSubtitlePresentation()
        }
    }

    func recordHistory(_ record: WorkflowResultRecord) {
        let record = HistoryRecordSanitizer.sanitize(record)
        let terminalWriteGeneration = record.runID.flatMap {
            terminalReceiptWriteGenerationByRunID.removeValue(forKey: $0)
        }
        guard let historyRepository else {
            cacheHistoryRecord(record)
            return
        }
        let cacheGeneration = historyLoadGeneration
        let task = Task { [weak self, historyRepository] in
            do {
                let writeGeneration: RunHistoryWriteGeneration
                if let terminalWriteGeneration {
                    writeGeneration = terminalWriteGeneration
                } else {
                    // Compatibility events without a receipt coordinate begin a
                    // fresh History write intent at this repository boundary.
                    writeGeneration = try await historyRepository
                        .captureRunHistoryWriteGeneration()
                }
                try await historyRepository.save(
                    record,
                    generation: writeGeneration
                )
                await MainActor.run {
                    guard self?.historyLoadGeneration == cacheGeneration else { return }
                    self?.cacheHistoryRecord(record)
                }
            } catch HistoryRepositoryError.writeObsoletedByClearBarrier {
                // The user's logical clear is authoritative. Do not resurrect
                // an old-generation row in durable storage or the UI cache.
            } catch {
                await MainActor.run {
                    guard self?.historyLoadGeneration == cacheGeneration else { return }
                    self?.cacheHistoryRecord(record)
                    self?.append(
                        english: "History persistence is unavailable. This run is visible only for the current session.",
                        simplifiedChinese: "历史记录持久化不可用；这次运行仅在当前会话中可见。"
                    )
                }
            }
        }
        persistenceWrites.track(task)
    }

    private func cacheHistoryRecord(_ record: WorkflowResultRecord) {
        noteNewRunAvailableForHistoryBrowsing()
        historyRecords.insert(record, at: 0)
        if historyRecords.count > 50 {
            historyRecords.removeLast(historyRecords.count - 50)
        }
    }

    /// A finalized receipt is the durable terminal coordinate for its run. The
    /// UI receives it before runCompleted/runFailed, so the history row and its
    /// receipt retain the same terminal ordering coordinate. Logical generation
    /// independently prevents delayed persistence from crossing a clear.
    private func runHistoryTimestamp(for runID: UUID, fallback: Date) -> Date {
        if let timestamp = terminalReceiptTimestampByRunID.removeValue(forKey: runID) {
            terminalReceiptTimestampOrder.removeAll { $0 == runID }
            return timestamp
        }
        return workflowRunReceiptsByRunID[runID]?.timestamp ?? fallback
    }

    private func rememberTerminalReceiptTimestamp(
        _ timestamp: Date,
        runID: UUID,
        writeGeneration: RunHistoryWriteGeneration?
    ) {
        if terminalReceiptTimestampByRunID[runID] == nil {
            terminalReceiptTimestampOrder.append(runID)
        }
        terminalReceiptTimestampByRunID[runID] = timestamp
        if let writeGeneration {
            terminalReceiptWriteGenerationByRunID[runID] = writeGeneration
        }
        let capacity = 256
        if terminalReceiptTimestampOrder.count > capacity {
            let evictedRunID = terminalReceiptTimestampOrder.removeFirst()
            terminalReceiptTimestampByRunID.removeValue(forKey: evictedRunID)
            terminalReceiptWriteGenerationByRunID.removeValue(forKey: evictedRunID)
        }
    }

    func loadHistory(reconcileRunPresentation: Bool = false) {
        guard !hasBegunApplicationShutdown else { return }
        loadRunReceipts()
        guard let historyRepository else {
            historyLoadState = .loaded
            if reconcileRunPresentation {
                historyRecords.removeAll()
                reconcileRunDerivedPresentation(with: [])
            }
            return
        }
        historyLoadState = .loading
        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        let since = runHistoryRetentionPeriod.cutoffDate(relativeTo: Date())
        let taskID = UUID()
        let task = Task { @MainActor [weak self, historyRepository] in
            guard let self else { return }
            defer { self.finishHistoryProjectionLoadTask(id: taskID) }
            guard !Task.isCancelled,
                  !self.hasBegunApplicationShutdown,
                  self.historyLoadGeneration == generation else {
                return
            }
            do {
                let stored = try await historyRepository.records(
                    matching: HistoryQuery(since: since, limit: 50)
                ).map(HistoryRecordSanitizer.sanitize)
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.historyLoadGeneration == generation else {
                    return
                }
                self.historyRecords = stored
                self.historyLoadState = .loaded
                self.loadRunReceipts(
                    requiredRunIDs: Set(stored.compactMap(\.runID))
                )
                let retainedRunIDs = Set(stored.compactMap(\.runID))
                self.failedAudioRecoveryUnavailableReasonsByRunID =
                    self.failedAudioRecoveryUnavailableReasonsByRunID.filter {
                        retainedRunIDs.contains($0.key)
                    }
                if reconcileRunPresentation {
                    self.reconcileRunDerivedPresentation(with: stored)
                }
            } catch {
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.historyLoadGeneration == generation else {
                    return
                }
                if reconcileRunPresentation {
                    self.historyRecords.removeAll()
                    self.reconcileRunDerivedPresentation(with: [])
                }
                self.historyLoadState = .failed(.repositoryUnavailable)
                self.append(
                    english: "History repository is unavailable.",
                    simplifiedChinese: "历史记录仓库不可用。"
                )
            }
        }
        historyProjectionLoadTasks[taskID] = task
    }

    public func retryHistoryLoad() {
        loadHistory()
    }

    func loadRunReceipts(requiredRunIDs additionalRunIDs: Set<UUID> = []) {
        guard !hasBegunApplicationShutdown else { return }
        guard let runReceiptRepository else {
            workflowRunReceiptsByRunID.removeAll()
            return
        }
        runReceiptLoadGeneration += 1
        let generation = runReceiptLoadGeneration
        let since = runHistoryRetentionPeriod.cutoffDate(relativeTo: Date())
        let requiredRunIDs = additionalRunIDs.union(
            historyRecords.compactMap(\.runID)
        )
        let taskID = UUID()
        let task = Task { @MainActor [weak self, runReceiptRepository] in
            guard let self else { return }
            defer { self.finishHistoryProjectionLoadTask(id: taskID) }
            guard !Task.isCancelled,
                  !self.hasBegunApplicationShutdown,
                  self.runReceiptLoadGeneration == generation else {
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
                      self.runReceiptLoadGeneration == generation else {
                    return
                }
                self.workflowRunReceiptsByRunID = Dictionary(
                    receipts.map { ($0.runID, $0) },
                    uniquingKeysWith: { existing, _ in existing }
                )
            } catch {
                guard !Task.isCancelled,
                      !self.hasBegunApplicationShutdown,
                      self.runReceiptLoadGeneration == generation else {
                    return
                }
                self.append(
                    english: "Run receipt repository is unavailable.",
                    simplifiedChinese: "运行收据仓库不可用。"
                )
            }
        }
        historyProjectionLoadTasks[taskID] = task
    }

    func finishHistoryProjectionLoadTask(id: UUID) {
        historyProjectionLoadTasks.removeValue(forKey: id)
    }

    /// Waits until history, receipt, and diagnostic projections have reached
    /// a stable state. A completed history read may enqueue a receipt read, so
    /// the owner is checked again after every batch.
    func waitForHistoryProjectionLoads() async {
        while !historyProjectionLoadTasks.isEmpty {
            let tasks = Array(historyProjectionLoadTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    public func workflowRunReceipt(for runID: UUID?) -> WorkflowRunReceipt? {
        guard let runID else { return nil }
        return workflowRunReceiptsByRunID[runID]
    }

    private func reconcileRunDerivedPresentation(with records: [WorkflowResultRecord]) {
        lastCompletedText = records.first(where: { record in
            record.outcome == .completed &&
                !(record.finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        })?.finalText
        lastFailure = records.first(where: { $0.outcome == .failed })
            .map {
                RunFailurePresentation.text(
                    for: $0.failureMessage,
                    language: language
                )
            }
        pendingResolution = nil
        eventFeed.removeAll()
        pendingRuns.removeAll()
        currentCaptureLiveSubtitleSnapshot = nil
        workflowAudioCaptureRunID = nil
        liveSubtitleSnapshot = nil
        lastLiveSubtitleMeterRefreshAt = nil
        pendingLiveSubtitleHideTask?.cancel()
        pendingLiveSubtitleHideTask = nil
    }

    func isVoiceHistoryRecord(_ record: WorkflowResultRecord) -> Bool {
        let receiptTrigger = record.runID.flatMap {
            workflowRunReceiptsByRunID[$0]?.trigger
        }
        if let recordTrigger = record.trigger, let receiptTrigger {
            // Two durable authorities must agree. A corrupt or mismatched join
            // cannot gain permission to surface a body.
            guard recordTrigger == receiptTrigger else { return false }
            return recordTrigger.isVoiceCapture
        }
        return (record.trigger ?? receiptTrigger)?.isVoiceCapture == true
    }
}
