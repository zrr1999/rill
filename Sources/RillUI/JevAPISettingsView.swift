import RillCore
import SwiftUI

struct JevAPISettingsView: View {
  @Bindable var settings: JevAPISettingsModel
  let language: AppLanguage
  @State private var apiKey = ""
  let focusedItem: FocusState<SettingsItem?>.Binding
  let accessibilityFocusedItem: AccessibilityFocusState<SettingsItem?>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(L10n.resource("models.decision").string(for: language))
        .font(.subheadline.weight(.medium))
      Text(text(.settingsDescription))
        .font(.caption).foregroundStyle(.secondary)
      Picker(
        L10n.resource("models.provider").string(for: language),
        selection: Binding(
          get: { settings.configuration.model },
          set: {
            settings.selectModel($0)
            apiKey = ""
          }
        )
      ) {
        ForEach(DecisionModel.allCases) { model in Text(verbatim: model.displayName).tag(model) }
      }
      .accessibilityIdentifier("settings.decision.model")
      if settings.configuration.model != .jev {
        TextField(
          "Cloudflare Account ID",
          text: Binding(
            get: { settings.configuration.accountID }, set: { settings.setAccountID($0) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("settings.decision.account-id")
      }
      LabeledContent(text(.apiKey)) {
        SecureField(text(.apiKeyPlaceholder), text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .accessibilityLabel(text(.apiKeyPlaceholder))
          .focused(focusedItem, equals: .jevCredential)
          .accessibilityFocused(accessibilityFocusedItem, equals: .jevCredential)
          .accessibilityIdentifier("settings.jev.api-key")
      }
      HStack {
        Button(text(.saveKey)) {
          focusedItem.wrappedValue = nil
          settings.setKey(apiKey)
          apiKey = ""
        }
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.configuration.isValid)
        .accessibilityIdentifier("settings.jev.save-key")
        Button(text(.clearKey)) {
          focusedItem.wrappedValue = nil
          settings.setKey("")
          apiKey = ""
        }
        .disabled(!settings.isConfigured)
        .accessibilityIdentifier("settings.jev.clear-key")
      }
      Text(text(settings.isConfigured ? .keyReady : .keyNotice))
        .font(.caption).foregroundStyle(.secondary)
      if let error = settings.error {
        Text(error == .invalidInput ? text(.invalidKey) : L10n.jevError(error, language: language))
          .font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("settings.jev.error")
      }
    }
    .onDisappear { apiKey = "" }
  }

  private func text(_ key: JevText) -> String { L10n.jev(key, language: language) }
}
