import Foundation
import RillCore

enum VoiceTextStyle: String, CaseIterable, Identifiable, Codable, Sendable, Equatable {
  case rawInput
  case cleanInput
  case smartCleanup
  case formalWriting
  case translateInput
  case commandMode
  case custom

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .rawInput:
      return RillSystemSymbol.textQuote.rawValue
    case .cleanInput:
      return RillSystemSymbol.textAlignLeft.rawValue
    case .formalWriting, .smartCleanup:
      return RillSystemSymbol.wandAndStars.rawValue
    case .translateInput:
      return RillSystemSymbol.globeAsiaAustralia.rawValue
    case .commandMode:
      return RillSystemSymbol.terminal.rawValue
    case .custom:
      return RillSystemSymbol.sliderHorizontal3.rawValue
    }
  }

  static func infer(from workflow: WorkflowDefinition) -> VoiceTextStyle {
    if let rawValue = workflow.properties.textStyle,
      let style = VoiceTextStyle(rawValue: rawValue)
    {
      return style
    }
    return infer(from: workflow.plan.process.allSteps.compactMap(\.postProcessStep))
  }

  static func infer(from steps: [PostProcessStep]) -> VoiceTextStyle {
    guard !steps.isEmpty else { return .rawInput }

    if steps.allSatisfy({ $0.kind == .normalizeWhitespace }) {
      return .cleanInput
    }

    let promptText =
      steps
      .compactMap(\.prompt)
      .joined(separator: " ")
      .lowercased()

    if steps.contains(where: { $0.prompt == LLMTextProcessing.cleanupPrompt }) {
      return .smartCleanup
    }
    if promptText.contains("translate") {
      return .translateInput
    }
    if promptText.contains("command") {
      return .commandMode
    }
    if promptText.contains("formal")
      || promptText.contains("polish")
      || promptText.contains("rewrite")
      || promptText.contains("concise final message")
    {
      return .formalWriting
    }

    return .custom
  }

  var workflowSteps: [PostProcessStep] {
    switch self {
    case .rawInput:
      return []
    case .cleanInput:
      return [PostProcessStep(kind: .normalizeWhitespace)]
    case .smartCleanup:
      var rewrite = PostProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt, reasoning: .some(.none), failurePolicy: .preserveInput)
      rewrite.preservesContent = true
      rewrite.decision = .init(optional: true)
      return [PostProcessStep(kind: .normalizeWhitespace), rewrite]
    case .formalWriting:
      return [
        PostProcessStep(kind: .normalizeWhitespace),
        PostProcessStep(kind: .llmRewrite, prompt: Self.formalWritingPrompt, reasoning: .some(.none)),
      ]
    case .translateInput:
      return [
        PostProcessStep(kind: .normalizeWhitespace),
        PostProcessStep(kind: .llmRewrite, prompt: Self.translatePrompt, reasoning: .some(.none)),
      ]
    case .commandMode:
      return [
        PostProcessStep(kind: .normalizeWhitespace),
        PostProcessStep(kind: .llmRewrite, prompt: Self.commandPrompt, reasoning: .some(.none)),
      ]
    case .custom:
      return [PostProcessStep(kind: .normalizeWhitespace)]
    }
  }

  var draftSteps: [WorkflowEditorDraft.PostProcessStepDraft] {
    workflowSteps.map { step in
      WorkflowEditorDraft.PostProcessStepDraft(
        id: step.id,
        kind: step.kind,
        prompt: step.prompt ?? ""
      )
    }
  }

  static let formalWritingPrompt = "Polish into a concise final message while preserving meaning and language."
  static let translatePrompt = "Translate the transcript into the target language requested by the user while preserving names, numbers, and formatting."
  static let commandPrompt = "Convert the transcript into a concise command or instruction while preserving the user's intent."
}

struct VoiceWorkflowPresentation: Equatable, Sendable {
  let textStyle: VoiceTextStyle
  let usesBuiltinTitle: Bool

  init(workflow: WorkflowDefinition) {
    textStyle = VoiceTextStyle.infer(from: workflow)
    usesBuiltinTitle = workflow.titleKey != nil
  }

  func menuTitle(workflowName: String, language: AppLanguage) -> String {
    let style = L10n.voiceTextStyleTitle(textStyle, language: language)
    guard !usesBuiltinTitle else { return style }
    guard style != workflowName else { return workflowName }
    return "\(style) — \(workflowName)"
  }

}

/// Duplicate workflow display names are legal (user TOML files are data, not
/// dirt). Naming rules in `saveWorkflowDraft` and the built-in shadowing in
/// `rebuildWorkflowLibrary` judge names on this same normalized string.
enum WorkflowNameDuplicationPolicy {
  static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

extension WorkflowEditorDraft {
  var textStyle: VoiceTextStyle {
    get {
      VoiceTextStyle.infer(from: postProcessSteps.map { $0.toStep() })
    }
    set {
      postProcessSteps = newValue.draftSteps
    }
  }
}
