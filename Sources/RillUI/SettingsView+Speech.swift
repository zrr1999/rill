import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var speechEngineSection: some View {
    settingsDisclosure(.speech) {
      ForEach(
        [
          ScalarSettingsDomain.speechRoute,
          .localSpeech,
        ].filter { model.hasUnavailableScalarSettings(in: $0) }
      ) { domain in
        unavailableScalarSettingsWarning(domain)
      }

      if !model.localSpeechAvailability.isAvailable {
        Label(
          UIStrings.localSpeechAvailabilityDescription(
            model.localSpeechAvailability,
            language: model.language
          ),
          systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("settings.local-speech-unavailable")
      }

      Text(
        model.language == .english
          ? "Models are enabled here; each workflow chooses its STT model, TTS model, voice, language, prompt, and streaming style."
          : "在这里启用模型；每个 workflow 独立选择 STT 模型、TTS 模型、音色、语言、提示词和流式风格。"
      )
        .font(.caption)
        .foregroundStyle(.secondary)

      if let metadataError = model.downloadedLocalSpeechModelsError {
        settingsDomainLoadFailure(
          message: metadataError,
          retryIdentifier: "settings.local-speech-metadata.retry"
        )
      }

      VStack(alignment: .leading, spacing: 8) {
          Text(UIStrings.text(.settingsLocalSpeech, language: model.language))
            .font(.subheadline.weight(.medium))

          if model.localSpeechTrustMaterialAvailable {
            Text(
              UIStrings.localSpeechAvailabilityDescription(
                model.localSpeechAvailability,
                language: model.language
              )
            )
            .foregroundStyle(.secondary)

            speechModelPoolSettings

            if model.speechModelResourceCatalog.isEmpty {
            if !model.trustedLocalSpeechModels.isEmpty {
              Picker(
                UIStrings.text(.localSpeechModel, language: model.language),
                selection: Binding(
                  get: { model.selectedTrustedLocalSpeechModelIdentifier },
                  set: { _ = model.setPreferredLocalSpeechModel($0) }
                )
              ) {
                ForEach(modelsForSelectedLocalSpeechEngine) { descriptor in
                  Text(
                    model.language == .english
                      ? descriptor.englishName
                      : descriptor.simplifiedChineseName
                  )
                  .tag(descriptor.id)
                }
              }
              .pickerStyle(.menu)
              .disabled(
                model.isLoadingSettings
                  || !model.canMutateScalarSettings(in: .localSpeech)
              )
              .accessibilityIdentifier("settings.local-speech.model")

              if let descriptor = modelsForSelectedLocalSpeechEngine.first(where: {
                $0.id == model.selectedTrustedLocalSpeechModelIdentifier
              }) {
                Text(
                  model.language == .english
                    ? descriptor.englishDetail
                    : descriptor.simplifiedChineseDetail
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.local-speech.trusted-model-detail")
                Text(model.localSpeechModelHardwareDescription(descriptor))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier(
                    "settings.local-speech.trusted-model-hardware"
                  )
                if model.recommendedLocalSpeechModelIdentifier != descriptor.id {
                  Button(
                    model.language == .english
                      ? "Use hardware recommendation"
                      : "使用硬件推荐"
                  ) {
                    model.selectRecommendedLocalSpeechModel()
                  }
                  .controlSize(.small)
                  .disabled(model.isLoadingSettings)
                  .accessibilityIdentifier(
                    "settings.local-speech.use-hardware-recommendation"
                  )
                }
                Text(
                  model.language == .english
                    ? "Live preview uses the workflow's Qwen model; the sealed WAV is always recognized offline for the authoritative final text."
                    : "实时预览使用 workflow 选择的 Qwen 模型；录音封口后始终以 WAV 离线识别生成唯一正式文本。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.local-speech.streaming-preview-model")
              }
            } else {
              Picker(
                UIStrings.text(.localSpeechModel, language: model.language),
                selection: $model.localSpeechModelOption
              ) {
                ForEach(LegacyWhisperModelOption.allCases) { option in
                  Text(model.localSpeechModelOptionLabel(option))
                    .tag(option)
                }
              }
              .pickerStyle(.menu)
            }

            }

            if model.trustedLocalSpeechModels.isEmpty {
              if !model.downloadedLocalSpeechModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  Text(UIStrings.text(.localSpeechDownloadedModels, language: model.language))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                      ForEach(model.downloadedLocalSpeechModels, id: \.self) { modelIdentifier in
                        Button(
                          model.localSpeechModelDisplayName(modelIdentifier, includeStatus: true)
                        ) {
                          model.useDownloadedLocalSpeechModel(modelIdentifier)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isLoadingSettings)
                      }
                    }
                  }
                }
              }

              if model.localSpeechModelOption == .custom {
                VStack(alignment: .leading, spacing: 8) {
                  TextField(
                    UIStrings.text(.legacyWhisperKitCustomModel, language: model.language),
                    text: $model.legacyWhisperKitCustomModel
                  )
                  .textFieldStyle(.roundedBorder)
                  .onSubmit {
                    model.prepareLocalSpeechModel()
                  }

                  HStack(alignment: .center, spacing: 12) {
                    Text(UIStrings.text(.legacyWhisperKitCustomModelHint, language: model.language))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Spacer()
                    Button(UIStrings.text(.localSpeechPrepare, language: model.language)) {
                      model.prepareLocalSpeechModel()
                    }
                    .disabled(model.isLoadingSettings)
                  }
                }
              }
            }

            if model.localSpeechPreparationState == .preparing {
              let preparationStage = LocalSpeechPreparationPresentation.stage(
                displayedProgress: model.localSpeechPreparationProgress
              )
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(
                    UIStrings.text(
                      preparationStage.localizedKey,
                      language: model.language
                    )
                  )
                  .foregroundStyle(.secondary)
                  Spacer()
                  if let downloadFraction = preparationStage.downloadFraction {
                    Text(
                      downloadFraction,
                      format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                  }
                  Button(UIStrings.text(.localSpeechCancelPreparation, language: model.language)) {
                    model.cancelLocalSpeechModelPreparation()
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .accessibilityIdentifier("settings.local-speech.cancel-preparation")
                }
                if let downloadFraction = preparationStage.downloadFraction {
                  ProgressView(value: downloadFraction, total: 1)
                    .controlSize(.small)
                    .progressViewStyle(.linear)
                } else {
                  ProgressView()
                    .controlSize(.small)
                }
              }
            } else if model.localSpeechPreparationState == .ready {
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Label(
                    UIStrings.text(.localSpeechPreparationReady, language: model.language),
                    systemImage: RillSystemSymbol.checkmarkCircleFill.rawValue
                  )
                  .foregroundStyle(.green)

                  Spacer()

                  Button(
                    UIStrings.text(.localSpeechReleaseMemory, language: model.language)
                  ) {
                    model.releaseLocalSpeechModelMemory()
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .help(
                    UIStrings.text(
                      .localSpeechReleaseMemoryHint,
                      language: model.language
                    )
                  )
                  .accessibilityIdentifier("settings.local-speech.release-memory")
                }

                if let preparedModel = model.localSpeechPreparedModelIdentifier {
                  Text(preparedModel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
              }
            }

            if let testWorkflow = model.localSpeechTestWorkflow {
              VStack(alignment: .leading, spacing: 4) {
                Button(model.workflowRunButtonTitle(for: testWorkflow)) {
                  model.runWorkflow(testWorkflow)
                }
                .disabled(
                  !model.canTriggerWorkflow(testWorkflow)
                    || model.localSpeechPreparationState == .preparing
                )
                .accessibilityIdentifier("settings.local-speech.record-test")

                Text(UIStrings.text(.localSpeechLocalTestHint, language: model.language))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            Text(
              UIStrings.text(
                model.trustedLocalSpeechModels.isEmpty
                  ? .localSpeechPreparationHint
                  : .localSpeechTrustedCatalogHint,
                language: model.language
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = model.localSpeechPreparationError, !error.isEmpty {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }
      .disabled(model.hasUnavailableScalarSettings(in: .localSpeech))

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        Text(L10n.string(.settingsOpenAITitle, language: model.language))
          .font(.subheadline.weight(.medium))
        Text(L10n.string(.settingsOpenAIDescription, language: model.language))
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

        providerInputRow(L10n.string(.settingsOpenAIAPIKey, language: model.language)) {
          SecureField("", text: $model.openAIAPIKey)
            .textFieldStyle(.roundedBorder)
            .disabled(model.openAICredentialAvailability == .inaccessible)
            .accessibilityIdentifier("settings.openai.api-key")
        }

        providerInputRow(L10n.string(.settingsOpenAIBaseURL, language: model.language)) {
          TextField("", text: $model.openAIBaseURL)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("settings.openai.base-url")
        }

        Text(L10n.string(.settingsOpenAIEndpointHint, language: model.language))
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker(
          L10n.string(.settingsOpenAIModel, language: model.language),
          selection: openAIModelSelection
        ) {
          ForEach(OpenAIModelSelection.allCases) { selection in
            Text(openAIModelLabel(selection)).tag(selection)
          }
        }
        .pickerStyle(.menu)
        .disabled(model.hasUnavailableScalarSettings(in: .openAI))
        .accessibilityIdentifier("settings.openai.model")

        Text(
          model.language == .english
            ? "Model ID: \(model.openAIModel)"
            : "模型 ID：\(model.openAIModel)"
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

        if openAIModelSelection.wrappedValue == .custom {
          providerInputRow(
            L10n.string(.settingsOpenAICustomModel, language: model.language)
          ) {
            TextField("", text: $model.openAIModel)
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

      Text(UIStrings.text(.settingsSpeechEngineDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  var openAIModelSelection: Binding<OpenAIModelSelection> {
    Binding(
      get: { OpenAIModelSelection(modelIdentifier: model.openAIModel) },
      set: { selection in
        if let modelIdentifier = selection.modelIdentifier {
          model.openAIModel = modelIdentifier
        } else if OpenAIModelOption(rawValue: model.openAIModel) != nil {
          model.openAIModel = ""
        }
      }
    )
  }

  func openAIModelLabel(_ selection: OpenAIModelSelection) -> String {
    switch selection {
    case .luna:
      model.language == .english
        ? "Luna — high volume (gpt-5.6-luna)"
        : "Luna — 高吞吐 (gpt-5.6-luna)"
    case .terra:
      model.language == .english
        ? "Terra — balanced (gpt-5.6-terra)"
        : "Terra — 均衡 (gpt-5.6-terra)"
    case .sol:
      model.language == .english
        ? "Sol — highest capability (gpt-5.6-sol)"
        : "Sol — 最高能力 (gpt-5.6-sol)"
    case .custom:
      model.language == .english ? "Custom model ID" : "自定义模型 ID"
    }
  }

  var usesThirdPartyOpenAIEndpoint: Bool {
    guard let host = URLComponents(string: model.openAIBaseURL)?.host?.lowercased() else {
      return false
    }
    return host != "api.openai.com"
  }

  var thirdPartyOpenAICompatibilityHint: String {
    switch model.language {
    case .english:
      "Verification uses the exact model ID shown above. Third-party providers must expose gpt-5.6-luna for the Luna preset to succeed."
    case .simplifiedChinese:
      "验证会使用上方显示的准确模型 ID。使用 Luna 预设时，第三方服务必须实际开放 gpt-5.6-luna。"
    }
  }

  var openAIVerificationFailureMessage: String {
    switch (model.language, model.openAIVerificationFailure) {
    case (.english, .credentialUnavailable):
      "The saved API key could not be loaded."
    case (.simplifiedChinese, .credentialUnavailable):
      "无法读取已保存的 API Key。"
    case (.english, .configurationInvalid):
      "The endpoint rejected this request or model ID. Check the exact model available from the provider."
    case (.simplifiedChinese, .configurationInvalid):
      "该地址拒绝了当前请求或模型 ID。请核对服务商实际开放的模型 ID。"
    case (.english, .authenticationFailed):
      "Authentication failed. Check whether the API key belongs to this endpoint."
    case (.simplifiedChinese, .authenticationFailed):
      "身份验证失败。请确认 API Key 属于当前服务地址。"
    case (.english, .rateLimited):
      "The account is rate limited or has insufficient quota. Check the provider account and retry."
    case (.simplifiedChinese, .rateLimited):
      "账号受到限流或额度不足。请检查服务商账号后重试。"
    case (.english, .timedOut):
      "The verification request timed out."
    case (.simplifiedChinese, .timedOut):
      "验证请求超时。"
    case (.english, .networkFailed):
      "The endpoint could not be reached. Check the network and Base URL."
    case (.simplifiedChinese, .networkFailed):
      "无法连接该地址。请检查网络和 Base URL。"
    case (.english, .refused):
      "The model refused the verification request."
    case (.simplifiedChinese, .refused):
      "模型拒绝了验证请求。"
    case (.english, .incomplete):
      "The endpoint returned an incomplete response."
    case (.simplifiedChinese, .incomplete):
      "服务返回了不完整响应。"
    case (.english, .invalidResponse):
      "The endpoint returned empty content or an unrecognized Responses API payload."
    case (.simplifiedChinese, .invalidResponse):
      "服务返回了空内容或无法识别的 Responses API 响应。"
    case (.english, .unknown), (.english, nil):
      L10n.string(.settingsOpenAIVerificationFailed, language: .english)
    case (.simplifiedChinese, .unknown), (.simplifiedChinese, nil):
      L10n.string(.settingsOpenAIVerificationFailed, language: .simplifiedChinese)
    }
  }

  func providerInputRow<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      content()
        .environment(\.layoutDirection, .leftToRight)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var availableLocalSpeechEngines: [LocalSpeechEngine] {
    LocalSpeechEngine.allCases.filter { engine in
      model.trustedLocalSpeechModels.contains(where: { $0.engine == engine })
    }
  }

  var selectedLocalSpeechEngine: LocalSpeechEngine? {
    model.trustedLocalSpeechModels.first(where: {
      $0.id == model.selectedTrustedLocalSpeechModelIdentifier
    })?.engine ?? availableLocalSpeechEngines.first
  }

  var modelsForSelectedLocalSpeechEngine: [LocalSpeechModelDescriptor] {
    guard let selectedLocalSpeechEngine else { return [] }
    return model.trustedLocalSpeechModels.filter {
      $0.engine == selectedLocalSpeechEngine
    }
  }

  @ViewBuilder
  var speechModelPoolSettings: some View {
    if !model.speechModelResourceCatalog.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(model.language == .english ? "Available model pool" : "可用模型池")
          .font(.caption.weight(.semibold))
        Text(
          model.language == .english
            ? "Workflows choose models and voices. Enable models here, then optionally keep frequently used models resident."
            : "模型和音色由各 workflow 选择。这里仅启用可用模型，并可选择让常用模型常驻。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.speechModelPoolDegradedByMemoryPressure {
          Label(
            model.language == .english
              ? "Memory pressure unloaded resident models; they will reload on demand."
              : "因系统内存压力，常驻模型已临时卸载；下次使用时会按需重载。",
            systemImage: RillSystemSymbol.memorychip.rawValue
          )
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("settings.speech-model-pool.degraded")
        }

        ForEach(model.speechModelResourceCatalog) { descriptor in
          VStack(alignment: .leading, spacing: 5) {
            Toggle(
              isOn: Binding(
                get: { model.enabledSpeechModelIDs.contains(descriptor.id) },
                set: { model.setSpeechModelEnabled(descriptor.id, enabled: $0) }
              )
            ) {
              Text(speechModelDisplayName(descriptor))
            }
            .disabled(model.isLoadingSettings)

            Toggle(
              model.language == .english ? "Keep resident" : "保持常驻",
              isOn: Binding(
                get: { model.residentSpeechModelIDs.contains(descriptor.id) },
                set: { model.setSpeechModelResident(descriptor.id, resident: $0) }
              )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(
              model.isLoadingSettings
                || !model.enabledSpeechModelIDs.contains(descriptor.id)
            )
          }
          .padding(.vertical, 2)
        }

        if let budget = model.pendingResidentSpeechModelBudget {
          VStack(alignment: .leading, spacing: 6) {
            Label(
              model.language == .english
                ? "Estimated resident memory exceeds 20%"
                : "预计常驻内存超过整机内存的 20%",
              systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
            )
            .foregroundStyle(.orange)
            Text(
              String(
                format: model.language == .english
                  ? "Estimated %.2f GB (%.1f%%): %@"
                  : "预计 %.2f GB（%.1f%%）：%@",
                Double(budget.estimatedPeakByteCount) / 1_073_741_824,
                budget.estimatedFraction * 100,
                budget.models.map(\.id).joined(separator: ", ")
              )
            )
            .font(.caption)
            HStack {
              Button(model.language == .english ? "Enable anyway" : "仍然启用") {
                model.confirmPendingResidentSpeechModels()
              }
              Button(model.language == .english ? "Cancel" : "取消", role: .cancel) {
                model.cancelPendingResidentSpeechModels()
              }
            }
            .controlSize(.small)
          }
          .padding(8)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .accessibilityIdentifier("settings.speech-model-pool")
    }
  }

  func speechModelDisplayName(
    _ descriptor: SpeechModelResourceDescriptor
  ) -> String {
    let capability = descriptor.capability == .speechToText ? "STT" : "TTS"
    let size = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: descriptor.downloadByteCount),
      countStyle: .file
    )
    return "\(capability) · \(descriptor.id) · \(size)"
  }

}
