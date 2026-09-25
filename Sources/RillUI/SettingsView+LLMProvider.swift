import RillCore
import SwiftUI

extension SettingsView {
  var apiProviderSettingsSection: some View {
    settingsDisclosure(.providers) {
      if let settings = model.recordWorkspace.jevSettings {
        JevAPISettingsView(settings: settings, language: model.settings.language)
        Divider()
      }
      jevPolishingSettingsSection
      Divider()
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
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
          model.settings.language == .simplifiedChinese
          ? "使用 DeepSeek：Base URL 填写 https://api.deepseek.com，模型选择 DeepSeek V4.1 Flash。润色时自动关闭思考。"
          : "For DeepSeek, use https://api.deepseek.com and choose DeepSeek V4.1 Flash. Thinking is disabled for polishing."
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
      .disabled(model.hasUnavailableScalarSettings(in: .openAI))
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

      HStack(spacing: 10) {
        Button(L10n.string(.settingsOpenAIVerify, language: model.settings.language)) {
          model.verifyOpenAIConfiguration()
        }
        .disabled(!model.canVerifyOpenAIConfiguration)
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

  private var jevPolishingSettingsSection: some View {
    @Bindable var jev = model.jevPolishing
    let chinese = model.settings.language == .simplifiedChinese
    return VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(chinese ? "Jev 润色判断" : "Jev polishing prediction")
        .font(.subheadline.weight(.medium))
      Text(chinese
        ? "启用后，智能整理会先将转写文本与润色要求发送到 TypeSafe Jev。明确无需润色时跳过 LLM，原文仍会保存并输出；判断不确定或失败时继续润色。"
        : "When enabled, Smart Cleanup sends the transcript and rewrite instructions to TypeSafe Jev first. If clearly ready, the text is saved and delivered without an LLM rewrite. Uncertain or failed predictions continue with polishing.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      SecureField("TypeSafe API Key", text: $jev.apiKey)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("settings.jev-polishing.api-key")
      Toggle(chinese ? "用 Jev 判断是否需要润色" : "Use Jev to decide whether polishing is needed",
        isOn: $jev.isEnabled)
        .disabled(!jev.hasValidKey && !jev.isEnabled)
        .accessibilityIdentifier("settings.jev-polishing.enabled")
      Text(chinese
        ? "开关和 Key 仅在本次 App 会话中保留。不会发送音频、屏幕或记忆；使用这些参考信息时仍直接润色。"
        : "The switch and key are kept only for this app session. Audio, screen and memory references are never sent to Jev; runs using those references proceed directly to polishing.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
