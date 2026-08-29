import Foundation
import RillCore

enum VoiceTextStyle: String, CaseIterable, Identifiable, Codable, Sendable, Equatable {
    case rawInput
    case cleanInput
    case formalWriting
    case translateInput
    case commandMode
    case custom

    static let selectableCases: [VoiceTextStyle] = [
        .rawInput,
        .cleanInput,
        .formalWriting,
        .translateInput,
        .commandMode,
        .custom,
    ]

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .rawInput:
            return RillSystemSymbol.textQuote.rawValue
        case .cleanInput:
            return RillSystemSymbol.textAlignLeft.rawValue
        case .formalWriting:
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
        if let rawValue = workflow.metadata[WorkflowMetadataKey.textStyle],
           let style = VoiceTextStyle(rawValue: rawValue) {
            return style
        }
        return infer(from: workflow.plan.process.steps.compactMap(\.postProcessStep))
    }

    static func infer(from steps: [PostProcessStep]) -> VoiceTextStyle {
        guard !steps.isEmpty else { return .rawInput }

        if steps.allSatisfy({ $0.kind == .normalizeWhitespace }) {
            return .cleanInput
        }

        let promptText = steps
            .compactMap(\.prompt)
            .joined(separator: " ")
            .lowercased()

        if promptText.contains("translate") {
            return .translateInput
        }
        if promptText.contains("command") {
            return .commandMode
        }
        if promptText.contains("formal")
            || promptText.contains("polish")
            || promptText.contains("rewrite")
            || promptText.contains("concise final message") {
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
        case .formalWriting:
            return [
                PostProcessStep(kind: .normalizeWhitespace),
                PostProcessStep(kind: .llmRewrite, prompt: Self.formalWritingPrompt),
            ]
        case .translateInput:
            return [
                PostProcessStep(kind: .normalizeWhitespace),
                PostProcessStep(kind: .llmRewrite, prompt: Self.translatePrompt),
            ]
        case .commandMode:
            return [
                PostProcessStep(kind: .normalizeWhitespace),
                PostProcessStep(kind: .llmRewrite, prompt: Self.commandPrompt),
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
    let trigger: TriggerBinding
    let outputActionID: String?
    let recognizerID: String
    let languageOverride: String?
    let usesBuiltinTitle: Bool

    init(workflow: WorkflowDefinition) {
        textStyle = VoiceTextStyle.infer(from: workflow)
        trigger = workflow.trigger
        outputActionID = workflow.plan.output.actions.first?.id
        recognizerID = workflow.plan.setup.speechRoute?.recognizerID ?? ""
        languageOverride = workflow.metadata[WorkflowMetadataKey.languageOverride]
        usesBuiltinTitle = workflow.titleKey != nil
    }

    func detail(language: AppLanguage) -> String {
        let style = L10n.voiceTextStyleTitle(textStyle, language: language)
        let route = speechRouteTitle(language: language)
        let languageTitle = languageOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? languageOverride ?? ""
            : L10n.string(.workflowLanguageAuto, language: language)
        let triggerTitle = UIStrings.workflowTrigger(trigger, language: language)
        let output = outputActionID.map { UIStrings.actionName($0, language: language) }
            ?? L10n.string(.voiceModeOutputNone, language: language)
        let privacyLabel = L10n.privacyText(PrivacySettingsTextKey.routeDetailLabel, language: language)
        let privacy = privacyRouteHint(language: language)

        switch language {
        case .english:
            return "Mode: \(style) · Speech: \(route) · Language: \(languageTitle) · Trigger: \(triggerTitle) · Output: \(output) · \(privacyLabel): \(privacy)"
        case .simplifiedChinese:
            return "模式：\(style) · 识别：\(route) · 语言：\(languageTitle) · 触发：\(triggerTitle) · 输出：\(output) · \(privacyLabel)：\(privacy)"
        }
    }

    func menuTitle(workflowName: String, language: AppLanguage) -> String {
        let style = L10n.voiceTextStyleTitle(textStyle, language: language)
        guard !usesBuiltinTitle else { return style }
        guard style != workflowName else { return workflowName }
        return "\(style) — \(workflowName)"
    }

    private func speechRouteTitle(language: AppLanguage) -> String {
        if let route = WorkflowEditorDraft.RecognizerChoice(recognizerID: recognizerID) {
            return UIStrings.editorRecognizer(route, language: language)
        }
        return UIStrings.recognizerName(recognizerID, language: language)
    }

    func privacyRouteHint(language: AppLanguage) -> String {
        if let route = WorkflowEditorDraft.RecognizerChoice(recognizerID: recognizerID) {
            return L10n.privacySettingsSpeechRouteHint(route, language: language)
        }
        return L10n.privacySettingsSpeechRouteHint(.localSpeech, language: language)
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
