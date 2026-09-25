import Foundation
import RillCore

extension VoiceRunModel {
  func applyCurrentCaptureLiveSubtitleSnapshot(_ newValue: LiveSubtitleSnapshot?) {
    let oldValue = currentCaptureLiveSubtitleSnapshot
    currentCaptureLiveSubtitleSnapshot = newValue
    guard
      hasLiveSubtitleSemanticChange(
        from: oldValue,
        to: currentCaptureLiveSubtitleSnapshot
      )
    else { return }
    cancelPendingLiveSubtitleMeterRefresh()
  }

  func hasLiveSubtitleSemanticChange(
    from current: LiveSubtitleSnapshot?,
    to snapshot: LiveSubtitleSnapshot?
  ) -> Bool {
    guard let current, let snapshot else {
      return current != nil || snapshot != nil
    }
    return current.runID != snapshot.runID || current.workflow != snapshot.workflow
      || current.phase != snapshot.phase || current.confirmedText != snapshot.confirmedText
      || current.hypothesisText != snapshot.hypothesisText
      || current.statusText != snapshot.statusText || current.providerID != snapshot.providerID
      || current.networkUsage != snapshot.networkUsage
      || current.livePreviewPlacement != snapshot.livePreviewPlacement
      || current.queuedRunCount != snapshot.queuedRunCount
      || current.prefersCompactLayout != snapshot.prefersCompactLayout
  }

  func shouldUpdateLiveSubtitleSnapshot(_ snapshot: LiveSubtitleSnapshot) -> Bool {
    guard let current = currentCaptureLiveSubtitleSnapshot else { return true }
    if hasLiveSubtitleSemanticChange(from: current, to: snapshot) {
      lastLiveSubtitleMeterRefreshAt = ContinuousClock.now
      return true
    }
    guard current.levelMeter != snapshot.levelMeter else {
      cancelPendingLiveSubtitleMeterRefresh()
      return false
    }
    let now = ContinuousClock.now
    if let lastLiveSubtitleMeterRefreshAt,
      now - lastLiveSubtitleMeterRefreshAt < liveSubtitleMeterRefreshInterval
    {
      let elapsed = now - lastLiveSubtitleMeterRefreshAt
      scheduleLiveSubtitleMeterRefresh(
        snapshot,
        after: liveSubtitleMeterRefreshInterval - elapsed
      )
      return false
    }
    cancelPendingLiveSubtitleMeterRefresh()
    lastLiveSubtitleMeterRefreshAt = now
    return true
  }

  func scheduleLiveSubtitleMeterRefresh(
    _ snapshot: LiveSubtitleSnapshot,
    after delay: Duration
  ) {
    guard !settings.hasBegunApplicationShutdown else { return }
    if pendingLiveSubtitleMeterSnapshot?.runID == snapshot.runID,
      pendingLiveSubtitleMeterRefreshTask != nil
    {
      pendingLiveSubtitleMeterSnapshot = snapshot
      return
    }

    cancelPendingLiveSubtitleMeterRefresh()
    liveSubtitleMeterRefreshGeneration &+= 1
    let generation = liveSubtitleMeterRefreshGeneration
    let runID = snapshot.runID
    let wait = waitForLiveSubtitleMeterRefresh
    pendingLiveSubtitleMeterSnapshot = snapshot
    pendingLiveSubtitleMeterRefreshTask = Task { @MainActor [weak self, wait] in
      do {
        try await wait(delay)
      } catch {
        self?.discardPendingLiveSubtitleMeterRefresh(generation: generation)
        return
      }
      guard !Task.isCancelled else { return }
      self?.applyPendingLiveSubtitleMeterRefresh(runID: runID, generation: generation)
    }
  }

  func applyPendingLiveSubtitleMeterRefresh(runID: UUID, generation: Int) {
    guard generation == liveSubtitleMeterRefreshGeneration else { return }
    pendingLiveSubtitleMeterRefreshTask = nil
    guard
      !settings.hasBegunApplicationShutdown,
      let pendingSnapshot = pendingLiveSubtitleMeterSnapshot,
      pendingSnapshot.runID == runID,
      let currentSnapshot = currentCaptureLiveSubtitleSnapshot,
      currentSnapshot.runID == runID,
      !hasLiveSubtitleSemanticChange(from: currentSnapshot, to: pendingSnapshot)
    else {
      pendingLiveSubtitleMeterSnapshot = nil
      return
    }

    pendingLiveSubtitleMeterSnapshot = nil
    lastLiveSubtitleMeterRefreshAt = ContinuousClock.now
    applyCurrentCaptureLiveSubtitleSnapshot(pendingSnapshot)
    refreshLiveSubtitlePresentation()
  }

  func discardPendingLiveSubtitleMeterRefresh(generation: Int) {
    guard generation == liveSubtitleMeterRefreshGeneration else { return }
    pendingLiveSubtitleMeterRefreshTask = nil
    pendingLiveSubtitleMeterSnapshot = nil
  }

  func cancelPendingLiveSubtitleMeterRefresh() {
    guard
      pendingLiveSubtitleMeterRefreshTask != nil || pendingLiveSubtitleMeterSnapshot != nil
    else { return }
    liveSubtitleMeterRefreshGeneration &+= 1
    pendingLiveSubtitleMeterRefreshTask?.cancel()
    pendingLiveSubtitleMeterRefreshTask = nil
    pendingLiveSubtitleMeterSnapshot = nil
  }

  func applyLiveSubtitleUpdate(_ snapshot: LiveSubtitleSnapshot) {
    guard !settings.hasBegunApplicationShutdown else { return }
    let currentLiveRunID = currentCaptureLiveSubtitleSnapshot?.runID
    if snapshot.isVisible || currentLiveRunID == nil || currentLiveRunID == snapshot.runID {
      cancelLiveSubtitleHide()
    }
    if snapshot.isVisible {
      if workflowAudioCaptureRunID == nil, workflowAudioRunState != .idle {
        workflowAudioCaptureRunID = snapshot.runID
      }
      if shouldUpdateLiveSubtitleSnapshot(snapshot) {
        applyCurrentCaptureLiveSubtitleSnapshot(snapshot)
        refreshLiveSubtitlePresentation()
        if snapshot.phase == .failed {
          scheduleLiveSubtitleHide()
        } else if snapshot.phase == .preparing {
          scheduleLiveSubtitleHide(after: liveSubtitlePreparingHideDelay)
        }
      }
    } else if currentCaptureLiveSubtitleSnapshot?.runID == snapshot.runID {
      if case .recording(let workflowID) = workflowAudioRunState {
        workflowAudioRunState = .transcribing(workflowID: workflowID)
      }
      applyCurrentCaptureLiveSubtitleSnapshot(nil)
      lastLiveSubtitleMeterRefreshAt = nil
      refreshLiveSubtitlePresentation()
    }
  }

  func refreshLiveSubtitlePresentation() {
    guard !settings.hasBegunApplicationShutdown else {
      setLiveSubtitlePresentation(nil)
      return
    }
    if var captureSnapshot = currentCaptureLiveSubtitleSnapshot, captureSnapshot.isVisible {
      captureSnapshot.queuedRunCount = queuedBackgroundRunCount(from: audioProcessingQueueSnapshot)
      setLiveSubtitlePresentation(captureSnapshot)
      return
    }
    // The floating surface belongs only to live capture. Background
    // recognition and output remain observable in the menu bar/history, but
    // never open a second panel that can fight with the next recording.
    setLiveSubtitlePresentation(nil)
  }

  func setLiveSubtitlePresentation(_ snapshot: LiveSubtitleSnapshot?) {
    liveSubtitleSnapshot = snapshot
    syncLiveSubtitlePanel()
  }

  func syncLiveSubtitlePanel() {
    updateLiveSubtitlePanelAction?(liveSubtitleSnapshot, self.settings.language)
  }

  func queuedBackgroundRunCount(from snapshot: AudioProcessingQueueSnapshot?) -> Int {
    snapshot?.pendingCount ?? 0
  }

}

extension VoiceRunModel {
  func scheduleLiveSubtitleHide(after delay: Duration = .seconds(1)) {
    guard !settings.hasBegunApplicationShutdown,
      let runID = currentCaptureLiveSubtitleSnapshot?.runID
    else { return }
    cancelLiveSubtitleHide()
    let wait = waitForLiveSubtitleHide
    pendingLiveSubtitleHideTask = Task { @MainActor [weak self, wait] in
      do { try await wait(delay) } catch { return }
      guard let self, !Task.isCancelled, !settings.hasBegunApplicationShutdown,
        currentCaptureLiveSubtitleSnapshot?.runID == runID
      else { return }
      pendingLiveSubtitleHideTask = nil
      applyCurrentCaptureLiveSubtitleSnapshot(nil)
      lastLiveSubtitleMeterRefreshAt = nil
      refreshLiveSubtitlePresentation()
    }
  }

  func cancelLiveSubtitleHide() {
    pendingLiveSubtitleHideTask?.cancel()
    pendingLiveSubtitleHideTask = nil
  }

  func stopPresentationForApplicationShutdown() {
    cancelPendingLiveSubtitleMeterRefresh()
    cancelLiveSubtitleHide()
    applyCurrentCaptureLiveSubtitleSnapshot(nil)
    lastLiveSubtitleMeterRefreshAt = nil
    setLiveSubtitlePresentation(nil)
  }
}
