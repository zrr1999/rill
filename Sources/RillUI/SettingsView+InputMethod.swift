import AppKit
import Carbon
import RillCore
import SwiftUI

struct InputMethodSettingsView: View {
  @Bindable var input: InputMethodFeatureModel
  var language: AppLanguage

  private func applicationName(_ identifier: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.deletingPathExtension()
      .lastPathComponent ?? identifier
  }

  var body: some View {
    Section("输入法") {
      Text(L10n.inputMethod(.description, language: language))
        .font(.caption).foregroundStyle(.secondary)
      Text(L10n.inputMethodState(input.installationState, language: language))
        .accessibilityIdentifier("input-method-installation-state")
      Button(
        L10n.inputMethod(
          input.isInstalling
            ? .installing : (input.installationState == .notInstalled ? .install : .repair),
          language: language)
      ) {
        Task { await input.installInputMethod() }
      }.disabled(input.isInstalling)
      if input.installationState == .notInstalled {
        Button(L10n.inputMethod(.importProfile, language: language)) {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
              "Library/Rime")
          panel.message = L10n.inputMethod(.importPanel, language: language)
          if panel.runModal() == .OK, let url = panel.url {
            Task { await input.installInputMethod(importing: url) }
          }
        }.disabled(input.isInstalling)
        Text(L10n.inputMethod(.importNotice, language: language))
          .font(.caption).foregroundStyle(.secondary)
      }
      if input.installationState == .registered || input.installationState == .registrationPending {
        Text(L10n.inputMethod(.activationHelp, language: language))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let status = input.status { Text(status).font(.caption) }
      if let error = input.error { Text(error).foregroundStyle(.red).font(.caption) }
      Button(L10n.inputMethod(.openSettings, language: language)) {
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
    }
    .onAppear { input.refreshInstallationState() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      input.refreshInstallationState()
    }
    .onReceive(
      DistributedNotificationCenter.default().publisher(
        for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String))
    ) { _ in input.refreshInstallationState() }
    .onReceive(
      DistributedNotificationCenter.default().publisher(
        for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
    ) { _ in input.refreshInstallationState() }
  }
}
