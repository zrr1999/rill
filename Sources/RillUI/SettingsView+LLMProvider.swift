import RillCore
import SwiftUI

extension SettingsView {
  var apiProviderSettingsSection: some View {
    settingsDisclosure(.providers) {
      if let settings = model.recordWorkspace.jevSettings {
        JevAPISettingsView(settings: settings, language: model.language,
          focusedItem: $focusedSettingsItem, accessibilityFocusedItem: $accessibilityFocusedSettingsItem)
          .id(SettingsItem.jevCredential)
        jevPolishingSettingsSection(settings)
        if settings.supportsHotwordSelection {
          JevHotwordSettingsView(settings: settings, language: model.language)
        }
        Divider()
      }
      llmProviderSettingsSection
    }
  }

  var llmProviderSettingsSection: some View {
    VStack(alignment: .leading, spacing: RillSpacing.card) {
      Text(L10n.string(.settingsOpenAITitle, language: model.language))
        .font(.subheadline.weight(.medium))
      Text(L10n.string(.settingsOpenAIDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      switch model.openAICredentialAvailability {
      case .loading:
        ProgressView(UIStrings.text(.voiceSetupLoading, language: model.language))
          .controlSize(.small)
      case .saving:
        ProgressView(L10n.string(.settingsOpenAISaving, language: model.language))
          .controlSize(.small)
      case .missing:
        Label(
          L10n.string(.settingsOpenAIMissing, language: model.language),
          systemImage: RillSystemSymbol.keySlash.rawValue
        )
        .font(.caption)
        .foregroundStyle(.orange)
      case .available:
        Label(
          L10n.string(.settingsOpenAIAvailable, language: model.language),
          systemImage: RillSystemSymbol.checkmarkCircleFill.rawValue
        )
        .font(.caption)
        .foregroundStyle(.green)
      case .inaccessible:
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Label(
            L10n.string(.settingsOpenAIInaccessible, language: model.language),
            systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
          )
          .font(.caption)
          .foregroundStyle(.red)
          Spacer()
          Button(UIStrings.text(.retryCredentialLoad, language: model.language)) {
            model.retryOpenAICredentialLoad()
          }
        }
      }

      let openAIAPIKeyTitle = L10n.string(.settingsOpenAIAPIKey, language: model.language)
      providerInputRow(openAIAPIKeyTitle) {
        SecureField(openAIAPIKeyTitle, text: $model.openAIAPIKey)
          .textFieldStyle(.roundedBorder)
          .disabled(model.openAICredentialAvailability == .inaccessible)
          .accessibilityIdentifier("settings.openai.api-key")
      }

      let openAIBaseURLTitle = L10n.string(.settingsOpenAIBaseURL, language: model.language)
      providerInputRow(openAIBaseURLTitle) {
        TextField(openAIBaseURLTitle, text: $model.openAIBaseURL)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("settings.openai.base-url")
      }

      Text(L10n.string(.settingsOpenAIEndpointHint, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(
        verbatim:
          model.language == .simplifiedChinese
          ? "使用 DeepSeek：Base URL 填写 https://api.deepseek.com，模型选择 DeepSeek V4.1 Flash。润色时自动关闭思考。"
          : "For DeepSeek, use https://api.deepseek.com and choose DeepSeek V4.1 Flash. Thinking is disabled for polishing."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Picker(
        L10n.string(.settingsOpenAIModel, language: model.language),
        selection: llmModelSelection
      ) {
        ForEach(LLMModelSelection.allCases) { selection in
          Text(llmModelLabel(selection)).tag(selection)
        }
      }
      .pickerStyle(.menu)
      .disabled(model.hasUnavailableScalarSettings(in: .openAI))
      .accessibilityIdentifier("settings.openai.model")

      Text(L10n.settingsOpenAIModelID(model.openAIModel, language: model.language))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if llmModelSelection.wrappedValue == .custom {
        let openAICustomModelTitle = L10n.string(
          .settingsOpenAICustomModel,
          language: model.language
        )
        providerInputRow(openAICustomModelTitle) {
          TextField(openAICustomModelTitle, text: $model.openAIModel)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("settings.openai.custom-model")
        }
      }

      HStack(spacing: 10) {
        Button(L10n.string(.settingsOpenAIVerify, language: model.language)) {
          model.verifyOpenAIConfiguration()
        }
        .disabled(!model.canVerifyOpenAIConfiguration)
        .accessibilityIdentifier("settings.openai.verify")

        switch model.openAIConfigurationVerificationState {
        case .idle:
          EmptyView()
        case .verifying:
          ProgressView(L10n.string(.settingsOpenAIVerifying, language: model.language))
            .controlSize(.small)
        case .verified:
          Label(
            L10n.string(.settingsOpenAIVerificationSucceeded, language: model.language),
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

      Text(L10n.string(.settingsOpenAITranscriptOnlyHint, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .disabled(model.openAIConfigurationVerificationState == .verifying)
  }

  private func jevPolishingSettingsSection(_ settings: JevAPISettingsModel) -> some View {
    @Bindable var jev = settings
    let chinese = model.language == .simplifiedChinese
    return VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(chinese ? "Jev 润色判断" : "Jev polishing prediction")
        .font(.subheadline.weight(.medium))
      Text(chinese
        ? "启用后，智能整理会先将转写文本与润色要求发送到 TypeSafe Jev。明确无需润色时跳过 LLM，原文仍会保存并输出；判断不确定或失败时继续润色。"
        : "When enabled, Smart Cleanup sends the transcript and rewrite instructions to TypeSafe Jev first. If clearly ready, the text is saved and delivered without an LLM rewrite. Uncertain or failed predictions continue with polishing.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle(chinese ? "用 Jev 判断是否需要润色" : "Use Jev to decide whether polishing is needed",
        isOn: $jev.isPolishingEnabled)
        .disabled(!jev.isConfigured)
        .accessibilityIdentifier("settings.jev-polishing.enabled")
        .id(SettingsItem.jevPolishing)
        .focused($focusedSettingsItem, equals: .jevPolishing)
        .accessibilityFocused($accessibilityFocusedSettingsItem, equals: .jevPolishing)
      Text(chinese
        ? "开关和 Key 仅在本次 App 会话中保留。不会发送音频、屏幕或记忆；使用这些参考信息时仍直接润色。"
        : "The switch and key are kept only for this app session. Audio, screen and memory references are never sent to Jev; runs using those references proceed directly to polishing.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
