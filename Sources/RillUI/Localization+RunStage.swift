import Foundation
import RillCore

extension L10n {
  static func runStageTitle(_ stage: WorkflowRunStage, language: AppLanguage) -> String {
    let text: LocalizedStringResource =
      switch stage {
      case .preparing: L10n.resource("Localization.RunStage.Preparing")
      case .capturingInput: L10n.resource("Localization.RunStage.Recording")
      case .recognizing: L10n.resource("Localization.RunStage.Recognizing")
      case .resolving: L10n.resource("Localization.RunStage.Reviewing.candidates")
      case .transforming: L10n.resource("Localization.RunStage.Processing.text")
      case .saving: L10n.resource("Localization.RunStage.Saving")
      case .delivering: L10n.resource("Localization.RunStage.Sending.output")
      case .completed: L10n.resource("Localization.RunStage.Completed")
      case .failed: L10n.resource("Localization.RunStage.Needs.attention")
      }
    return text.string(for: language)
  }
  static func recoveryCopyTitle(original: Bool, language: AppLanguage) -> String {
    if original {
      return L10n.resource("Localization.RunStage.Copy.original.recognition").string(for: language)
    }
    return L10n.resource("Localization.RunStage.Copy.existing.text").string(for: language)
  }

  static func recoveryMessage(
    wasSaved: Bool, outputState: HistoryRecoveryPresentation.OutputState?, language: AppLanguage
  ) -> String? {

    switch (wasSaved, outputState) {
    case (true, .uncertain):
      return L10n.resource("Localization.RunStage.Text.saved.output.is.unconfirmed.Check.the.target.app.before.sending.again").string(for: language)
    case (false, .uncertain):
      return L10n.resource("Localization.RunStage.Output.is.unconfirmed.Check.the.target.app.before.sending.again").string(for: language)
    case (true, .failed):
      return L10n.resource("Localization.RunStage.Text.saved.output.failed.You.can.copy.the.existing.text").string(for: language)
    case (false, .failed):
      return L10n.resource("Localization.RunStage.Output.failed.You.can.copy.the.existing.text").string(for: language)
    case (true, nil):
      return L10n.resource("Localization.RunStage.Text.saved").string(for: language)
    case (false, nil): return nil
    }
  }
}
