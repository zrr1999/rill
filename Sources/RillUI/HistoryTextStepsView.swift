import RillCore
import SwiftUI

struct HistoryTextStepsView: View {
  let steps: [WorkflowTextStep]
  let previewMode: PrivacyHistoryPreviewMode
  let language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1). \(HistoryTextStepPresentation.title(step.kind, language: language))")
              .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            Text(HistoryTextStepPresentation.status(step, language: language))
              .font(.caption)
              .foregroundStyle(step.result == .failed ? .red : .secondary)
          }
          if let milliseconds = step.durationMilliseconds {
            Text(HistoryTextStepPresentation.duration(milliseconds, language: language))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          if step.kind == .llmRewrite || step.kind == .llmAnswer {
            Text(HistoryTextStepPresentation.tokenUsage(step.tokenUsage, language: language))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let output = step.outputText {
            HistoryPreviewContent(text: output, mode: previewMode, language: language) { text, lineLimit in
              Text(text.isEmpty ? (L10n.catalogString("HistoryTextStepsView.Empty.result", language: language)) : text)
                .font(.callout)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.text-step.\(index)")
      }
    }
    .padding(.vertical, 8)
    .accessibilityIdentifier("history.text-steps")
  }

}

enum HistoryTextStepPresentation {
  static func duration(_ milliseconds: UInt64, language: AppLanguage) -> String {
    durationResource(milliseconds).string(for: language)
  }

  private static func durationResource(_ milliseconds: UInt64) -> LocalizedStringResource {
    L10n.resource("history.step.duration", defaultValue: "Processing time: \(L10n.historyProcessingDurationResource(milliseconds))")
  }

  static func tokenUsage(_ usage: LanguageModelTokenUsage?, language: AppLanguage) -> String {
    tokenUsageResource(usage).string(for: language)
  }

  private static func tokenUsageResource(_ usage: LanguageModelTokenUsage?) -> LocalizedStringResource {
    let missing = L10n.resource("history.step.tokens.missing")
    guard let usage else {
      return L10n.resource("history.step.tokens.unavailable", defaultValue: "Token usage: \(missing)")
    }
    func count(_ value: Int?) -> LocalizedStringResource {
      guard let value else { return missing }
      return L10n.resource("history.step.tokens.count", defaultValue: "\(String(value))")
    }
    return L10n.resource(
      "history.step.tokens.usage",
      defaultValue: "Tokens · Input \(count(usage.inputTokens)) · Output \(count(usage.outputTokens)) · Total \(count(usage.totalTokens))")
  }

  static func logHeader(_ step: WorkflowTextStep, language: AppLanguage) -> String {
    logHeaderResource(step).string(for: language)
  }

  static func logHeaderResource(_ step: WorkflowTextStep) -> LocalizedStringResource {
    var header = L10n.resource("history.step.header", defaultValue: "\(titleResource(step.kind)) · \(statusResource(step))\n")
    if let milliseconds = step.durationMilliseconds {
      header = L10n.resource("history.step.headerLine", defaultValue: "\(header)\(durationResource(milliseconds))\n")
    }
    if step.kind == .llmRewrite || step.kind == .llmAnswer {
      header = L10n.resource("history.step.headerLine", defaultValue: "\(header)\(tokenUsageResource(step.tokenUsage))\n")
    }
    return header
  }

  static func title(_ kind: WorkflowProcessStepKind, language: AppLanguage) -> String {
    titleResource(kind).string(for: language)
  }

  private static func titleResource(_ kind: WorkflowProcessStepKind) -> LocalizedStringResource {
    switch kind {
    case .recognizeSpeech: L10n.resource("history.step.title.recognizeSpeech")
    case .applyVocabulary: L10n.resource("history.step.title.applyVocabulary")
    case .llmRewrite: L10n.resource("history.step.title.llmRewrite")
    default: WorkflowStepPresentation.titleResource(kind)
    }
  }

  static func status(_ step: WorkflowTextStep, language: AppLanguage) -> String {
    statusResource(step).string(for: language)
  }

  private static func statusResource(_ step: WorkflowTextStep) -> LocalizedStringResource {
    switch step.result {
    case .completed:
      L10n.resource(step.didChange == false ? "history.step.status.unchanged" : "history.step.status.completed")
    case .skipped: L10n.resource("history.step.status.skipped")
    case .failed: L10n.resource("history.step.status.failed")
    case .cancelled: L10n.resource("history.step.status.cancelled")
    case .thenBranch: L10n.resource("history.step.status.thenBranch")
    case .elseBranch: L10n.resource("history.step.status.elseBranch")
    }
  }
}
