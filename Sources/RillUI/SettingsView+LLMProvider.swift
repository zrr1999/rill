import RillCore
import SwiftUI

extension SettingsView {
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
}
