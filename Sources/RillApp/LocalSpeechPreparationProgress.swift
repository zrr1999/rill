import Foundation
import RillProviders

extension AppBootstrap {
  nonisolated static let localSpeechValidationProgress = 0.9
  nonisolated static let localSpeechLoadingProgress = 0.95

  nonisolated static func localSpeechPreparationProgress(
    _ update: SpeechWorkerProgress
  ) -> Progress {
    let scale: Int64 = 10_000
    let displayedFraction =
      switch update.phase {
      case .downloading:
        update.fractionCompleted * localSpeechValidationProgress
      case .loading:
        localSpeechLoadingProgress
          + (update.fractionCompleted * (1 - localSpeechLoadingProgress))
      }
    let progress = Progress(totalUnitCount: scale)
    progress.completedUnitCount = Int64((displayedFraction * Double(scale)).rounded())
    return progress
  }
}
