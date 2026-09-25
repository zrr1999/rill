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
        ].filter { model.settings.hasUnavailableScalarSettings(in: $0) }
      ) { domain in
        unavailableScalarSettingsWarning(domain)
      }

      if !model.localSpeechAvailability.isAvailable {
        Label(
          L10n.localSpeechAvailabilityDescription(
            model.localSpeechAvailability,
            language: model.settings.language
          ),
          systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("settings.local-speech-unavailable")
      }

      Text(L10n.settingsText(.settingsSpeechModelEnablementDetail, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      if let metadataError = model.voice.downloadedLocalSpeechModelsError {
        settingsDomainLoadFailure(
          message: metadataError,
          retryIdentifier: "settings.local-speech-metadata.retry"
        )
      }

      VStack(alignment: .leading, spacing: RillSpacing.row) {
          Text(L10n.text(.settingsLocalSpeech, language: model.settings.language))
            .font(.subheadline.weight(.medium))

          if model.localSpeechTrustMaterialAvailable {
            Text(
              L10n.localSpeechAvailabilityDescription(
                model.localSpeechAvailability,
                language: model.settings.language
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            speechModelPoolSettings

            if model.speechModelResourceCatalog.isEmpty {
              if !model.trustedLocalSpeechModels.isEmpty {
                Picker(
                  L10n.text(.localSpeechModel, language: model.settings.language),
                  selection: Binding(
                    get: { model.selectedTrustedLocalSpeechModelIdentifier },
                    set: { _ = model.setPreferredLocalSpeechModel($0) }
                  )
                ) {
                  ForEach(modelsForSelectedLocalSpeechEngine) { descriptor in
                    Text(
                      model.settings.language == .english
                        ? descriptor.englishName
                        : descriptor.simplifiedChineseName
                    )
                    .tag(descriptor.id)
                  }
                }
                .pickerStyle(.menu)
                .disabled(
                  model.settings.isLoading
                    || !model.settings.canMutateScalarSettings(in: .localSpeech)
                )
                .accessibilityIdentifier("settings.local-speech.model")

                if let descriptor = modelsForSelectedLocalSpeechEngine.first(where: {
                  $0.id == model.selectedTrustedLocalSpeechModelIdentifier
                }) {
                  Text(
                    model.settings.language == .english
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
                        language: model.settings.language
                      )
                    ) {
                      model.selectRecommendedLocalSpeechModel()
                    }
                    .controlSize(.small)
                    .disabled(model.settings.isLoading)
                    .accessibilityIdentifier(
                      "settings.local-speech.use-hardware-recommendation"
                    )
                  }
                  Text(
                    L10n.settingsText(
                      .settingsStreamingPreviewModelDetail,
                      language: model.settings.language
                    )
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier("settings.local-speech.streaming-preview-model")
                }
              }
            }

            if model.voice.localSpeechPreparationState == .preparing {
              let preparationStage = LocalSpeechPreparationPresentation.stage(
                displayedProgress: model.voice.localSpeechPreparationProgress
              )
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(
                    L10n.text(
                      preparationStage.localizedKey,
                      language: model.settings.language
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
                  Button(L10n.text(.localSpeechCancelPreparation, language: model.settings.language)) {
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
            } else if model.voice.localSpeechPreparationState == .ready {
              VStack(alignment: .leading, spacing: RillSpacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: RillSpacing.card) {
                  Label(
                    L10n.text(.localSpeechPreparationReady, language: model.settings.language),
                    systemImage: RillSystemSymbol.checkmarkCircleFill.rawValue
                  )
                  .foregroundStyle(.green)

                  Spacer()

                  Button(
                    L10n.text(.localSpeechReleaseMemory, language: model.settings.language)
                  ) {
                    model.releaseLocalSpeechModelMemory()
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .help(
                    L10n.text(
                      .localSpeechReleaseMemoryHint,
                      language: model.settings.language
                    )
                  )
                  .accessibilityIdentifier("settings.local-speech.release-memory")
                }

                if let preparedModel = model.voice.localSpeechPreparedModelIdentifier {
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
                    || model.voice.localSpeechPreparationState == .preparing
                )
                .accessibilityIdentifier("settings.local-speech.record-test")

                Text(L10n.text(.localSpeechLocalTestHint, language: model.settings.language))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            Text(
              L10n.text(
                model.trustedLocalSpeechModels.isEmpty
                  ? .localSpeechPreparationHint
                  : .localSpeechTrustedCatalogHint,
                language: model.settings.language
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = model.voice.localSpeechPreparationError, !error.isEmpty {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.15),
        value: model.voice.localSpeechPreparationState
      )
      .disabled(model.settings.hasUnavailableScalarSettings(in: .localSpeech))

      Text(L10n.text(.settingsSpeechEngineDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  var llmModelSelection: Binding<LLMModelSelection> {
    Binding(
      get: { LLMModelSelection(modelIdentifier: model.settings.openAIModel) },
      set: { selection in
        if let modelIdentifier = selection.modelIdentifier {
          model.setOpenAIModel(modelIdentifier)
        } else if LLMModelSelection(modelIdentifier: model.settings.openAIModel) != .custom {
          model.setOpenAIModel("")
        }
      }
    )
  }

  func llmModelLabel(_ selection: LLMModelSelection) -> String {
    L10n.llmModelLabel(selection, language: model.settings.language)
  }

  var usesThirdPartyOpenAIEndpoint: Bool {
    guard let host = URLComponents(string: model.settings.openAIBaseURL)?.host?.lowercased() else {
      return false
    }
    return host != "api.openai.com"
  }

  var thirdPartyOpenAICompatibilityHint: String {
    L10n.settingsText(.settingsThirdPartyOpenAIHint, language: model.settings.language)
  }

  var openAIVerificationFailureMessage: String {
    L10n.openAIVerificationFailureMessage(
      model.settings.openAIVerificationFailure,
      language: model.settings.language
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
        Text(L10n.settingsText(.settingsModelPoolTitle, language: model.settings.language))
          .font(.caption.weight(.semibold))
        Text(L10n.settingsText(.settingsModelPoolDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.voice.speechModelPoolDegradedByMemoryPressure {
          Label(
            L10n.settingsText(.settingsModelPoolDegraded, language: model.settings.language),
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
                get: { model.settings.enabledSpeechModelIDs.contains(descriptor.id) },
                set: { model.setSpeechModelEnabled(descriptor.id, enabled: $0) }
              )
            ) {
              Text(speechModelDisplayName(descriptor))
            }
            .disabled(model.settings.isLoading)

            Toggle(
              L10n.settingsText(.settingsKeepResident, language: model.settings.language),
              isOn: Binding(
                get: { model.settings.residentSpeechModelIDs.contains(descriptor.id) },
                set: { model.setSpeechModelResident(descriptor.id, resident: $0) }
              )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(
              model.settings.isLoading
                || !model.settings.enabledSpeechModelIDs.contains(descriptor.id)
            )
          }
          .padding(.vertical, 2)
        }

        if let budget = model.pendingResidentSpeechModelBudget {
          VStack(alignment: .leading, spacing: 6) {
            Label(
              L10n.settingsText(.settingsResidentMemoryWarning, language: model.settings.language),
              systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
            )
            .foregroundStyle(.orange)
            Text(
              L10n.settingsResidentMemoryBudget(
                estimatedGigabytes: Double(budget.estimatedPeakByteCount) / 1_073_741_824,
                estimatedFractionPercent: budget.estimatedFraction * 100,
                modelList: budget.models.map(\.id).joined(separator: ", "),
                language: model.settings.language
              )
            )
            .font(.caption)
            HStack {
              Button(L10n.settingsText(.settingsEnableAnyway, language: model.settings.language)) {
                model.confirmPendingResidentSpeechModels()
              }
              Button(L10n.recordText(.cancel, language: model.settings.language), role: .cancel) {
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
      ? L10n.settingsText(.settingsSpeechModelCapabilitySTT, language: model.settings.language)
      : L10n.settingsText(.settingsSpeechModelCapabilityTTS, language: model.settings.language)
    let size = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: descriptor.downloadByteCount),
      countStyle: .file
    )
    return "\(capability) · \(descriptor.id) · \(size)"
  }

}
