import AppKit
import SwiftUI

struct InputMethodSettingsView: View {
  @Bindable var input: InputMethodFeatureModel

  private func applicationName(_ identifier: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension()
      .lastPathComponent ?? identifier
  }

  var body: some View {
    Section("输入法") {
      Text("自带轻量全拼词库，独立保存配置与个人词库。安装后，在系统输入法设置中添加 Rill。")
        .font(.caption).foregroundStyle(.secondary)
      Button(input.isInstalling ? "正在安装…" : "安装 Rill 输入法") {
        Task { await input.installInputMethod() }
      }.disabled(input.isInstalling)
      Button("从鼠须管导入并安装…") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Rime")
        panel.message = "先切换到 ABC 并退出鼠须管，再选择 Rime 配置目录。原目录会保留。"
        if panel.runModal() == .OK, let url = panel.url {
          Task { await input.installInputMethod(importing: url) }
        }
      }.disabled(input.isInstalling)
      Text("首次安装时可选择一次性导入已有方案和完整个人词库。导入后使用独立副本，原目录保留。")
        .font(.caption).foregroundStyle(.secondary)
      if let status = input.status { Text(status).font(.caption) }
      Button("打开系统输入法设置") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        {
          NSWorkspace.shared.open(url)
        }
      }
      Toggle(
        "从打字生成词汇建议", isOn: Binding(get: { input.state.enabled }, set: { input.setEnabled($0) })
      )
      .disabled(!input.isReady)
      Text("仅采集下方选定的应用。在本机提取词汇，确认后才供语音识别使用；未确认建议保留 30 天。")
        .font(.caption).foregroundStyle(.secondary)
      Button("选择允许学习的应用…") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
          for url in panel.urls {
            if let identifier = Bundle(url: url)?.bundleIdentifier {
              input.setApplication(identifier, allowed: true)
            }
          }
        }
      }.disabled(!input.isReady)
      ForEach(input.state.allowedApplications.sorted(), id: \.self) { app in
        HStack {
          Text(applicationName(app))
          Spacer()
          Button("移除") { input.setApplication(app, allowed: false) }
        }
      }
      ForEach(
        input.state.suggestions.filter { $0.status != .ignored }.sorted { $0.count > $1.count }
      ) { suggestion in
        HStack {
          VStack(alignment: .leading) {
            Text(suggestion.phrase)
            Text(
              "\(suggestion.count) 次 · \(suggestion.applications.sorted().map(applicationName).joined(separator: ", "))"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if suggestion.status == .pending {
            Button("确认") { Task { await input.confirm(suggestion) } }
            Button("忽略") { Task { await input.ignore(suggestion.id) } }
          } else {
            Text("已确认").foregroundStyle(.secondary)
          }
          Button(suggestion.ownsConfirmedRule ? "撤销词汇" : "删除建议") {
            Task { await input.remove(suggestion) }
          }
        }
      }
      Button("清空未确认建议") { Task { await input.clearPending() } }.disabled(!input.isReady)
      if let error = input.error { Text(error).foregroundStyle(.red).font(.caption) }
    }
  }
}
