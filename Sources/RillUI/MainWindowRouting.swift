import Foundation
import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
  case permissions
  case speech
  case decision
  case llm
  case tts
  case input
  case voiceAssistant
  case recordPanel
  case vocabulary
  case language
  case privacy
  case storage
  case contextMemory
  case diagnostics

  public var id: String { rawValue }

  public func title(language: AppLanguage) -> String {
    switch self {
    case .contextMemory:
      L10n.workspace(.contextMemory, language: language)
    case .diagnostics:
      L10n.text(.sidebarDiagnostics, language: language)
    case .language:
      L10n.text(.settingsLanguage, language: language)
    case .recordPanel:
      L10n.text(.settingsRecordPanel, language: language)
    case .permissions:
      L10n.text(.permissions, language: language)
    case .privacy:
      L10n.privacyText(.title, language: language)
    case .storage:
      L10n.historySettingsText(.title, language: language)
    case .decision:
      L10n.resource("models.service.decision").string(for: language)
    case .llm:
      L10n.resource("models.service.llm").string(for: language)
    case .tts:
      L10n.resource("models.service.tts").string(for: language)
    case .speech:
      L10n.text(.settingsSpeechEngine, language: language)
    case .vocabulary:
      L10n.string(.vocabularyTitle, language: language)
    case .input:
      L10n.text(.settingsBuiltinPushToTalk, language: language)
    case .voiceAssistant:
      L10n.overlayText(.settingsVoiceAssistantTitle, language: language)
    }
  }

  public var symbolName: String {
    switch self {
    case .contextMemory: RillSystemSymbol.textBadgeCheckmark.rawValue
    case .diagnostics: RillSystemSymbol.stethoscope.rawValue
    case .language: RillSystemSymbol.globe.rawValue
    case .recordPanel: RillSystemSymbol.docOnClipboard.rawValue
    case .permissions: RillSystemSymbol.lockShield.rawValue
    case .privacy: RillSystemSymbol.handRaised.rawValue
    case .storage: RillSystemSymbol.externaldrive.rawValue
    case .speech: RillSystemSymbol.waveformPathEcg.rawValue
    case .decision: RillSystemSymbol.globe.rawValue
    case .llm: RillSystemSymbol.sparkles.rawValue
    case .tts: RillSystemSymbol.speakerWave2.rawValue
    case .vocabulary: RillSystemSymbol.textBadgeCheckmark.rawValue
    case .input: RillSystemSymbol.micBadgePlus.rawValue
    case .voiceAssistant: RillSystemSymbol.waveformBadgeMic.rawValue
    }
  }

  // Hardcoded bilingual (English + Simplified Chinese) keyword lists. When
  // adding a new AppLanguage, extend every list with that language's terms
  // or the new locale will search worse than the existing ones.
  var searchKeywords: String {
    switch self {
    case .contextMemory:
      "context memory screen correction 上下文 记忆 屏幕 纠错"
    case .diagnostics:
      "diagnostics events logs 诊断 事件 日志"
    case .language:
      "language interface locale 语言 界面 中文 english"
    case .recordPanel:
      "clipboard capture history panel shortcut hotkey double command 剪贴板 剪切板 捕获 历史 面板 快捷键 双击 开启 关闭"
    case .permissions:
      "permissions microphone accessibility privacy system 权限 麦克风 辅助功能"
    case .privacy:
      "privacy sensitive apps secure input cloud confirmation preview 隐私 敏感 应用 云端 确认"
    case .storage:
      "storage retention history clear recovery data 保留 历史 清理 恢复 本地 数据"
    case .speech:
      "speech asr stt mlx qwen model local 语音 识别 模型 本地"
    case .decision:
      "decision classification scoring jev typesafe cloudflare clef api key token 分类 评分 密钥 排序 润色"
    case .llm:
      "providers openai deepseek llm api key 语言 大模型 提供商 密钥"
    case .tts:
      "tts speech synthesis qwen system voice local 语音 合成 音色 系统 本地"
    case .vocabulary:
      "vocabulary hotword mapping replacement keyterm 词汇 热词 映射 替换"
    case .input:
      "push to talk fn toggle recording output input 按住说话 切换式录音 输出 输入"
    case .voiceAssistant:
      "voice assistant readiness wake word listener priority channel 语音助手 就绪 唤醒词 监听 优先级 通道"
    }
  }
}

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
  case general, input, models, vocabulary, privacy, data
  public var id: String { rawValue }
  var sections: [SettingsSection] {
    switch self {
    case .general: [.language]
    case .input: [.input, .voiceAssistant, .recordPanel]
    case .models: [.speech, .decision, .llm, .tts]
    case .vocabulary: [.vocabulary, .contextMemory]
    case .privacy: [.permissions, .privacy]
    case .data: [.storage, .diagnostics]
    }
  }
  func title(language: AppLanguage) -> String {
    switch self {
    case .models: L10n.workspace(.modelServices, language: language)
    case .general: L10n.workspace(.general, language: language)
    case .input: L10n.workspace(.input, language: language)
    case .vocabulary: L10n.workspace(.vocabularyMemory, language: language)
    case .privacy: L10n.workspace(.privacy, language: language)
    case .data: L10n.workspace(.data, language: language)
    }
  }
  var symbolName: String { sections[0].symbolName }
}

extension SettingsSection {
  var pane: SettingsPane {
    switch self {
    case .language: .general
    case .input, .recordPanel, .voiceAssistant: .input
    case .speech, .decision, .llm, .tts: .models
    case .vocabulary, .contextMemory: .vocabulary
    case .permissions, .privacy: .privacy
    case .storage, .diagnostics: .data
    }
  }
}

public enum SettingsItem: String, CaseIterable, Hashable, Sendable {
  case jevCredential, jevPolishing
  public var section: SettingsSection { .decision }
  var title: JevText { self == .jevCredential ? .credentialTitle : .polishingTitle }
  var searchKeywords: String {
    switch self {
    case .jevCredential: "jev typesafe api key credential 密钥 凭据 排序"
    case .jevPolishing: "jev typesafe polishing prediction 润色 判断 智能整理"
    }
  }
}

public struct SettingsNavigationRequest: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let section: SettingsSection
  public let item: SettingsItem?

  public init(section: SettingsSection, item: SettingsItem? = nil) {
    self.section = item?.section ?? section
    self.item = item
  }
}

struct HistoryNavigationRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  let entryID: UUID
  let scope: RunHistoryScope
}

struct WorkflowEditorNavigationRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  let workflowID: UUID
}

public struct GlobalSearchPresentationAction {
  private let action: @MainActor () -> Void

  public init(_ action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  @MainActor
  public func callAsFunction() {
    action()
  }
}

private struct GlobalSearchPresentationActionKey: FocusedValueKey {
  typealias Value = GlobalSearchPresentationAction
}

public extension FocusedValues {
  var rillGlobalSearchPresentationAction: GlobalSearchPresentationAction? {
    get { self[GlobalSearchPresentationActionKey.self] }
    set { self[GlobalSearchPresentationActionKey.self] = newValue }
  }
}

public struct RillGlobalSearchCommands: Commands {
  @FocusedValue(\.rillGlobalSearchPresentationAction)
  private var presentationAction

  private let language: AppLanguage

  public init(language: AppLanguage) {
    self.language = language
  }

  public var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button(GlobalSearchText.searchCommand(language: language)) {
        presentationAction?()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(presentationAction == nil)
    }
  }
}
