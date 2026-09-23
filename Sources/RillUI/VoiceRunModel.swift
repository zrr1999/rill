import Foundation
import Observation
import RillCore

@MainActor @Observable
public final class VoiceRunModel {
  public internal(set) var isRunning = false
  public internal(set) var lastCompletedText: String?
  var activeRunID: UUID?
  private(set) var runs: [UUID: RunSnapshot] = [:]

  func begin(_ run: RunSnapshot) {
    runs[run.runID] = run
    if run.lane == .primary || activeRunID == nil { activeRunID = run.runID }
    isRunning = true
  }

  func updateText(_ text: String, from identity: WorkflowRunIdentity) {
    guard activeRunID == identity.runID, runs[identity.runID]?.lane == identity.lane,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    lastCompletedText = text
  }

  func complete(_ summary: WorkflowRunSummary) {
    if summary.trigger.isVoiceCapture {
      updateText(summary.finalText, from: .init(runID: summary.runID, lane: summary.lane))
    }
    finish(summary.runID)
  }

  func finish(_ runID: UUID) {
    guard runs.removeValue(forKey: runID) != nil || activeRunID == runID else { return }
    if activeRunID == runID || activeRunID == nil {
      activeRunID =
        runs.values.sorted {
          if $0.lane != $1.lane { return $0.lane == .primary }
          return $0.startedAt > $1.startedAt
        }.first?.runID
    }
    isRunning = !runs.isEmpty
  }

  func reset() {
    runs.removeAll()
    activeRunID = nil
    isRunning = false
  }
}
