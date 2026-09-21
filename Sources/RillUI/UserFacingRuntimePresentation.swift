import Foundation
import RillCore

enum RunFailurePresentation {
  static func localizedText(for untrustedMessage: String?) -> LocalizedText {
    let safeMessage = HistoryFailureSanitizer.sanitize(untrustedMessage)
      ?? HistoryFailureSanitizer.genericMessage
    let simplifiedChinese: String
    switch safeMessage {
    case "Microphone access is required. Grant access in System Settings and retry.":
      simplifiedChinese = "需要麦克风权限。请在系统设置中授权后重试。"
    case "Accessibility access is required for direct text insertion. Grant access and retry.":
      simplifiedChinese = "直接输入文本需要辅助功能权限。请授权后重试。"
    case "The run was blocked by the current privacy policy. Review Privacy settings and retry.":
      simplifiedChinese = "当前隐私策略阻止了本次运行。请检查隐私设置后重试。"
    case HistoryFailureSanitizer.noSpeechMessage:
      simplifiedChinese = "未检测到语音。请重试。"
    case HistoryFailureSanitizer.globalInputUnavailableMessage:
      simplifiedChinese = "全局键盘输入不可用，语音录制已停止。"
    case HistoryFailureSanitizer.recognitionTimeoutMessage:
      simplifiedChinese = "语音识别耗时过长，本次运行已停止。请重试。"
    case HistoryFailureSanitizer.recognitionRecoveryPendingMessage:
      simplifiedChinese = "上次识别操作仍在结束中。请稍候，或切换识别引擎。"
    default:
      simplifiedChinese = "工作流失败。请在诊断中查看安全摘要后重试。"
    }
    return LocalizedText(
      english: safeMessage,
      simplifiedChinese: simplifiedChinese
    )
  }

  static func historyText(for message: String?, language: AppLanguage) -> String {
    if HistoryFailureSanitizer.sanitize(message) == HistoryFailureSanitizer.genericMessage {
      return language == .english
        ? "Processing did not complete. Expand execution details to see why."
        : "本次处理未完成。展开执行详情查看原因。"
    }
    return text(for: message, language: language)
  }

  static func text(
    for untrustedMessage: String?,
    language: AppLanguage
  ) -> String {
    localizedText(for: untrustedMessage).string(for: language)
  }
}

enum DiagnosticsTimelineFilter: String, CaseIterable, Identifiable, Sendable {
  case activity
  case issues
  case all

  var id: String { rawValue }

  func title(language: AppLanguage) -> String {
    switch (language, self) {
    case (.english, .activity): "Activity"
    case (.simplifiedChinese, .activity): "活动"
    case (.english, .issues): "Issues"
    case (.simplifiedChinese, .issues): "问题"
    case (.english, .all): "All Details"
    case (.simplifiedChinese, .all): "全部详情"
    }
  }

  func includes(_ event: DiagnosticEvent) -> Bool {
    switch self {
    case .activity:
      event.level != .debug
    case .issues:
      event.level == .warning || event.level == .error
    case .all:
      true
    }
  }
}

enum DiagnosticEventPresentation {
  private static let genericMessage = "Diagnostic event recorded."

  static func title(
    for event: DiagnosticEvent,
    language: AppLanguage
  ) -> String {
    if let known = knownTitle(for: event, language: language) {
      return known
    }
    if event.message != genericMessage {
      return language == .english
        ? event.message
        : localizedFallbackTitle(for: event, language: language)
    }
    return localizedFallbackTitle(for: event, language: language)
  }

  static func detail(for event: DiagnosticEvent) -> String {
    let metadata = event.metadata
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " · ")
    return metadata.isEmpty ? event.event : "\(event.event) · \(metadata)"
  }

  private static func knownTitle(
    for event: DiagnosticEvent,
    language: AppLanguage
  ) -> String? {
    switch event.event {
    case "global-input.installed":
      return localized("Global input is ready", "全局输入已就绪", language: language)
    case "global-input.unavailable":
      return localized("Global input is unavailable", "全局输入不可用", language: language)
    case "history.maintenance.completed":
      return localized("History cleanup completed", "历史清理已完成", language: language)
    case "clipboard.capture.paused":
      return localized("Clipboard capture is paused", "剪贴板捕获已暂停", language: language)
    case "clipboard.capture.resumed":
      return localized("Clipboard capture is active", "剪贴板捕获已开启", language: language)
    case "temporary-files.cleanup.completed":
      return localized("Temporary recordings cleaned up", "临时录音已清理", language: language)
    case "security.webhook-configuration.protected":
      return localized(
        "Webhook credentials are protected",
        "Webhook 凭据已受保护",
        language: language
      )
    case "provider.local-speech.available", "provider.sherpa-onnx.available":
      return localized(
        "On-device speech support is available",
        "本机语音能力已可用",
        language: language
      )
    case "workflow-manifest.loaded":
      return localized("Workflow catalog loaded", "工作流目录已载入", language: language)
    case "persistence.sqlite.ready":
      return localized("Local storage is ready", "本地存储已就绪", language: language)
    case "workflow.audio-recording.started":
      return localized("Recording started", "已开始录音", language: language)
    case "workflow.audio-recording.queued":
      return localized(
        "Recording queued for on-device transcription",
        "录音已进入本机转写队列",
        language: language
      )
    case "workflow.audio-recording.terminal-signal":
      return localized("Recording finished", "录音已结束", language: language)
    case "recording.started":
      return localized("Recording started", "已开始录音", language: language)
    case "recording.hotkey.pressed":
      return localized("Push-to-talk pressed", "已按下按住说话键", language: language)
    case "recording.hotkey.released":
      return localized("Push-to-talk released", "已松开按住说话键", language: language)
    case "recording.finishing":
      return localized("Finishing recording", "正在结束录音", language: language)
    case "recording.queued":
      return localized(
        "Recording queued for transcription",
        "录音已进入转写队列",
        language: language
      )
    case "audio-processing.enqueued":
      return localized("Audio queued for processing", "音频已进入处理队列", language: language)
    case "audio-processing.started":
      return localized("Audio processing started", "已开始处理音频", language: language)
    case "audio-processing.temporary-file-removed":
      return localized("Temporary recording removed", "临时录音已清理", language: language)
    case "session.transform.step":
      return localized("Text cleanup applied", "已完成文本整理", language: language)
    case "session.action":
      return localized("Output action completed", "输出动作已完成", language: language)
    case "clipboard.inject.text.prepare":
      return localized("Preparing text insertion", "正在准备输入文本", language: language)
    case "clipboard.inject.paste.begin":
      return localized("Text insertion started", "已开始输入文本", language: language)
    case "clipboard.inject.paste.end":
      return localized("Text insertion finished", "文本输入已完成", language: language)
    case "clipboard.inject.restore":
      return localized("Clipboard restored", "剪贴板已恢复", language: language)
    case "session.stage":
      return sessionStageTitle(
        event.metadata["stage"],
        language: language
      )
    default:
      return nil
    }
  }

  private static func sessionStageTitle(
    _ stage: String?,
    language: AppLanguage
  ) -> String? {
    switch stage {
    case "preparing":
      return localized("Preparing workflow", "正在准备工作流", language: language)
    case "recognizing":
      return localized("Recognizing speech on device", "正在本机识别语音", language: language)
    case "transforming":
      return localized("Formatting transcription", "正在整理转写文本", language: language)
    case "delivering":
      return localized("Delivering text", "正在投递文本", language: language)
    case "completed":
      return localized("Workflow completed", "工作流已完成", language: language)
    default:
      return nil
    }
  }

  private static func localizedFallbackTitle(
    for event: DiagnosticEvent,
    language: AppLanguage
  ) -> String {
    let subsystem = UIStrings.subsystem(event.subsystem, language: language)
    return language == .english
      ? "\(subsystem) event: \(event.event)"
      : "\(subsystem)事件：\(event.event)"
  }

  private static func localized(
    _ english: String,
    _ simplifiedChinese: String,
    language: AppLanguage
  ) -> String {
    language == .english ? english : simplifiedChinese
  }
}
