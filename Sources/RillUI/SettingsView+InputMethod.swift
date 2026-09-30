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
    Section(L10n.inputMethod(.sectionTitle, language: language)) {
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
        L10n.inputMethod(.learnFromTyping, language: language),
        isOn: Binding(get: { input.state.enabled }, set: { input.setEnabled($0) })
      )
      .disabled(!input.isReady)
      Text(L10n.inputMethod(.learnNotice, language: language))
        .font(.caption).foregroundStyle(.secondary)
      Button(L10n.inputMethod(.chooseApps, language: language)) {
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
          Button(L10n.inputMethod(.remove, language: language)) { input.setApplication(app, allowed: false) }
        }
      }
      ForEach(
        input.state.suggestions.filter { $0.status != .ignored }.sorted { $0.count > $1.count }
      ) { suggestion in
        HStack {
          VStack(alignment: .leading) {
            Text(suggestion.phrase)
            Text(
              L10n.inputMethodSuggestionDetail(
                count: suggestion.count,
                applications: suggestion.applications.sorted().map(applicationName).joined(separator: ", "),
                language: language
              )
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if suggestion.status == .pending {
            Button(L10n.inputMethod(.confirm, language: language)) { Task { await input.confirm(suggestion) } }
            Button(L10n.inputMethod(.ignore, language: language)) { Task { await input.ignore(suggestion.id) } }
          } else {
            Text(L10n.inputMethod(.confirmed, language: language)).foregroundStyle(.secondary)
          }
          Button(L10n.inputMethod(suggestion.ownsConfirmedRule ? .revokeVocabulary : .deleteSuggestion, language: language)) {
            Task { await input.remove(suggestion) }
          }
        }
      }
      Button(L10n.inputMethod(.clearPending, language: language)) { Task { await input.clearPending() } }.disabled(!input.isReady)
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
