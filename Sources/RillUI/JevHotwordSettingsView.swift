import RillCore
import SwiftUI

struct JevHotwordSettingsView: View {
  @Bindable var settings: JevAPISettingsModel
  let language: AppLanguage

  var body: some View {

    VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(L10n.resource("JevHotwordSettingsView.Jev.hotword.selection.Experimental").string(for: language))
        .font(.subheadline.weight(.medium))
      Text(
        L10n.resource("JevHotwordSettingsView.Enabling.sends.candidate.hotwords.app.and.workflow.names.and.the.authorized.text.selection.to").string(
          for: language)
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle(L10n.resource("JevHotwordSettingsView.Select.relevant.hotwords").string(for: language), isOn: $settings.isHotwordSelectionEnabled)
        .disabled(!settings.isConfigured)
        .accessibilityIdentifier("settings.jev-hotwords.enabled")
      Text(
        L10n.resource("JevHotwordSettingsView.The.switch.and.key.last.only.for.this.app.session.Recording.never.waits.for").string(for: language)
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
