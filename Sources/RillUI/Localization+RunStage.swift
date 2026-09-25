import RillCore

extension L10n {
  static func runStageTitle(_ stage: WorkflowRunStage, language: AppLanguage) -> String {
    let text: LocalizedText =
      switch stage {
      case .preparing: .init(english: "Preparing", simplifiedChinese: "准备中")
      case .capturingInput: .init(english: "Recording", simplifiedChinese: "录音中")
      case .recognizing: .init(english: "Recognizing", simplifiedChinese: "识别中")
      case .resolving: .init(english: "Reviewing candidates", simplifiedChinese: "等待确认候选词")
      case .transforming: .init(english: "Processing text", simplifiedChinese: "处理文本中")
      case .saving: .init(english: "Saving", simplifiedChinese: "保存中")
      case .delivering: .init(english: "Sending output", simplifiedChinese: "输出中")
      case .completed: .init(english: "Completed", simplifiedChinese: "已完成")
      case .failed: .init(english: "Needs attention", simplifiedChinese: "需要处理")
      }
    return text.string(for: language)
  }
  static func recoveryCopyTitle(original: Bool, language: AppLanguage) -> String {
    if original {
      return language == .simplifiedChinese ? "复制原始识别" : "Copy original recognition"
    }
    return language == .simplifiedChinese ? "复制已有文本" : "Copy existing text"
  }

  static func recoveryMessage(
    wasSaved: Bool, outputState: HistoryRecoveryPresentation.OutputState?, language: AppLanguage
  ) -> String? {
    let chinese = language == .simplifiedChinese
    switch (wasSaved, outputState) {
    case (true, .uncertain):
      return chinese
        ? "文本已保存，输出结果未确认。请先检查目标应用，避免重复发送。"
        : "Text saved; output is unconfirmed. Check the target app before sending again."
    case (false, .uncertain):
      return chinese
        ? "输出结果未确认。请先检查目标应用，避免重复发送。"
        : "Output is unconfirmed. Check the target app before sending again."
    case (true, .failed):
      return chinese
        ? "文本已保存，输出失败。可以复制已有文本。" : "Text saved; output failed. You can copy the existing text."
    case (false, .failed):
      return chinese ? "输出失败，可以复制已有文本。" : "Output failed. You can copy the existing text."
    case (true, nil):
      return chinese ? "文本已保存" : "Text saved"
    case (false, nil): return nil
    }
  }
}
