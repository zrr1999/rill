import Foundation

public enum ContextMemoryFailure: Sendable, Equatable {
  case settingsLoad, revocation, authorization, storage, mutation, correction, unavailable
}

public enum ContextMemoryMutationResult: Sendable, Equatable {
  case saved
  case failed(ContextMemoryFailure)
  case stopped
}

extension L10n {
  static func contextMemoryFailure(_ failure: ContextMemoryFailure) -> LocalizedText {
    switch failure {
    case .settingsLoad:
      LocalizedText(
        english: "Context settings could not be loaded.", simplifiedChinese: "上下文设置读取失败。")
    case .revocation:
      LocalizedText(
        english: "Authorization revocation could not be saved.", simplifiedChinese: "撤权设置保存失败。")
    case .authorization:
      LocalizedText(
        english: "Context settings could not be saved or authorized.",
        simplifiedChinese: "上下文设置保存或授权失败。")
    case .storage:
      LocalizedText(english: "Memory storage is unavailable.", simplifiedChinese: "记忆存储不可用。")
    case .mutation:
      LocalizedText(
        english: "Memory could not be changed. Your draft is retained; refresh and retry.",
        simplifiedChinese: "记忆修改失败，草稿已保留；请刷新后重试。")
    case .correction:
      LocalizedText(
        english: "Correction could not be linked to history.", simplifiedChinese: "无法将纠正关联到历史。")
    case .unavailable:
      LocalizedText(
        english: "Memory editing is unavailable while Rill is shutting down.",
        simplifiedChinese: "Rill 正在退出，暂时无法编辑记忆。")
    }
  }
}
