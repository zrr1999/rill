import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var voiceAssistantResourcesSection: some View {
    settingsDisclosure(.voiceAssistant) {
      voiceAssistantSetupOverview

      Divider()

      LabeledContent(
        L10n.settingsText(.settingsWakeWordListener, language: model.settings.language)
      ) {
        Text(wakeWordRuntimeStatusText)
          .foregroundStyle(wakeWordRuntimeStatusColor)
      }

      voiceResourceStatus(
        state: model.voice.wakeWordResourceState,
        readyText: L10n.settingsText(.settingsWakeWordASRReady, language: model.settings.language)
      )

      if voiceAssistantActionVisibility.showsWakeWordPreparation {
        Button(
          resourcePreparationButtonTitle(
            state: model.voice.wakeWordResourceState,
            resourceNameKey: .settingsLocalASRResourceName
          )
        ) {
          model.prepareWakeWordModel()
        }
        .accessibilityIdentifier("settings.wake-word.prepare")
      }

      Toggle(
        L10n.settingsText(.settingsEnableWakeWordListening, language: model.settings.language),
        isOn: Binding(
          get: { wakeListeningDraftEnabled },
          set: { requestWakeWordListening($0) }
        )
      )
      .disabled(
        isApplyingWakeWordSettings
          || (!wakeListeningDraftEnabled
            && !model.voiceAssistantReadiness.canEnableListening)
      )
      .accessibilityIdentifier("settings.wake-word.enabled")

      VStack(alignment: .leading, spacing: 5) {
        Text(L10n.settingsText(.settingsWakePhrasesTitle, language: model.settings.language))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        TextField(
          L10n.settingsText(.settingsWakePhrasesPlaceholder, language: model.settings.language),
          text: $wakePhrasesText,
          axis: .vertical
        )
        .lineLimit(1...4)
        .textFieldStyle(.roundedBorder)
        .focused($wakePhrasesFieldFocused)
        .disabled(isApplyingWakeWordSettings)
        .accessibilityIdentifier("settings.wake-word.phrases")

        HStack(spacing: 8) {
          Button(L10n.settingsText(.settingsSavePhrases, language: model.settings.language)) {
            applyWakeWordSettings(
              enableListening: wakeListeningDraftEnabled
            )
          }
          .disabled(isApplyingWakeWordSettings || !wakeWordModelIsReady)
          .accessibilityIdentifier("settings.wake-word.save")

          if isApplyingWakeWordSettings {
            ProgressView()
              .controlSize(.small)
              .transition(.opacity)
          }

          Spacer()

          if let workflowName = model.wakeWordSettingsSnapshot.workflowName {
            Text(L10n.settingsWorkflowName(workflowName, language: model.settings.language))
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }

      if let wakeWordSettingsError {
        Label(wakeWordSettingsError, systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
          .transition(.opacity)
      }

      Text(L10n.settingsText(.settingsWakeWordScopeDetail, language: model.settings.language))
      .font(.caption)
      .foregroundStyle(.secondary)

      Text(L10n.settingsText(.settingsWakeWordPrivacyDetail, language: model.settings.language))
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isApplyingWakeWordSettings)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: wakeWordSettingsError == nil)
    .onChange(of: model.wakeWordSettingsSnapshot) { _, snapshot in
      guard !isApplyingWakeWordSettings else { return }
      wakeListeningDraftEnabled = snapshot.isEnabled
      if !wakePhrasesFieldFocused {
        wakePhrasesText = snapshot.phrases.joined(separator: "\n")
      }
    }
  }

  @ViewBuilder
  func voiceResourceStatus(
    state: VoiceAssistantResourceState,
    readyText: String
  ) -> some View {
    switch state {
    case .notInstalled:
      Text(L10n.settingsText(.settingsResourceNotInstalled, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    case .preparing(let progress):
      if let progress, progress > 0 {
        HStack(spacing: 8) {
          ProgressView(value: progress)
          Text(progress, format: .percent.precision(.fractionLength(0)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 34, alignment: .trailing)
        }
      } else {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(L10n.settingsText(.settingsResourcePreparingDownload, language: model.settings.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    case .ready:
      Label(readyText, systemImage: RillSystemSymbol.checkmarkCircleFill.rawValue)
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
        .font(.caption)
        .foregroundStyle(.red)
    case .unavailable(let reason):
      Label(
        voiceResourceUnavailableText(reason),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .font(.caption)
      .foregroundStyle(.orange)
    }
  }

  var voiceAssistantActionVisibility: VoiceAssistantSettingsActionVisibility {
    VoiceAssistantSettingsActionVisibility(
      wakeWordState: model.voice.wakeWordResourceState,
      ttsState: model.voice.ttsResourceState,
      isSpeechPlaybackActive: model.voice.isSpeechPlaybackActive
    )
  }

  var voiceAssistantSetupOverview: some View {
    let readiness = model.voiceAssistantReadiness
    return VStack(alignment: .leading, spacing: 10) {
      Label(
        readiness.canEnableListening
          ? L10n.settingsText(.settingsAssistantSetupReady, language: model.settings.language)
          : L10n.settingsText(.settingsAssistantSetupIncomplete, language: model.settings.language),
        systemImage: readiness.canEnableListening
          ? RillSystemSymbol.checkmarkSealFill.rawValue
          : RillSystemSymbol.checklist.rawValue
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(readiness.canEnableListening ? .green : .primary)

      voiceAssistantReadinessRow(
        title: L10n.text(.microphone, language: model.settings.language),
        detail: microphoneReadinessDetail(readiness.microphone),
        isReady: readiness.microphone == .granted
      )
      voiceAssistantReadinessRow(
        title: L10n.settingsText(.settingsReadinessLocalRecognition, language: model.settings.language),
        detail: localSpeechReadinessDetail(readiness.localSpeech),
        isReady: readiness.isLocalSpeechReady
      )
      voiceAssistantReadinessRow(
        title: L10n.settingsText(.settingsReadinessLLMAnswer, language: model.settings.language),
        detail: llmReadinessDetail(readiness.llm),
        isReady: readiness.llm.permitsListening
      )
      voiceAssistantReadinessRow(
        title: L10n.settingsText(.settingsReadinessCloudPrivacy, language: model.settings.language),
        detail: privacyReadinessDetail(readiness.privacy),
        isReady: readiness.privacy.permitsListening
      )
      voiceAssistantReadinessRow(
        title: L10n.settingsText(.settingsReadinessSpeechOutput, language: model.settings.language),
        detail: speechOutputReadinessDetail(readiness.speechOutput),
        isReady: true
      )

      HStack(spacing: RillSpacing.row) {
        if readiness.microphone != .granted {
          Button(L10n.settingsText(.settingsReviewPermissions, language: model.settings.language)) {
            model.showSettings(.permissions)
          }
          .accessibilityIdentifier("settings.voice-assistant.review-permissions")
        }
        if readiness.llm != .notRequired,
          readiness.llm != .verified
        {
          Button(L10n.settingsText(.settingsConfigureVerifyLLM, language: model.settings.language)) {
            model.showSettings(.providers)
          }
          .accessibilityIdentifier("settings.voice-assistant.configure-llm")
        }
        if readiness.privacy == .unavailable {
          Button(L10n.settingsText(.settingsRepairPrivacySettings, language: model.settings.language)) {
            model.showSettings(.privacy)
          }
          .accessibilityIdentifier("settings.voice-assistant.repair-privacy")
        }
      }
      .buttonStyle(.bordered)
    }
    .padding(10)
    // RillCard prominent-tier fill at badge radius; padding stays manual.
    .background(
      .quaternary.opacity(RillCardProminence.prominent.fillOpacity),
      in: RoundedRectangle(cornerRadius: RillRadius.badge, style: .continuous)
    )
  }

  func voiceAssistantReadinessRow(
    title: String,
    detail: String,
    isReady: Bool
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: isReady ? RillSystemSymbol.checkmarkCircleFill.rawValue : RillSystemSymbol.circleDashed.rawValue)
        .foregroundStyle(isReady ? .green : .orange)
        .accessibilityHidden(true)
      Text(title)
        .font(.caption.weight(.medium))
      Spacer(minLength: 12)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  func microphoneReadinessDetail(_ state: PermissionState) -> String {
    L10n.microphoneReadinessDetail(state, language: model.settings.language)
  }

  func localSpeechReadinessDetail(
    _ state: VoiceAssistantResourceState
  ) -> String {
    L10n.localSpeechReadinessDetail(state, language: model.settings.language)
  }

  func llmReadinessDetail(_ state: VoiceAssistantLLMReadiness) -> String {
    L10n.llmReadinessDetail(state, language: model.settings.language)
  }

  func privacyReadinessDetail(
    _ state: VoiceAssistantPrivacyReadiness
  ) -> String {
    L10n.privacyReadinessDetail(state, language: model.settings.language)
  }

  func speechOutputReadinessDetail(
    _ state: VoiceAssistantSpeechOutputReadiness
  ) -> String {
    L10n.speechOutputReadinessDetail(state, language: model.settings.language)
  }

  var wakeWordModelIsReady: Bool {
    if case .ready = model.voice.wakeWordResourceState {
      return true
    }
    return false
  }

  var wakePhraseDraftValues: [String] {
    wakePhrasesText
      .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" })
      .map(String.init)
      .map(WakeWordConfiguration.normalizedPhrase)
      .filter { !$0.isEmpty }
  }

  func requestWakeWordListening(_ enabled: Bool) {
    wakeListeningDraftEnabled = enabled
    wakeWordSettingsError = nil
    if enabled {
      applyWakeWordSettings(enableListening: true)
    } else {
      model.disableWakeWordListening()
    }
  }

  func applyWakeWordSettings(enableListening: Bool) {
    guard !isApplyingWakeWordSettings else { return }
    isApplyingWakeWordSettings = true
    wakeWordSettingsError = nil
    let phrases = wakePhraseDraftValues
    Task { @MainActor in
      let result = await model.updateWakeWordSettings(
        phrases: phrases,
        enableListening: enableListening
      )
      isApplyingWakeWordSettings = false
      switch result {
      case .saved:
        let snapshot = model.wakeWordSettingsSnapshot
        wakeListeningDraftEnabled = snapshot.isEnabled
        wakePhrasesText = snapshot.phrases.joined(separator: "\n")
      case .failed(let message):
        wakeListeningDraftEnabled = model.wakeWordSettingsSnapshot.isEnabled
        wakeWordSettingsError = message
      }
    }
  }

  func resourcePreparationButtonTitle(
    state: VoiceAssistantResourceState,
    resourceNameKey: SettingsTextKey
  ) -> String {
    let resourceName = L10n.settingsText(resourceNameKey, language: model.settings.language)
    if case .failed = state {
      return L10n.settingsResourceRetryTitle(resourceName, language: model.settings.language)
    }
    return L10n.settingsResourceDownloadTitle(resourceName, language: model.settings.language)
  }

  func voiceResourceUnavailableText(
    _ reason: VoiceAssistantResourceUnavailableReason
  ) -> String {
    switch reason {
    case .distributionLicenseUnverified:
      return L10n.settingsText(.settingsVoiceResourceUnavailable, language: model.settings.language)
    }
  }

  var wakeWordRuntimeStatusText: String {
    L10n.wakeWordRuntimeStatus(model.voice.wakeWordRuntimeState, language: model.settings.language)
  }

  var wakeWordRuntimeStatusColor: Color {
    switch model.voice.wakeWordRuntimeState {
    case .listening:
      .green
    case .failed:
      .red
    case .starting, .suspended:
      .orange
    case .disabled, .modelMissing:
      .secondary
    }
  }

}
