import SwiftUI
import RillCore

private enum SettingsDestructiveConfirmation: Sendable {
  case clipboardHistory
  case runHistory
  case failedAudioRecovery
}

private enum SettingsSheetDestination: Identifiable {
  case privacyNotice(PrivacyNoticeDocument)

  var id: String {
    switch self {
    case .privacyNotice:
      return "privacy-notice"
    }
  }
}

enum SettingsPermissionAction: Equatable {
  case none
  case request
  case openSettings
}

enum SettingsPermissionTone: Equatable {
  case success
  case secondary
  case warning
  case error
}

struct SettingsPermissionPresentation: Equatable {
  let detail: String
  let tone: SettingsPermissionTone
  let action: SettingsPermissionAction

  static func make(
    state: PermissionState,
    isRequired: Bool,
    optionalDetail: String?,
    language: AppLanguage
  ) -> Self {
    if state == .granted {
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .success,
        action: .none
      )
    }
    if !isRequired {
      return Self(
        detail: optionalDetail
          ?? UIStrings.permissionState(state, language: language),
        tone: .secondary,
        action: .none
      )
    }
    switch state {
    case .granted:
      preconditionFailure("Granted permissions are handled above")
    case .unknown:
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .warning,
        action: .request
      )
    case .denied:
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .error,
        action: .openSettings
      )
    }
  }
}

public struct SettingsView: View {
  @Bindable private var model: AppModel
  private let privacyNoticeDocument: PrivacyNoticeDocument?
  @State private var vocabularyKind: VocabularyRuleKind = .mapping
  @State private var vocabularyPattern = ""
  @State private var vocabularyReplacement = ""
  @State private var vocabularyMatchMode: VocabularyMatchMode = .exactPhrase
  @State private var vocabularyCaseSensitive = false
  @State private var vocabularyBundleIdentifier = ""
  @State private var vocabularyGroupID: UUID?
  @State private var vocabularyLocale = ""
  @State private var vocabularyPriority = 0
  @State private var sensitiveAppBundleIdentifier = ""
  @State private var sensitiveAppApplicationName = ""
  @State private var editingSensitiveAppRuleID: UUID?
  @State private var sensitiveAppRuleError: String?
  @State private var destructiveConfirmation: SettingsDestructiveConfirmation?
  @State private var presentedSheet: SettingsSheetDestination?
  @FocusState private var focusedSettingsSection: SettingsSection?
  @AccessibilityFocusState private var accessibilityFocusedSettingsSection: SettingsSection?

  public init(
    model: AppModel,
    privacyNoticeDocument: PrivacyNoticeDocument? = PrivacyNoticeDocument.bundled
  ) {
    self.model = model
    self.privacyNoticeDocument = privacyNoticeDocument
  }

  public var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          Text(UIStrings.text(.settingsDescription, language: model.language))
            .foregroundStyle(.secondary)
        }

        if let unsavedSummary = model.settingsSaveState.unsavedSummary {
          settingsSaveFailureSection(unsavedSummary)
        }

        Section {
          if model.hasUnavailableScalarSettings(in: .interface) {
            unavailableScalarSettingsWarning(.interface)
          }
          Picker(
            UIStrings.text(.language, language: model.language),
            selection: Binding(
              get: { model.language },
              set: { model.setInterfaceLanguage($0) }
            )
          ) {
            ForEach(AppLanguage.allCases) { lang in
              Text(lang.displayName).tag(lang)
            }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 260)
          .disabled(!model.canMutateScalarSettings(in: .interface))
        } header: {
          settingsSectionHeader(.language)
        } footer: {
          Text(UIStrings.text(.settingsLanguageDescription, language: model.language))
        }
        .id(SettingsSection.language)

        Section {
          if model.hasUnavailableScalarSettings(in: .clipboard) {
            unavailableScalarSettingsWarning(.clipboard)
          }
          Toggle(
            UIStrings.text(
              .settingsClipboardCaptureEnabled,
              language: model.language
            ),
            isOn: Binding(
              get: { model.clipboardCaptureEnabled },
              set: { model.setClipboardCaptureEnabled($0) }
            )
          )
          .disabled(!model.canMutateScalarSettings(in: .clipboard))
          .accessibilityIdentifier("settings.clipboard.capture-enabled")

          Text(
            UIStrings.text(
              .settingsClipboardCaptureEnabledDescription,
              language: model.language
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          if ClipboardPanelShortcutPresentationPolicy.surfaceVisibility(
            clipboardCaptureEnabled: model.clipboardCaptureEnabled
          ).settingsRecorder {
            Divider()

            HotkeyRecorderView(
              binding: model.clipboardPanelHotkeyBinding,
              language: model.language,
              beginClipboardPanelShortcutRecording: {
                model.beginClipboardPanelShortcutRecording()
              },
              endClipboardPanelShortcutRecording: { suspensionID in
                model.endClipboardPanelShortcutRecording(suspensionID)
              },
              commitClipboardPanelShortcutRecording: { suspensionID, keyCode in
                model.commitClipboardPanelShortcutRecording(
                  suspensionID,
                  keyCode: keyCode
                )
              },
              onRecord: { shortcut in
                model.setClipboardPanelHotkeyShortcut(shortcut)
              },
              onReset: {
                model.resetClipboardPanelHotkeyBinding()
              }
            )
            .disabled(model.hasUnavailableScalarSettings(in: .clipboard))
          }
        } header: {
          settingsSectionHeader(.clipboardPanel)
        } footer: {
          Text(UIStrings.text(.settingsClipboardPanelDescription, language: model.language))
        }
        .id(SettingsSection.clipboardPanel)

        Section {
          HStack {
            Spacer()
            Button(UIStrings.text(.refreshPermissions, language: model.language)) {
              model.refreshPermissions()
            }
          }

          globalInputPermissionRow(model.globalInputCapability)

          permissionRow(
            title: UIStrings.text(.accessibility, language: model.language),
            state: model.permissionSnapshot.accessibility,
            isRequired: model.voiceSetupReadiness.accessibilityRequired,
            optionalDetail: UIStrings.text(
              .voiceSetupAccessibilityOptional,
              language: model.language
            ),
            requestAction: model.requestAccessibilityPermission,
            openSettingsAction: model.openAccessibilitySettings
          )

          permissionRow(
            title: UIStrings.text(.microphone, language: model.language),
            state: model.permissionSnapshot.microphone,
            requestAction: model.requestMicrophonePermission,
            openSettingsAction: model.openMicrophoneSettings
          )

          if model.voiceSetupReadiness.accessibilityRequired,
            model.permissionSnapshot.accessibility != .granted
          {
            Text(UIStrings.text(.appNotListedHint, language: model.language))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        } header: {
          settingsSectionHeader(.permissions)
        } footer: {
          Text(UIStrings.text(.permissionHint, language: model.language))
        }
        .id(SettingsSection.permissions)

        privacySection
          .id(SettingsSection.privacy)
        localDataAndRetentionSection
          .id(SettingsSection.storage)
        speechEngineSection
          .id(SettingsSection.speech)
        vocabularySection
          .id(SettingsSection.vocabulary)
        builtinPushToTalkSection
          .id(SettingsSection.input)
      }
      .formStyle(.grouped)
      .task(id: model.settingsNavigationRequest?.id) {
        guard let request = model.settingsNavigationRequest else { return }
        await positionSettingsSection(request, proxy: proxy)
      }
    }
    .navigationTitle(UIStrings.text(.settingsTitle, language: model.language))
    .sheet(item: $presentedSheet) { destination in
      switch destination {
      case .privacyNotice(let document):
        PrivacyNoticeSheet(document: document, language: model.language)
      }
    }
    .confirmationDialog(
      destructiveConfirmationTitle,
      isPresented: Binding(
        get: { destructiveConfirmation != nil },
        set: { isPresented in
          if !isPresented {
            destructiveConfirmation = nil
          }
        }
      ),
      presenting: destructiveConfirmation
    ) { confirmation in
      Button(destructiveConfirmationActionTitle(confirmation), role: .destructive) {
        destructiveConfirmation = nil
        performDestructiveConfirmation(confirmation)
      }
      Button(
        L10n.historySettingsText(.cancel, language: model.language),
        role: .cancel
      ) {
        destructiveConfirmation = nil
      }
    } message: { confirmation in
      Text(destructiveConfirmationDetail(confirmation))
    }
  }

  private func settingsSectionHeader(_ section: SettingsSection) -> some View {
    Label(section.title(language: model.language), systemImage: section.symbolName)
      .focusable()
      .focused($focusedSettingsSection, equals: section)
      .accessibilityFocused(
        $accessibilityFocusedSettingsSection,
        equals: section
      )
      .accessibilityIdentifier("settings.section.\(section.rawValue)")
  }

  private func positionSettingsSection(
    _ request: SettingsNavigationRequest,
    proxy: ScrollViewProxy
  ) async {
    await Task.yield()
    guard model.selectedSidebarSection == .settings,
      model.settingsNavigationRequest?.id == request.id
    else {
      return
    }
    withAnimation(.easeInOut(duration: 0.2)) {
      proxy.scrollTo(request.section, anchor: .top)
    }
    await Task.yield()
    guard model.settingsNavigationRequest?.id == request.id else { return }
    focusedSettingsSection = request.section
    accessibilityFocusedSettingsSection = request.section
  }

  private var destructiveConfirmationTitle: String {
    guard let destructiveConfirmation else { return "" }
    return switch destructiveConfirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboardConfirmation, language: model.language)
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmation, language: model.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmation,
        language: model.language
      )
    }
  }

  private func destructiveConfirmationActionTitle(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboard, language: model.language)
    case .runHistory:
      L10n.historySettingsText(.clearRun, language: model.language)
    case .failedAudioRecovery:
      L10n.string(.settingsFailedAudioRecoveryClear, language: model.language)
    }
  }

  private func destructiveConfirmationDetail(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(
        .clearClipboardConfirmationDetail,
        language: model.language
      )
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmationDetail, language: model.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmationDetail,
        language: model.language
      )
    }
  }

  private func performDestructiveConfirmation(
    _ confirmation: SettingsDestructiveConfirmation
  ) {
    switch confirmation {
    case .clipboardHistory:
      model.clearClipboardHistory()
    case .runHistory:
      model.clearRunHistory()
    case .failedAudioRecovery:
      model.clearFailedAudioRecoveries()
    }
  }

  private func permissionRow(
    title: String,
    state: PermissionState,
    isRequired: Bool = true,
    optionalDetail: String? = nil,
    requestAction: @escaping () -> Void,
    openSettingsAction: @escaping () -> Void
  ) -> some View {
    let presentation = SettingsPermissionPresentation.make(
      state: state,
      isRequired: isRequired,
      optionalDetail: optionalDetail,
      language: model.language
    )
    return HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(presentation.detail)
          .font(.caption)
          .foregroundStyle(permissionColor(presentation.tone))
      }
      Spacer()
      switch presentation.action {
      case .none:
        EmptyView()
      case .request:
        Button(UIStrings.text(.requestAccess, language: model.language)) {
          requestAction()
        }
      case .openSettings:
        Button(UIStrings.text(.openSettings, language: model.language)) {
          openSettingsAction()
        }
      }
    }
  }

  private func settingsSaveFailureSection(
    _ summary: UnsavedSettingsSummary
  ) -> some View {
    Section {
      Label(
        UIStrings.text(.settingsSaveFailedTitle, language: model.language),
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      .accessibilityIdentifier("settings.unsaved.title")

      Text(UIStrings.settingsSaveFailureDescription(summary, language: model.language))
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("settings.unsaved.description")

      HStack {
        Spacer()
        Button {
          model.retryUnsavedSettingsSave()
        } label: {
          if model.settingsSaveState.isRetrying {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(UIStrings.text(.settingsSaveRetrying, language: model.language))
            }
          } else {
            Text(UIStrings.text(.settingsSaveRetry, language: model.language))
          }
        }
        .disabled(model.settingsSaveState.isRetrying)
        .accessibilityIdentifier("settings.unsaved.retry")
      }
    }
  }

  private func unavailableScalarSettingsWarning(
    _ domain: ScalarSettingsDomain
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        domain.unavailableWarning(language: model.language),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(.orange)

      HStack {
        Spacer()
        Button {
          model.retryUnavailableScalarSettings(in: domain)
        } label: {
          if model.isRetryingUnavailableScalarSettings(in: domain) {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(model.language == .english ? "Retrying…" : "正在重试…")
            }
          } else {
            Text(model.language == .english ? "Retry Loading" : "重试加载")
          }
        }
        .disabled(model.isRetryingUnavailableScalarSettings(in: domain))
        .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue).retry")
      }
    }
    .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue)")
  }

  @ViewBuilder
  private func globalInputPermissionRow(_ capability: GlobalInputCapability) -> some View {
    let title = UIStrings.text(.globalInput, language: model.language)
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(globalInputPermissionDetail(capability))
          .font(.caption)
          .foregroundStyle(globalInputPermissionColor(capability))
      }
      Spacer()
      switch capability {
      case .checking, .available:
        EmptyView()
      case .permissionRequired:
        Button(UIStrings.text(.requestAccess, language: model.language)) {
          model.requestGlobalInputPermission()
        }
        .accessibilityIdentifier("settings.global-input.request")
      case .installationFailed:
        Button(UIStrings.text(.retryGlobalInput, language: model.language)) {
          model.retryGlobalInputInstallation()
        }
        .accessibilityIdentifier("settings.global-input.retry")
      }
    }
    .accessibilityIdentifier("settings.global-input.status")
  }

  private func globalInputPermissionDetail(_ capability: GlobalInputCapability) -> String {
    let key: UIStrings.Key =
      switch capability {
      case .checking:
        .voiceSetupGlobalInputChecking
      case .available:
        ClipboardPanelShortcutPresentationPolicy.globalInputReadyDetail(
          clipboardCaptureEnabled: model.clipboardCaptureEnabled
        )
      case .permissionRequired:
        .voiceSetupGlobalInputPermissionNeeded
      case .installationFailed:
        .voiceSetupGlobalInputInstallationFailed
      }
    return UIStrings.text(key, language: model.language)
  }

  private func globalInputPermissionColor(_ capability: GlobalInputCapability) -> Color {
    switch capability {
    case .checking:
      .secondary
    case .available:
      .green
    case .permissionRequired:
      .orange
    case .installationFailed:
      .red
    }
  }

  private var speechEngineSection: some View {
    Section {
      ForEach(
        [
          ScalarSettingsDomain.speechRoute,
          .localSpeech,
          .deepgram,
        ].filter { model.hasUnavailableScalarSettings(in: $0) }
      ) { domain in
        unavailableScalarSettingsWarning(domain)
      }

      Picker(
        UIStrings.text(.settingsSpeechEngine, language: model.language),
        selection: Binding(
          get: { model.preferredSpeechEngine },
          set: { engine in
            model.setPreferredSpeechEngine(engine)
          }
        )
      ) {
        ForEach(PreferredSpeechEngine.allCases) { engine in
          Text(UIStrings.speechEngine(engine, language: model.language))
            .tag(engine)
            .disabled(engine == .local && !model.localSpeechTrustMaterialAvailable)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!model.canMutateScalarSettings(in: .speechRoute))

      if !model.localSpeechAvailability.isAvailable {
        Label(
          UIStrings.localSpeechAvailabilityDescription(
            model.localSpeechAvailability,
            language: model.language
          ),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("settings.local-speech-unavailable")
      }

      Text(L10n.privacySettingsSpeechRouteHint(preferredSpeechRoute, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      if let metadataError = model.downloadedLocalSpeechModelsError {
        settingsDomainLoadFailure(
          message: metadataError,
          retryIdentifier: "settings.local-speech-metadata.retry"
        )
      }

      if model.preferredSpeechEngine == .local {
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

            if !model.trustedLocalSpeechModels.isEmpty {
              Picker(
                UIStrings.text(.localSpeechModel, language: model.language),
                selection: Binding(
                  get: { model.selectedTrustedLocalSpeechModelIdentifier },
                  set: { model.selectTrustedLocalSpeechModel($0) }
                )
              ) {
                ForEach(model.trustedLocalSpeechModels) { descriptor in
                  Text(model.localSpeechModelDisplayName(descriptor.id))
                    .tag(descriptor.id)
                }
              }
              .pickerStyle(.menu)
              .accessibilityIdentifier("settings.local-speech.trusted-model")
              if let descriptor = model.trustedLocalSpeechModels.first(where: {
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
                    ? "Live preview and Streaming Direct use the fixed bilingual Streaming Zipformer INT8 model (about 437 MiB additional first download); Accurate Transcription uses the selected final tier."
                    : "流式预览和“流式直出”固定使用中英双语 Streaming Zipformer INT8（首次额外下载约 437 MiB）；“精准转写”使用所选最终档位。"
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

            Toggle(
              UIStrings.text(.localSpeechPrewarm, language: model.language),
              isOn: $model.localSpeechPrewarm
            )

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
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(
                    UIStrings.text(
                      model.localSpeechPreparationProgress >= 1
                        ? .localSpeechFinalizing
                        : .localSpeechPreparing,
                      language: model.language
                    )
                  )
                  .foregroundStyle(.secondary)
                  Spacer()
                  if model.localSpeechPreparationProgress < 1 {
                    Text(
                      model.localSpeechPreparationProgress,
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
                if model.localSpeechPreparationProgress >= 1 {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  ProgressView(value: model.localSpeechPreparationProgress, total: 1)
                    .controlSize(.small)
                    .progressViewStyle(.linear)
                }
              }
            } else if model.localSpeechPreparationState == .ready {
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Label(
                    UIStrings.text(.localSpeechPreparationReady, language: model.language),
                    systemImage: "checkmark.circle.fill"
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
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text(UIStrings.text(.settingsDeepgram, language: model.language))
            .font(.subheadline.weight(.medium))
          Text(UIStrings.text(.settingsDeepgramDescription, language: model.language))
            .foregroundStyle(.secondary)

          if let failureMessage = recoverableDeepgramFailureMessage {
            Label(
              UIStrings.text(.diagnosticsManageProviderSettings, language: model.language),
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .accessibilityHint(failureMessage)
          }

          switch model.deepgramCredentialAvailability {
          case .loading:
            ProgressView(UIStrings.text(.voiceSetupLoading, language: model.language))
              .controlSize(.small)
          case .saving:
            ProgressView(UIStrings.text(.voiceSetupCloudCredentialSaving, language: model.language))
              .controlSize(.small)
          case .inaccessible:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Label(
                UIStrings.text(.voiceSetupCloudCredentialUnavailable, language: model.language),
                systemImage: "exclamationmark.triangle.fill"
              )
              .font(.callout)
              .foregroundStyle(.red)
              Spacer()
              Button(UIStrings.text(.retryCredentialLoad, language: model.language)) {
                model.retryDeepgramCredentialLoad()
              }
            }
          case .missing, .available:
            EmptyView()
          }

          SecureField(
            UIStrings.text(.deepgramAPIKey, language: model.language),
            text: $model.deepgramAPIKey
          )
          .textFieldStyle(.roundedBorder)

          TextField(
            UIStrings.text(.deepgramBaseURL, language: model.language),
            text: $model.deepgramBaseURL
          )
          .textFieldStyle(.roundedBorder)
          Text(L10n.string(.settingsDeepgramSecureEndpointHint, language: model.language))
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack(spacing: 12) {
            TextField(
              UIStrings.text(.deepgramModel, language: model.language),
              text: $model.deepgramModel
            )
            .textFieldStyle(.roundedBorder)

            TextField(
              UIStrings.text(.deepgramLanguage, language: model.language),
              text: $model.deepgramLanguage
            )
            .textFieldStyle(.roundedBorder)
          }
        }
        .disabled(
          model.deepgramAudioTestState != .idle
            || model.hasUnavailableScalarSettings(in: .deepgram)
        )
      }
    } header: {
      settingsSectionHeader(.speech)
    } footer: {
      Text(UIStrings.text(.settingsSpeechEngineDescription, language: model.language))
    }
  }

  private var localDataAndRetentionSection: some View {
    Section {
      Picker(
        L10n.historySettingsText(.clipboardRetention, language: model.language),
        selection: Binding(
          get: { model.clipboardHistoryRetentionPeriod },
          set: { model.setClipboardHistoryRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Picker(
        L10n.historySettingsText(.runRetention, language: model.language),
        selection: Binding(
          get: { model.runHistoryRetentionPeriod },
          set: { model.setRunHistoryRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Divider()

      Toggle(
        L10n.string(.settingsFailedAudioRecovery, language: model.language),
        isOn: Binding(
          get: { model.failedAudioRecoveryEnabled },
          set: { model.setFailedAudioRecoveryEnabled($0) }
        )
      )
      .disabled(
        model.isLoadingSettings
          || model.isUpdatingFailedAudioRecovery
          || !model.retryingFailedAudioRecoveryIDs.isEmpty
      )

      Text(
        L10n.string(
          .settingsFailedAudioRecoveryDescription,
          language: model.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Button(
          L10n.string(
            .settingsFailedAudioRecoveryClear,
            language: model.language
          ),
          role: .destructive
        ) {
          destructiveConfirmation = .failedAudioRecovery
        }
        .disabled(
          model.failedAudioRecoveryReceipts.isEmpty
            || model.isUpdatingFailedAudioRecovery
            || !model.retryingFailedAudioRecoveryIDs.isEmpty
        )
        Spacer()
        if !model.failedAudioRecoveryReceipts.isEmpty {
          Text(
            model.language == .english
              ? "\(model.failedAudioRecoveryReceipts.count) encrypted"
              : "已加密 \(model.failedAudioRecoveryReceipts.count) 条"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if let error = model.failedAudioRecoveryError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button(
            L10n.historySettingsText(.clearClipboard, language: model.language),
            role: .destructive
          ) {
            destructiveConfirmation = .clipboardHistory
          }
          .disabled(
            localHistoryControlsDisabled || !model.isLocalHistoryMaintenanceAvailable
          )
          Spacer()
        }
        Text(
          L10n.historySettingsText(
            .preservedClipboardDetail,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button(
            L10n.historySettingsText(.clearRun, language: model.language),
            role: .destructive
          ) {
            destructiveConfirmation = .runHistory
          }
          .disabled(!model.canClearRunHistory || !model.isLocalHistoryMaintenanceAvailable)
          Spacer()
        }
        Text(
          L10n.historySettingsText(
            .preservedRunDetail,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.hasActiveOrQueuedVoiceRun {
          Text(L10n.historySettingsText(.runActiveHint, language: model.language))
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      if let error = model.historyRetentionSettingsError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.isLocalHistoryMaintenanceRunning {
        Label(
          L10n.historySettingsText(.maintenanceRunning, language: model.language),
          systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let pendingReason = model.localHistoryMaintenancePendingReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(pendingReason, systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)
          retryLocalHistoryMaintenanceButton
        }
      } else if let blockedReason = model.localHistoryMaintenanceBlockedReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(blockedReason, systemImage: "exclamationmark.octagon")
            .font(.caption)
            .foregroundStyle(.red)
          retryLocalHistoryMaintenanceButton
        }
      } else if model.lastLocalHistoryRemovedCount > 0
        || model.lastPreservedActiveClipboardCount > 0
      {
        Label(
          L10n.historyMaintenanceResult(
            removedCount: model.lastLocalHistoryRemovedCount,
            preservedActiveClipboardCount: model.lastPreservedActiveClipboardCount,
            language: model.language
          ),
          systemImage: "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } header: {
      settingsSectionHeader(.storage)
    } footer: {
      Text(L10n.historySettingsText(.description, language: model.language))
    }
  }

  private var localHistoryControlsDisabled: Bool {
    model.isLoadingSettings || model.isUpdatingHistoryRetentionSettings
      || model.isLocalHistoryMaintenanceRunning
  }

  private var retryLocalHistoryMaintenanceButton: some View {
    Button(L10n.historySettingsText(.retry, language: model.language)) {
      model.retryPendingLocalHistoryMaintenance()
    }
    .buttonStyle(.bordered)
    .disabled(
      localHistoryControlsDisabled || !model.isLocalHistoryMaintenanceAvailable
    )
  }

  private var preferredSpeechRoute: WorkflowEditorDraft.RecognizerChoice {
    model.preferredSpeechEngine == .local ? .localSpeech : .cloudSpeech
  }

  private var recoverableDeepgramFailureMessage: String? {
    guard let message = model.lastFailure?.trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty,
      hasDeepgramAPIKeyRecovery(for: message)
    else {
      return nil
    }
    return message
  }

  private func hasDeepgramAPIKeyRecovery(for message: String) -> Bool {
    L10n.hasDeepgramAPIKeyRecovery(for: message)
  }

  private var privacySection: some View {
    Section {
      if model.isLoadingPrivacySettings {
        Label(
          L10n.privacyText(.loading, language: model.language),
          systemImage: "hourglass"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if let loadError = model.privacySettingsLoadError {
        VStack(alignment: .leading, spacing: 6) {
          Label(loadError, systemImage: "exclamationmark.shield")
            .font(.caption)
            .foregroundStyle(.red)
          HStack {
            Button(L10n.privacyText(.retryLoad, language: model.language)) {
              model.retryPrivacySettingsLoad()
            }
            Button(
              L10n.privacyText(.resetSafeDefaults, language: model.language),
              role: .destructive
            ) {
              model.resetPrivacySettingsToSafeDefaults()
            }
          }
          .buttonStyle(.bordered)
          .disabled(model.isLoadingPrivacySettings)
        }
      }

      if let saveError = model.privacySettingsSaveError {
        VStack(alignment: .leading, spacing: 6) {
          Label(saveError, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
          Button(L10n.privacyText(.retrySave, language: model.language)) {
            model.retryPrivacySettingsSave()
          }
          .buttonStyle(.bordered)
        }
      } else if model.isSavingPrivacySettings {
        Label(
          L10n.privacyText(.saving, language: model.language),
          systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text(L10n.privacyText(PrivacySettingsTextKey.description, language: model.language))
        .font(.callout)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Button {
          guard let privacyNoticeDocument else { return }
          presentedSheet = .privacyNotice(privacyNoticeDocument)
        } label: {
          Label(
            L10n.privacyText(.technicalNotice, language: model.language),
            systemImage: "hand.raised.square"
          )
        }
        .disabled(privacyNoticeDocument == nil)
        .accessibilityIdentifier("settings.privacy.technical-notice")

        Text(
          L10n.privacyText(
            privacyNoticeDocument == nil
              ? .technicalNoticeUnavailable
              : .technicalNoticeDescription,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(privacyNoticeDocument == nil ? .red : .secondary)
      }

      Toggle(
        L10n.privacyText(PrivacySettingsTextKey.cloudConfirmation, language: model.language),
        isOn: Binding(
          get: { model.privacyPolicySettings.cloudConfirmationRequired },
          set: { model.setPrivacyCloudConfirmationRequired($0) }
        )
      )
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(
          PrivacySettingsTextKey.cloudConfirmationDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Toggle(
        L10n.privacyText(
          PrivacySettingsTextKey.secureInputConservativeMode, language: model.language),
        isOn: Binding(
          get: { model.privacyPolicySettings.secureInputConservativeMode },
          set: { model.setPrivacySecureInputConservativeMode($0) }
        )
      )
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(
          PrivacySettingsTextKey.secureInputConservativeDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Picker(
        L10n.privacyText(PrivacySettingsTextKey.historyPreviewMode, language: model.language),
        selection: Binding(
          get: { model.privacyPolicySettings.historyPreviewMode },
          set: { model.setPrivacyHistoryPreviewMode($0) }
        )
      ) {
        ForEach(PrivacyHistoryPreviewMode.allCases, id: \.rawValue) { mode in
          Text(L10n.privacySettingsHistoryPreviewMode(mode, language: model.language)).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(PrivacySettingsTextKey.historyPreviewDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(L10n.privacyText(PrivacySettingsTextKey.sensitiveApps, language: model.language))
            .font(.subheadline.weight(.medium))
          Spacer()
          Button(L10n.privacyText(.restoreRecommended, language: model.language)) {
            restoreRecommendedSensitiveAppRules()
          }
          .buttonStyle(.bordered)
          .disabled(privacySettingsControlsDisabled)
        }
        Text(
          L10n.privacyText(
            PrivacySettingsTextKey.sensitiveAppsDescription, language: model.language)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      sensitiveAppRuleEditor
        .disabled(privacySettingsControlsDisabled)

      ForEach(model.privacyPolicySettings.sensitiveAppRules) { rule in
        sensitiveAppRuleRow(rule)
          .disabled(privacySettingsControlsDisabled)
      }
    } header: {
      settingsSectionHeader(.privacy)
    }
  }

  private var privacySettingsControlsDisabled: Bool {
    model.isLoadingPrivacySettings || model.privacySettingsLoadError != nil
  }

  private var sensitiveAppRuleEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        L10n.privacyText(.bundleIdentifier, language: model.language),
        text: $sensitiveAppBundleIdentifier
      )
      .textFieldStyle(.roundedBorder)

      TextField(
        L10n.privacyText(.applicationNameOptional, language: model.language),
        text: $sensitiveAppApplicationName
      )
      .textFieldStyle(.roundedBorder)

      if let sensitiveAppRuleError {
        Label(sensitiveAppRuleError, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        if editingSensitiveAppRuleID != nil {
          Button(L10n.privacyText(.cancelEdit, language: model.language)) {
            resetSensitiveAppRuleEditor()
          }
        }
        Button(
          L10n.privacyText(
            editingSensitiveAppRuleID == nil ? .addRule : .saveRule,
            language: model.language
          )
        ) {
          saveSensitiveAppRule()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 4)
  }

  private func sensitiveAppRuleRow(_ rule: SensitiveAppRule) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        L10n.privacyText(PrivacySettingsTextKey.ruleEnabled, language: model.language),
        isOn: Binding(
          get: { sensitiveAppRule(rule.id)?.enabled ?? rule.enabled },
          set: { model.setSensitiveAppRuleEnabled(rule.id, isEnabled: $0) }
        )
      )
      .font(.subheadline.weight(.medium))

      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(rule.displayName)
            .font(.subheadline.weight(.medium))
          Text(rule.bundleIdentifier)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        if rule.isRecommended {
          Text(L10n.privacyText(.recommendedRule, language: model.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Button(L10n.privacyText(.editRule, language: model.language)) {
            beginEditingSensitiveAppRule(rule)
          }
          .buttonStyle(.borderless)
          Button(role: .destructive) {
            deleteSensitiveAppRule(rule)
          } label: {
            Text(L10n.privacyText(.deleteRule, language: model.language))
          }
          .buttonStyle(.borderless)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksClipboard, language: model.language),
          isOn: Binding(
            get: {
              sensitiveAppRule(rule.id)?.blocksClipboardHistory ?? rule.blocksClipboardHistory
            },
            set: { model.setSensitiveAppRuleBlocksClipboardHistory(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksWorkflow, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksWorkflowCapture ?? rule.blocksWorkflowCapture },
            set: { model.setSensitiveAppRuleBlocksWorkflowCapture(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksSelectedText, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksSelectedText ?? rule.blocksSelectedText },
            set: { model.setSensitiveAppRuleBlocksSelectedText(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksCloud, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksCloudProcessing ?? rule.blocksCloudProcessing },
            set: { model.setSensitiveAppRuleBlocksCloudProcessing(rule.id, blocks: $0) }
          )
        )
      }
      .toggleStyle(.checkbox)
      .font(.caption)
    }
    .padding(.vertical, 4)
  }

  private func sensitiveAppRule(_ ruleID: UUID) -> SensitiveAppRule? {
    model.privacyPolicySettings.sensitiveAppRules.first { $0.id == ruleID }
  }

  private func saveSensitiveAppRule() {
    do {
      let name = trimmedOptional(sensitiveAppApplicationName)
      if let editingSensitiveAppRuleID {
        try model.editSensitiveAppRule(
          editingSensitiveAppRuleID,
          bundleIdentifier: sensitiveAppBundleIdentifier,
          applicationName: name
        )
      } else {
        try model.addSensitiveAppRule(
          bundleIdentifier: sensitiveAppBundleIdentifier,
          applicationName: name
        )
      }
      resetSensitiveAppRuleEditor()
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  private func beginEditingSensitiveAppRule(_ rule: SensitiveAppRule) {
    editingSensitiveAppRuleID = rule.id
    sensitiveAppBundleIdentifier = rule.bundleIdentifier
    sensitiveAppApplicationName = rule.applicationName ?? ""
    sensitiveAppRuleError = nil
  }

  private func deleteSensitiveAppRule(_ rule: SensitiveAppRule) {
    do {
      try model.deleteSensitiveAppRule(rule.id)
      if editingSensitiveAppRuleID == rule.id {
        resetSensitiveAppRuleEditor()
      }
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  private func restoreRecommendedSensitiveAppRules() {
    do {
      try model.restoreRecommendedSensitiveAppRules()
      sensitiveAppRuleError = nil
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  private func resetSensitiveAppRuleEditor() {
    editingSensitiveAppRuleID = nil
    sensitiveAppBundleIdentifier = ""
    sensitiveAppApplicationName = ""
    sensitiveAppRuleError = nil
  }

  private func localizedSensitiveAppRuleError(_ error: Error) -> String {
    guard let validationError = error as? SensitiveAppRuleValidationError else {
      return model.language == .english
        ? "The privacy rule could not be updated. Review the rule and retry."
        : "无法更新隐私规则。请检查规则后重试。"
    }
    let key: PrivacySettingsTextKey
    switch validationError {
    case .missingBundleIdentifier:
      key = .missingBundleIdentifier
    case .invalidBundleIdentifier:
      key = .invalidBundleIdentifier
    case .duplicateBundleIdentifier, .duplicateRuleIdentifier:
      key = .duplicateBundleIdentifier
    case .recommendedRuleCannotBeEdited:
      key = .recommendedRuleCannotBeEdited
    case .ruleNotFound:
      key = .ruleNotFound
    }
    return L10n.privacyText(key, language: model.language)
  }

  private var vocabularySection: some View {
    Section {
      if let vocabularyRulesError = model.vocabularyRulesError {
        settingsDomainLoadFailure(
          message: vocabularyRulesError,
          retryIdentifier: "settings.vocabulary.retry"
        )
      }

      VStack(alignment: .leading, spacing: 10) {
        Text(L10n.string(.vocabularyDescription, language: model.language))
          .font(.callout)
          .foregroundStyle(.secondary)

        Picker(L10n.string(.vocabularyKind, language: model.language), selection: $vocabularyKind) {
          ForEach(vocabularyRuleKinds, id: \.rawValue) { kind in
            Text(L10n.vocabularyRuleKind(kind, language: model.language)).tag(kind)
          }
        }
        .pickerStyle(.segmented)

        if vocabularyKind == .hotword {
          Label(
            L10n.string(.vocabularyHotwordBehavior, language: model.language),
            systemImage: "cloud"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        TextField(
          L10n.string(.vocabularyPattern, language: model.language),
          text: $vocabularyPattern
        )
        .textFieldStyle(.roundedBorder)

        if vocabularyKind == .mapping {
          TextField(
            L10n.string(.vocabularyReplacement, language: model.language),
            text: $vocabularyReplacement
          )
          .textFieldStyle(.roundedBorder)
        }

        HStack(spacing: 12) {
          if vocabularyKind == .mapping {
            Picker(
              L10n.string(.vocabularyMatchMode, language: model.language),
              selection: $vocabularyMatchMode
            ) {
              ForEach(vocabularyMatchModes, id: \.rawValue) { mode in
                Text(L10n.vocabularyMatchMode(mode, language: model.language)).tag(mode)
              }
            }
            .pickerStyle(.menu)
          }

          TextField(
            L10n.string(.vocabularyPriority, language: model.language),
            value: $vocabularyPriority,
            format: .number
          )
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 120)

          if vocabularyKind == .mapping {
            Toggle(
              L10n.string(.vocabularyCaseSensitive, language: model.language),
              isOn: $vocabularyCaseSensitive
            )
            .toggleStyle(.checkbox)
          }
        }

        DisclosureGroup(L10n.string(.vocabularyScope, language: model.language)) {
          VStack(alignment: .leading, spacing: 8) {
            TextField(
              L10n.string(.vocabularySourceApp, language: model.language),
              text: $vocabularyBundleIdentifier
            )
            .textFieldStyle(.roundedBorder)

            Picker(
              L10n.string(.vocabularyAnyGroup, language: model.language),
              selection: $vocabularyGroupID
            ) {
              Text(L10n.string(.vocabularyAnyGroup, language: model.language)).tag(nil as UUID?)
              ForEach(vocabularyGroupChoices, id: \.group.id) { summary in
                Text(summary.group.name).tag(summary.group.id as UUID?)
              }
            }
            .pickerStyle(.menu)

            TextField(
              L10n.string(.vocabularyLocale, language: model.language),
              text: $vocabularyLocale,
              prompt: Text(L10n.string(.vocabularyAnyLocale, language: model.language))
            )
            .textFieldStyle(.roundedBorder)
          }
          .padding(.top, 6)
        }

        HStack {
          Spacer()
          Button(L10n.string(.vocabularyAddRule, language: model.language)) {
            addVocabularyRule()
          }
          .disabled(vocabularyPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .disabled(!model.areVocabularyRulesAvailable)

      if model.areVocabularyRulesAvailable && model.vocabularyRules.isEmpty {
        Text(L10n.string(.vocabularyEmpty, language: model.language))
          .foregroundStyle(.secondary)
      } else if model.areVocabularyRulesAvailable {
        ForEach(model.vocabularyRules) { rule in
          vocabularyRuleRow(rule)
        }
      }
    } header: {
      settingsSectionHeader(.vocabulary)
    }
    .disabled(model.isLoadingSettings)
  }

  private func settingsDomainLoadFailure(
    message: String,
    retryIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)
      Button(L10n.historySettingsText(.retry, language: model.language)) {
        model.retryUnavailableStoredSettingsDomains()
      }
      .buttonStyle(.bordered)
      .disabled(model.isRetryingUnavailableSettingsDomains)
      .accessibilityIdentifier(retryIdentifier)
    }
  }

  private var vocabularyRuleKinds: [VocabularyRuleKind] {
    [.hotword, .mapping]
  }

  private var vocabularyMatchModes: [VocabularyMatchMode] {
    [.exactPhrase, .wordBoundary, .regex]
  }

  private var vocabularyGroupChoices: [ClipboardGroupSummary] {
    var summaries = [model.clipboardDefaultGroup]
    summaries.append(
      contentsOf: model.clipboardGroups.filter {
        $0.group.id != model.clipboardDefaultGroup.group.id
      })
    return summaries
  }

  private func vocabularyRuleRow(_ rule: VocabularyRule) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        UIStrings.targetedAccessibilityLabel(
          .vocabularyRule,
          target: vocabularyRuleTitle(rule),
          language: model.language
        ),
        isOn: Binding(
          get: { rule.enabled },
          set: { model.setVocabularyRuleEnabled(rule.id, isEnabled: $0) }
        )
      )
      .labelsHidden()
      .accessibilityIdentifier("vocabulary.rule.\(rule.id.uuidString).enabled")

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(L10n.vocabularyRuleKind(rule.kind, language: model.language))
            .font(.caption.weight(.semibold))
          if rule.kind == .mapping {
            Text(L10n.vocabularyMatchMode(rule.matchMode, language: model.language))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(vocabularyRuleTitle(rule))
          .font(.subheadline.weight(.medium))

        Text(vocabularyScopeSummary(rule.scope))
          .font(.caption)
          .foregroundStyle(.secondary)

        if rule.kind == .hotword {
          Text(L10n.string(.vocabularyHotwordBehavior, language: model.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Button(role: .destructive) {
        model.deleteVocabularyRule(rule.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        UIStrings.targetedAccessibilityLabel(
          .vocabularyDeleteRule,
          target: vocabularyRuleTitle(rule),
          language: model.language
        )
      )
      .accessibilityIdentifier("vocabulary.rule.\(rule.id.uuidString).delete")
    }
  }

  private func vocabularyRuleTitle(_ rule: VocabularyRule) -> String {
    if rule.kind == .mapping, !rule.replacement.isEmpty {
      return "\(rule.pattern) → \(rule.replacement)"
    }
    return rule.pattern
  }

  private func vocabularyScopeSummary(_ scope: VocabularyRuleScope) -> String {
    L10n.vocabularyScopeSummary(
      scope,
      groupName: vocabularyGroupName(scope.clipboardGroupID),
      language: model.language
    )
  }

  private func vocabularyGroupName(_ groupID: UUID?) -> String? {
    guard let groupID else { return nil }
    return vocabularyGroupChoices.first(where: { $0.group.id == groupID })?.group.name
  }

  private func addVocabularyRule() {
    model.addVocabularyRule(
      kind: vocabularyKind,
      pattern: vocabularyPattern,
      replacement: vocabularyKind == .mapping ? vocabularyReplacement : "",
      matchMode: vocabularyMatchMode,
      caseSensitive: vocabularyCaseSensitive,
      scope: VocabularyRuleScope(
        bundleIdentifier: trimmedOptional(vocabularyBundleIdentifier),
        clipboardGroupID: vocabularyGroupID,
        locale: trimmedOptional(vocabularyLocale)
      ),
      priority: vocabularyPriority
    )
    vocabularyPattern = ""
    vocabularyReplacement = ""
    vocabularyPriority = 0
  }

  private func trimmedOptional(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var builtinPushToTalkSection: some View {
    Section {
      if model.hasUnavailableScalarSettings(in: .input) {
        unavailableScalarSettingsWarning(.input)
      }

      Toggle(
        L10n.string(.settingsLongRecordingMode, language: model.language),
        isOn: Binding(
          get: { model.longRecordingModeEnabled },
          set: { model.setLongRecordingModeEnabled($0) }
        )
      )
      .disabled(!model.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsLongRecordingModeDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        UIStrings.text(.builtinPushToTalkOutputMode, language: model.language),
        selection: Binding(
          get: { model.builtinPushToTalkOutputMode },
          set: { model.setBuiltinPushToTalkOutputMode($0) }
        )
      ) {
        ForEach(BuiltinPushToTalkOutputMode.allCases) { mode in
          Text(UIStrings.builtinPushToTalkOutputMode(mode, language: model.language)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!model.canMutateScalarSettings(in: .input))
    } header: {
      settingsSectionHeader(.input)
    } footer: {
      Text(UIStrings.text(.settingsBuiltinPushToTalkDescription, language: model.language))
    }
  }

  private func permissionColor(_ tone: SettingsPermissionTone) -> Color {
    switch tone {
    case .success: return .green
    case .secondary: return .secondary
    case .warning: return .orange
    case .error: return .red
    }
  }
}
