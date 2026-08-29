import Foundation
import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case permissions
    case speech
    case input
    case voiceAssistant
    case recordPanel
    case vocabulary
    case language
    case privacy
    case storage

    public var id: String { rawValue }

    public func title(language: AppLanguage) -> String {
        switch self {
        case .language:
            UIStrings.text(.settingsLanguage, language: language)
        case .recordPanel:
            UIStrings.text(.settingsRecordPanel, language: language)
        case .permissions:
            UIStrings.text(.permissions, language: language)
        case .privacy:
            L10n.privacyText(.title, language: language)
        case .storage:
            L10n.historySettingsText(.title, language: language)
        case .speech:
            UIStrings.text(.settingsSpeechEngine, language: language)
        case .vocabulary:
            L10n.string(.vocabularyTitle, language: language)
        case .input:
            UIStrings.text(.settingsBuiltinPushToTalk, language: language)
        case .voiceAssistant:
            language == .english ? "Voice Assistant" : "语音助手"
        }
    }

    public var symbolName: String {
        switch self {
        case .language: RillSystemSymbol.globe.rawValue
        case .recordPanel: RillSystemSymbol.docOnClipboard.rawValue
        case .permissions: RillSystemSymbol.lockShield.rawValue
        case .privacy: RillSystemSymbol.handRaised.rawValue
        case .storage: RillSystemSymbol.externaldrive.rawValue
        case .speech: RillSystemSymbol.waveformPathEcg.rawValue
        case .vocabulary: RillSystemSymbol.textBadgeCheckmark.rawValue
        case .input: RillSystemSymbol.micBadgePlus.rawValue
        case .voiceAssistant: RillSystemSymbol.waveformBadgeMic.rawValue
        }
    }

    var searchKeywords: String {
        switch self {
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
            "providers speech stt tts mlx qwen openai llm api key model local 提供商 语音 识别 合成 音色 模型 大模型 本地 密钥"
        case .vocabulary:
            "vocabulary hotword mapping replacement keyterm 词汇 热词 映射 替换"
        case .input:
            "push to talk fn toggle recording output input 按住说话 切换式录音 输出 输入"
        case .voiceAssistant:
            "voice assistant readiness wake word listener priority channel 语音助手 就绪 唤醒词 监听 优先级 通道"
        }
    }
}

struct SettingsNavigationRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let section: SettingsSection
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
