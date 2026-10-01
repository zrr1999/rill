import SwiftUI
import RillCore

public struct VoiceSetupView: View {
  @Bindable private var model: AppModel

  public init(model: AppModel) { self.model = model }

  public var body: some View {
    let readiness = model.voiceSetupReadiness
    VStack(alignment: .leading, spacing: 14) {
      Label(
        L10n.text(.voiceSetupTitle, language: model.settings.language),
        systemImage: RillSystemSymbol.checklist.rawValue
      )
      .font(.headline)

      setupPermissionRows(readiness)
      if !readiness.provider.isReady {
        providerSetupRows(readiness.provider)
      }
      privacySetupRows(readiness)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .rillCard(.prominent)
  }

  @ViewBuilder
  private func setupPermissionRows(_ readiness: VoiceSetupReadiness) -> some View {
    if !readiness.globalInput.isAvailable {
      globalInputSetupRow(readiness.globalInput)
    }
    if readiness.microphone != .granted {
      permissionSetupRow(
        title: L10n.text(.microphone, language: model.settings.language),
        state: readiness.microphone,
        neededDetail: .voiceSetupMicrophoneNeeded,
        requestAction: model.requestMicrophonePermission,
        openSettingsAction: model.openMicrophoneSettings
      )
    }
    if readiness.accessibilityRequired, readiness.accessibility != .granted {
      permissionSetupRow(
        title: L10n.text(.accessibility, language: model.settings.language),
        state: readiness.accessibility,
        neededDetail: .voiceSetupAccessibilityNeeded,
        requestAction: model.requestAccessibilityPermission,
        openSettingsAction: model.openAccessibilitySettings
      )
    }
  }

  @ViewBuilder
  private func globalInputSetupRow(_ capability: GlobalInputCapability) -> some View {
    let title = L10n.text(.globalInput, language: model.settings.language)
    switch capability {
    case .checking:
      setupRow(
        title: title,
        detail: .voiceSetupGlobalInputChecking,
        symbol: RillSystemSymbol.hourglass.rawValue,
        color: .secondary
      )
    case .available:
      setupRow(
        title: title,
        detail: .voiceSetupGlobalInputReady,
        symbol: RillSystemSymbol.checkmarkCircleFill.rawValue,
        color: .green
      )
    case .permissionRequired:
      setupRow(
        title: title,
        detail: .voiceSetupGlobalInputPermissionNeeded,
        symbol: RillSystemSymbol.exclamationmarkCircleFill.rawValue,
        color: .orange,
        actionTitle: L10n.text(.requestAccess, language: model.settings.language),
        actionIdentifier: "stream.global-input.request",
        action: model.requestGlobalInputPermission
      )
    case .installationFailed:
      setupRow(
        title: title,
        detail: .voiceSetupGlobalInputInstallationFailed,
        symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
        color: .red,
        actionTitle: L10n.text(.retryGlobalInput, language: model.settings.language),
        actionIdentifier: "stream.global-input.retry",
        action: model.retryGlobalInputInstallation
      )
    }
  }

  @ViewBuilder
  private func permissionSetupRow(
    title: String,
    state: PermissionState,
    neededDetail: L10n.InterfaceKey,
    requestAction: @escaping () -> Void,
    openSettingsAction: @escaping () -> Void
  ) -> some View {
    if state == .unknown {
      setupRow(
        title: title,
        detail: neededDetail,
        symbol: RillSystemSymbol.exclamationmarkCircleFill.rawValue,
        color: .orange,
        actionTitle: L10n.text(.requestAccess, language: model.settings.language),
        action: requestAction
      )
    } else {
      setupRow(
        title: title,
        detail: neededDetail,
        symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
        color: .red,
        actionTitle: L10n.text(.openSettings, language: model.settings.language),
        action: openSettingsAction
      )
    }
  }

  @ViewBuilder
  private func providerSetupRows(_ state: VoiceSetupProviderReadiness) -> some View {
    switch state {
    case .loading:
      setupRow(
        title: L10n.text(.settingsSpeechEngine, language: model.settings.language),
        detail: .voiceSetupLoading,
        symbol: RillSystemSymbol.hourglass.rawValue,
        color: .secondary
      )
    case .localPreparing(let progress):
      VStack(alignment: .leading, spacing: 6) {
        setupRow(
          title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
          detail: .voiceSetupLocalPreparing,
          symbol: RillSystemSymbol.arrowDownCircleFill.rawValue,
          color: .blue
        )
        ProgressView(value: progress, total: 1)
          .controlSize(.small)
      }
    case .localReady:
      setupRow(
        title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
        detail: .voiceSetupLocalReady,
        symbol: RillSystemSymbol.checkmarkCircleFill.rawValue,
        color: .green
      )
    case .localUnavailable(let availability):
      setupRow(
        title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
        detail: availability == .architectureUnsupported
          ? .voiceSetupLocalArchitectureUnsupported
          : .voiceSetupLocalTrustMaterialUnavailable,
        symbol: RillSystemSymbol.exclamationmarkTriangleFill.rawValue,
        color: .red,
        actionTitle: L10n.text(.openSettings, language: model.settings.language),
        actionIdentifier: "stream.local-speech.open-settings",
        action: { model.showSettings(.speech) }
      )
    case .localPreviouslyPrepared:
      setupRow(
        title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
        detail: .voiceSetupLocalPreviouslyPrepared,
        symbol: RillSystemSymbol.questionmarkCircleFill.rawValue,
        color: .orange,
        actionTitle: L10n.text(.localSpeechPrepare, language: model.settings.language),
        action: model.prepareLocalSpeechModel
      )
    case .localNeedsPreparation(let downloadIfNeeded):
      setupRow(
        title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
        detail: downloadIfNeeded ? .voiceSetupLocalWillDownload : .voiceSetupLocalNeedsPreparation,
        symbol: RillSystemSymbol.arrowDownCircleFill.rawValue,
        color: .orange,
        actionTitle: L10n.text(.localSpeechPrepare, language: model.settings.language),
        action: model.prepareLocalSpeechModel
      )
    case .localPreparationFailed:
      setupRow(
        title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
        detail: .voiceSetupLocalFailed,
        symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
        color: .red,
        actionTitle: L10n.text(.openSettings, language: model.settings.language),
        actionIdentifier: "stream.local-speech.open-settings",
        action: { model.showSettings(.speech) }
      )
    }
  }

  @ViewBuilder
  private func privacySetupRows(_ readiness: VoiceSetupReadiness) -> some View {
    switch readiness.privacy {
    case .loading:
      setupRow(
        title: L10n.text(.permissions, language: model.settings.language),
        detail: .voiceSetupPrivacyLoading,
        symbol: RillSystemSymbol.lockCircle.rawValue,
        color: .secondary
      )
    case .unavailable:
      setupRow(
        title: L10n.text(.permissions, language: model.settings.language),
        detail: .voiceSetupPrivacyUnavailable,
        symbol: RillSystemSymbol.lockTrianglebadgeExclamationmark.rawValue,
        color: .red,
        actionTitle: L10n.text(.openSettings, language: model.settings.language),
        actionIdentifier: "stream.privacy.open-settings",
        action: { model.showSettings(.privacy) }
      )
    case .available:
      EmptyView()
    }
  }

  private func setupRow(
    title: String,
    detail: L10n.InterfaceKey,
    symbol: String,
    color: Color,
    actionTitle: String? = nil,
    actionIdentifier: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(L10n.text(detail, language: model.settings.language))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      if let actionTitle, let action {
        // Only stamp an identifier when one is provided; an empty
        // identifier is worse than none for accessibility queries.
        if let actionIdentifier {
          Button(actionTitle, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(actionIdentifier)
        } else {
          Button(actionTitle, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
    }
  }
}
