import RillCore
import SwiftUI

extension SettingsView {
  var apiProviderSettingsSection: some View {
    settingsDisclosure(.providers) {
      if let settings = model.recordWorkspace.jevSettings {
        JevAPISettingsView(
          settings: settings, language: model.settings.language,
          focusedItem: $focusedSettingsItem, accessibilityFocusedItem: $accessibilityFocusedSettingsItem
        )
        .id(SettingsItem.jevCredential)
        jevPolishingSettingsSection(settings)
        if settings.supportsHotwordSelection {
          JevHotwordSettingsView(settings: settings, language: model.settings.language)
        }
        Divider()
      }
      llmProviderSettingsSection
    }
  }

  var llmProviderSettingsSection: some View {
    VStack(alignment: .leading, spacing: RillSpacing.card) {
      Text(L10n.string(.settingsOpenAITitle, language: model.settings.language))
        .font(.subheadline.weight(.medium))
      Text(L10n.string(.settingsOpenAIDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      switch model.settings.openAICredentialAvailability {
      case .loading:
        ProgressView(L10n.text(.voiceSetupLoading, language: model.settings.language))
          .controlSize(.small)
      case .saving:
        ProgressView(L10n.string(.settingsOpenAISaving, language: model.settings.language))
          .controlSize(.small)
      case .missing:
        Label(
          L10n.string(.settingsOpenAIMissing, language: model.settings.language),
          systemImage: RillSystemSymbol.keySlash.rawValue
        )
        .font(.caption)
        .foregroundStyle(.orange)
      case .available:
        Label(
          L10n.string(.settingsOpenAIAvailable, language: model.settings.language),
          systemImage: RillSystemSymbol.checkmarkCircleFill.rawValue
        )
        .font(.caption)
        .foregroundStyle(.green)
      case .inaccessible:
        HStack(alignment: .firstTextBaseline, spacing: RillSpacing.dense) {
          Label(
            L10n.string(.settingsOpenAIInaccessible, language: model.settings.language),
            systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
          )
          .font(.caption)
          .foregroundStyle(.red)
          Spacer()
          Button(L10n.text(.retryCredentialLoad, language: model.settings.language)) {
            model.retryOpenAICredentialLoad()
          }
        }
      }

      let openAIAPIKeyTitle = L10n.string(.settingsOpenAIAPIKey, language: model.settings.language)
      providerInputRow(openAIAPIKeyTitle) {
        SecureField(openAIAPIKeyTitle, text: Binding(get: { model.settings.openAIAPIKey }, set: { model.setOpenAIAPIKey($0) }))
          .textFieldStyle(.roundedBorder)
          .disabled(model.settings.openAICredentialAvailability == .inaccessible)
          .accessibilityIdentifier("settings.openai.api-key")
      }

      let openAIBaseURLTitle = L10n.string(.settingsOpenAIBaseURL, language: model.settings.language)
      providerInputRow(openAIBaseURLTitle) {
        TextField(openAIBaseURLTitle, text: Binding(get: { model.settings.openAIBaseURL }, set: { model.setOpenAIBaseURL($0) }))
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("settings.openai.base-url")
      }

      Text(L10n.string(.settingsOpenAIEndpointHint, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(
        verbatim:
          L10n.surface(.forDeepseekUseHttpsApi, language: model.settings.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Picker(
        L10n.string(.settingsOpenAIModel, language: model.settings.language),
        selection: llmModelSelection
      ) {
        ForEach(LLMModelSelection.allCases) { selection in
          Text(llmModelLabel(selection)).tag(selection)
        }
      }
      .pickerStyle(.menu)
      .disabled(model.settings.hasUnavailableScalarSettings(in: .openAI))
      .accessibilityIdentifier("settings.openai.model")

      Text(L10n.settingsOpenAIModelID(model.settings.openAIModel, language: model.settings.language))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if llmModelSelection.wrappedValue == .custom {
        let openAICustomModelTitle = L10n.string(
          .settingsOpenAICustomModel,
          language: model.settings.language
        )
        providerInputRow(openAICustomModelTitle) {
          TextField(openAICustomModelTitle, text: Binding(get: { model.settings.openAIModel }, set: { model.setOpenAIModel($0) }))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("settings.openai.custom-model")
        }
      }

      HStack(spacing: RillSpacing.dense) {
        Button(L10n.string(.settingsOpenAIVerify, language: model.settings.language)) {
          model.settings.verifyOpenAIConfiguration()
        }
        .disabled(!model.settings.canVerifyOpenAIConfiguration)
        .accessibilityIdentifier("settings.openai.verify")

        switch model.settings.openAIConfigurationVerificationState {
        case .idle:
          EmptyView()
        case .verifying:
          ProgressView(L10n.string(.settingsOpenAIVerifying, language: model.settings.language))
            .controlSize(.small)
        case .verified:
          Label(
            L10n.string(.settingsOpenAIVerificationSucceeded, language: model.settings.language),
            systemImage: RillSystemSymbol.checkmarkSealFill.rawValue
          )
          .font(.caption)
          .foregroundStyle(.green)
        case .failed:
          Label(
            openAIVerificationFailureMessage,
            systemImage: RillSystemSymbol.xmarkOctagonFill.rawValue
          )
          .font(.caption)
          .foregroundStyle(.red)
        }
      }

      if usesThirdPartyOpenAIEndpoint {
        Text(thirdPartyOpenAICompatibilityHint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(L10n.string(.settingsOpenAITranscriptOnlyHint, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .disabled(model.settings.openAIConfigurationVerificationState == .verifying)
  }

  private func jevPolishingSettingsSection(_ settings: JevAPISettingsModel) -> some View {
    @Bindable var jev = settings
    let language = model.settings.language
    return VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(L10n.resource("SettingsView.LLMProvider.Jev.polishing.prediction").string(for: language))
        .font(.subheadline.weight(.medium))
      Text(
        L10n.resource("SettingsView.LLMProvider.When.enabled.Smart.Cleanup.sends.the.transcript.and.rewrite.instructions.to.TypeSafe.Jev.first").string(
          for: language)
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle(
        L10n.resource("SettingsView.LLMProvider.Use.Jev.to.decide.whether.polishing.is.needed").string(for: language),
        isOn: $jev.isPolishingEnabled
      )
      .disabled(!jev.isConfigured)
      .accessibilityIdentifier("settings.jev-polishing.enabled")
      .id(SettingsItem.jevPolishing)
      .focused($focusedSettingsItem, equals: .jevPolishing)
      .accessibilityFocused($accessibilityFocusedSettingsItem, equals: .jevPolishing)
      Text(
        L10n.resource("SettingsView.LLMProvider.The.switch.and.key.are.kept.only.for.this.app.session.Audio.screen.and").string(for: language)
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
