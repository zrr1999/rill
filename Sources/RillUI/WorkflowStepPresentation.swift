import RillCore

enum WorkflowStepPresentation {
    static func stepTitle(_ kind: WorkflowProcessStepKind, language: AppLanguage) -> String {
        let title: LocalizedText =
            switch kind {
            case .recognizeSpeech: .init(english: "Recognize speech", simplifiedChinese: "识别语音")
            case .resolveUncertainty: .init(english: "Resolve uncertainty", simplifiedChinese: "消歧")
            case .applyVocabulary: .init(english: "Apply vocabulary", simplifiedChinese: "应用词库")
            case .snippetReplacement: .init(english: "Replace snippets", simplifiedChinese: "替换片段")
            case .llmRewrite: .init(english: "Rewrite", simplifiedChinese: "改写")
            case .llmAnswer: .init(english: "Answer", simplifiedChinese: "回答")
            case .normalizeWhitespace:
                .init(english: "Normalize whitespace", simplifiedChinese: "整理空白")
            case .conditional: .init(english: "If", simplifiedChinese: "条件分支")
            }
        return title.string(for: language)
    }
}
