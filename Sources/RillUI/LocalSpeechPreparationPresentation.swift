import Foundation

enum LocalSpeechPreparationPresentation {
  enum Stage: Equatable {
    case downloading(fractionCompleted: Double)
    case validating
    case loading

    var localizedKey: L10n.InterfaceKey {
      switch self {
      case .downloading:
        .localSpeechPreparing
      case .validating:
        .localSpeechValidating
      case .loading:
        .localSpeechFinalizing
      }
    }

    var downloadFraction: Double? {
      guard case .downloading(let fractionCompleted) = self else { return nil }
      return fractionCompleted
    }
  }

  static let validationThreshold = 0.9
  static let loadingThreshold = 0.95

  static func stage(displayedProgress: Double) -> Stage {
    let progress = min(max(displayedProgress, 0), 1)
    if progress >= loadingThreshold {
      return .loading
    }
    if progress >= validationThreshold {
      return .validating
    }
    return .downloading(fractionCompleted: progress / validationThreshold)
  }
}
