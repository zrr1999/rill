import RillCore
import SwiftUI

struct JevHotwordSettingsView: View {
  @Bindable var settings: JevAPISettingsModel
  let language: AppLanguage

  var body: some View {
    let chinese = language == .simplifiedChinese
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(chinese ? "Jev 热词挑选 · 实验" : "Jev hotword selection · Experimental")
        .font(.subheadline.weight(.medium))
      Text(chinese
        ? "启用后，会将候选热词、应用名称、工作流名称和已授权的文本选区发送到 api.typesafe.ai。选区超过 1,800 UTF-8 字节时整段省略。不会发送音频、剪贴板、屏幕或历史记录。"
        : "Enabling sends candidate hotwords, app and workflow names, and the authorized text selection to api.typesafe.ai. Selections over 1,800 UTF-8 bytes are omitted. Audio, clipboard, screen and history are never sent.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle(chinese ? "智能挑选热词" : "Select relevant hotwords", isOn: $settings.isHotwordSelectionEnabled)
        .disabled(!settings.isConfigured)
        .accessibilityIdentifier("settings.jev-hotwords.enabled")
      Text(chinese
        ? "开关和 Key 仅在本次 App 会话中保留。录音不会等待网络：新上下文首次使用原有规则，后台结果供后续相同上下文使用。仅影响最终识别，实时字幕不变。"
        : "The switch and key last only for this app session. Recording never waits for the network: new contexts use existing rules, with background results available to later matching recordings. Only final recognition is affected; live captions are unchanged.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
