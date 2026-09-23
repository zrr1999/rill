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

      Text(L10n.settingsText(.settingsSpeechModelEnablementDetail, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      if let metadataError = model.downloadedLocalSpeechModelsError {
        settingsDomainLoadFailure(
          message: metadataError,
          retryIdentifier: "settings.local-speech-metadata.retry"
        )
      }

      VStack(alignment: .leading, spacing: RillSpacing.row) {
          Text(UIStrings.text(.settingsLocalSpeech, language: model.language))
            .font(.subheadline.weight(.medium))

          if model.localSpeechTrustMaterialAvailable {
            Text(
              UIStrings.localSpeechAvailabilityDescription(
                model.localSpeechAvailability,
                language: model.language
              )
            )
            .font(.caption)
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
                      L10n.settingsText(
                        .settingsUseHardwareRecommendation,
                        language: model.language
                      )
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
                    L10n.settingsText(
                      .settingsStreamingPreviewModelDetail,
                      language: model.language
                    )
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier("settings.local-speech.streaming-preview-model")
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
              .transition(.opacity)
            } else if model.localSpeechPreparationState == .ready {
              VStack(alignment: .leading, spacing: RillSpacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: RillSpacing.card) {
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
              .transition(.opacity)
            }

            if let testWorkflow = model.localSpeechTestWorkflow {
              VStack(alignment: .leading, spacing: RillSpacing.compact) {
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
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.15),
        value: model.localSpeechPreparationState
      )
      .disabled(model.hasUnavailableScalarSettings(in: .localSpeech))

      Divider()

      llmProviderSettingsSection

      Text(UIStrings.text(.settingsSpeechEngineDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  var llmModelSelection: Binding<LLMModelSelection> {
    Binding(
      get: { LLMModelSelection(modelIdentifier: model.openAIModel) },
      set: { selection in
        if let modelIdentifier = selection.modelIdentifier {
          model.openAIModel = modelIdentifier
        } else if LLMModelSelection(modelIdentifier: model.openAIModel) != .custom {
          model.openAIModel = ""
        }
      }
    )
  }

  func llmModelLabel(_ selection: LLMModelSelection) -> String {
    L10n.llmModelLabel(selection, language: model.language)
  }

  var usesThirdPartyOpenAIEndpoint: Bool {
    guard let host = URLComponents(string: model.openAIBaseURL)?.host?.lowercased() else {
      return false
    }
    return host != "api.openai.com"
  }

  var thirdPartyOpenAICompatibilityHint: String {
    L10n.settingsText(.settingsThirdPartyOpenAIHint, language: model.language)
  }

  var openAIVerificationFailureMessage: String {
    L10n.openAIVerificationFailureMessage(
      model.openAIVerificationFailure,
      language: model.language
    )
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
        Text(L10n.settingsText(.settingsModelPoolTitle, language: model.language))
          .font(.caption.weight(.semibold))
        Text(L10n.settingsText(.settingsModelPoolDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.speechModelPoolDegradedByMemoryPressure {
          Label(
            L10n.settingsText(.settingsModelPoolDegraded, language: model.language),
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
              L10n.settingsText(.settingsKeepResident, language: model.language),
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
              L10n.settingsText(.settingsResidentMemoryWarning, language: model.language),
              systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
            )
            .foregroundStyle(.orange)
            Text(
              L10n.settingsResidentMemoryBudget(
                estimatedGigabytes: Double(budget.estimatedPeakByteCount) / 1_073_741_824,
                estimatedFractionPercent: budget.estimatedFraction * 100,
                modelList: budget.models.map(\.id).joined(separator: ", "),
                language: model.language
              )
            )
            .font(.caption)
            HStack {
              Button(L10n.settingsText(.settingsEnableAnyway, language: model.language)) {
                model.confirmPendingResidentSpeechModels()
              }
              Button(L10n.recordText(.cancel, language: model.language), role: .cancel) {
                model.cancelPendingResidentSpeechModels()
              }
            }
            .controlSize(.small)
          }
          .padding(RillSpacing.row)
          .background(
            .orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: RillRadius.badge, style: .continuous)
          )
        }
      }
      .accessibilityIdentifier("settings.speech-model-pool")
    }
  }

  func speechModelDisplayName(
    _ descriptor: SpeechModelResourceDescriptor
  ) -> String {
    let capability =
      descriptor.capability == .speechToText
      ? L10n.settingsText(.settingsSpeechModelCapabilitySTT, language: model.language)
      : L10n.settingsText(.settingsSpeechModelCapabilityTTS, language: model.language)
    let size = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: descriptor.downloadByteCount),
      countStyle: .file
    )
    return "\(capability) · \(descriptor.id) · \(size)"
  }

}
