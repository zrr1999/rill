import Foundation
import RillCore

public extension AppModel {
  func setBenchmarkRecordingArchiveEnabled(_ isEnabled: Bool) {
    guard !hasBegunApplicationShutdown,
      !isLoadingSettings,
      isEnabled != benchmarkRecordingArchiveEnabled,
      !isUpdatingBenchmarkRecordingArchive
    else {
      return
    }
    guard let settingsStore else {
      benchmarkRecordingArchiveError = L10n.runText(
        .benchmarkStorageUnavailable,
        language: language
      )
      return
    }

    isUpdatingBenchmarkRecordingArchive = true
    benchmarkRecordingArchiveError = nil
    let refreshAction = refreshBenchmarkRecordingArchiveAction
    let task = Task { [weak self, settingsStore] in
      do {
        try await settingsStore.setString(
          isEnabled ? "true" : "false",
          forKey: .benchmarkRecordingArchiveEnabled
        )
        do {
          try await refreshAction(isEnabled)
        } catch {
          if isEnabled {
            try? await settingsStore.setString(
              "false",
              forKey: .benchmarkRecordingArchiveEnabled
            )
            try? await refreshAction(false)
          }
          throw error
        }
        await MainActor.run {
          self?.benchmarkRecordingArchiveEnabled = isEnabled
          self?.benchmarkRecordingArchiveError = nil
          self?.isUpdatingBenchmarkRecordingArchive = false
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.isUpdatingBenchmarkRecordingArchive = false
          self.benchmarkRecordingArchiveError = L10n.runText(
            .benchmarkRetentionUpdateFailed,
            language: self.language
          )
        }
      }
    }
    persistenceWrites.track(task)
  }

  func clearBenchmarkRecordingArchive() {
    guard !hasBegunApplicationShutdown,
      !isUpdatingBenchmarkRecordingArchive
    else {
      return
    }
    isUpdatingBenchmarkRecordingArchive = true
    benchmarkRecordingArchiveError = nil
    let clearAction = clearBenchmarkRecordingArchiveAction
    let task = Task { @MainActor [weak self, clearAction] in
      guard let self else { return }
      do {
        try await clearAction()
        self.benchmarkRecordingArchiveError = nil
      } catch {
        self.benchmarkRecordingArchiveError = L10n.runText(
          .benchmarkClearFailed,
          language: self.language
        )
      }
      self.isUpdatingBenchmarkRecordingArchive = false
    }
    persistenceWrites.track(task)
  }
}
