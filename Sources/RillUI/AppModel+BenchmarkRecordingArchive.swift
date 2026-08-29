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
      benchmarkRecordingArchiveError = benchmarkArchiveMessage(
        english: "Encrypted benchmark recording storage is unavailable because persistent settings storage is unavailable.",
        simplifiedChinese: "持久化设置存储不可用，因此无法使用加密的 Benchmark 录音归档。"
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
          self.benchmarkRecordingArchiveError = self.benchmarkArchiveMessage(
            english: "Benchmark recording retention could not be updated.",
            simplifiedChinese: "无法更新 Benchmark 录音保留设置。"
          )
        }
      }
    }
    registerPersistenceWrite(task)
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
        self.benchmarkRecordingArchiveError = self.benchmarkArchiveMessage(
          english: "Encrypted benchmark recordings could not be cleared.",
          simplifiedChinese: "无法清除加密的 Benchmark 录音。"
        )
      }
      self.isUpdatingBenchmarkRecordingArchive = false
    }
    registerPersistenceWrite(task)
  }

  private func benchmarkArchiveMessage(
    english: String,
    simplifiedChinese: String
  ) -> String {
    language == .english ? english : simplifiedChinese
  }
}
