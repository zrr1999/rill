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
                            Text(text.isEmpty ? (language == .english ? "Empty result" : "结果为空") : text)
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
    static func tokenUsage(_ usage: LanguageModelTokenUsage?, language: AppLanguage) -> String {
        let chinese = language == .simplifiedChinese
        let missing = chinese ? "未提供" : "Not provided"
        guard let usage else { return chinese ? "Token 用量：\(missing)" : "Token usage: \(missing)" }
        let input = usage.inputTokens.map { String($0) } ?? missing
        let output = usage.outputTokens.map { String($0) } ?? missing
        let total = usage.totalTokens.map { String($0) } ?? missing
        return chinese
            ? "Tokens · 输入 \(input) · 输出 \(output) · 合计 \(total)"
            : "Tokens · Input \(input) · Output \(output) · Total \(total)"
    }

    static func logHeader(_ step: WorkflowTextStep, language: AppLanguage) -> String {
        var header = "\(title(step.kind, language: language)) · \(status(step, language: language))\n"
        if step.kind == .llmRewrite || step.kind == .llmAnswer {
            header += tokenUsage(step.tokenUsage, language: language) + "\n"
        }
        return header
    }

    static func title(_ kind: WorkflowProcessStepKind, language: AppLanguage) -> String {
        switch (kind, language) {
        case (.recognizeSpeech, .simplifiedChinese): "识别结果"
        case (.recognizeSpeech, .english): "Recognized text"
        case (.applyVocabulary, .simplifiedChinese): "词替换"
        case (.applyVocabulary, .english): "Vocabulary replacement"
        case (.llmRewrite, .simplifiedChinese): "文本润色"
        case (.llmRewrite, .english): "Text cleanup"
        default: WorkflowStepPresentation.stepTitle(kind, language: language)
        }
    }

    static func status(_ step: WorkflowTextStep, language: AppLanguage) -> String {
        let chinese = language == .simplifiedChinese
        switch step.result {
        case .completed:
            if step.didChange == false { return chinese ? "文本未变化" : "Text unchanged" }
            return chinese ? "已完成" : "Completed"
        case .skipped: return chinese ? "已跳过，保留原文" : "Skipped; text retained"
        case .failed: return chinese ? "失败" : "Failed"
        case .cancelled: return chinese ? "已取消" : "Cancelled"
        case .thenBranch: return chinese ? "满足条件" : "Condition matched"
        case .elseBranch: return chinese ? "不满足条件" : "Condition not matched"
        }
    }
}
