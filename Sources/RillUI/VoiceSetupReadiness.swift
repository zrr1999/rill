import Foundation
import RillCore

public enum VoiceSetupProviderReadiness: Sendable, Equatable {
  case loading
  case localPreparing(progress: Double)
  case localReady
  case localUnavailable(LocalSpeechAvailability)
  case localPreviouslyPrepared
  case localNeedsPreparation(downloadIfNeeded: Bool)
  case localPreparationFailed
  public var isReady: Bool {
    switch self {
    case .localReady:
      return true
    case .loading,
      .localPreparing,
      .localUnavailable,
      .localPreviouslyPrepared,
      .localNeedsPreparation,
      .localPreparationFailed:
      return false
    }
  }
}

public enum VoiceSetupPrivacyReadiness: Sendable, Equatable {
  case loading
  case available(cloudConfirmationRequired: Bool)
  case unavailable

  public var isAvailable: Bool {
    if case .available = self {
      return true
    }
    return false
  }
}

public struct VoiceSetupReadiness: Sendable, Equatable {
  public var globalInput: GlobalInputCapability
  public var microphone: PermissionState
  public var accessibility: PermissionState
  public var accessibilityRequired: Bool
  public var preferredSpeechEngine: PreferredSpeechEngine
  public var provider: VoiceSetupProviderReadiness
  public var privacy: VoiceSetupPrivacyReadiness

  public init(
    globalInput: GlobalInputCapability,
    microphone: PermissionState,
    accessibility: PermissionState,
    accessibilityRequired: Bool,
    preferredSpeechEngine: PreferredSpeechEngine,
    provider: VoiceSetupProviderReadiness,
    privacy: VoiceSetupPrivacyReadiness
  ) {
    self.globalInput = globalInput
    self.microphone = microphone
    self.accessibility = accessibility
    self.accessibilityRequired = accessibilityRequired
    self.preferredSpeechEngine = preferredSpeechEngine
    self.provider = provider
    self.privacy = privacy
  }

  public var isComplete: Bool {
    globalInput.isAvailable
      && microphone == .granted
      && (!accessibilityRequired || accessibility == .granted)
      && provider.isReady
      && privacy.isAvailable
  }
}

extension AppModel {
  public var voiceSetupReadiness: VoiceSetupReadiness {
    VoiceSetupReadiness(
      globalInput: globalInputCapability,
      microphone: permissionSnapshot.microphone,
      accessibility: permissionSnapshot.accessibility,
      accessibilityRequired:
        self.settings.builtinPushToTalkOutputMode == .pasteIntoApp
        || hasEnabledCursorLivePreview,
      preferredSpeechEngine: self.settings.preferredSpeechEngine,
      provider: voiceSetupProviderReadiness,
      privacy: voiceSetupPrivacyReadiness
    )
  }

  private var hasEnabledCursorLivePreview: Bool {
    workflowLibrary.workflows.contains { workflow in
      isWorkflowEnabled(workflow)
        && workflow.livePreviewIsEnabled
        && workflow.resolvedLivePreviewPlacement == .cursor
    }
  }

  private var voiceSetupProviderReadiness: VoiceSetupProviderReadiness {
    guard !settings.isLoading else { return .loading }

    guard localSpeechAvailability.isAvailable else {
      return .localUnavailable(localSpeechAvailability)
    }
    if !trustedLocalSpeechModels.isEmpty {
      return trustedModelPoolReadiness
    }
    switch self.voice.localSpeechPreparationState {
    case .preparing:
      return .localPreparing(progress: self.voice.localSpeechPreparationProgress)
    case .ready:
      return .localReady
    case .idle:
      if self.voice.localSpeechPreparationError != nil {
        return .localPreparationFailed
      }
      if hasRecordedPreparationForSelectedLocalModel {
        return .localPreviouslyPrepared
      }
      return .localNeedsPreparation(downloadIfNeeded: true)
    }
  }

  /// Trusted-model (model pool) readiness. Pool models are prepared by the
  /// enable/resident synchronization rather than the legacy warm-up path, so
  /// a recorded preparation plus pool membership is sufficient — the user
  /// must not be asked to re-confirm after every relaunch.
  private var trustedModelPoolReadiness: VoiceSetupProviderReadiness {
    switch self.voice.localSpeechPreparationState {
    case .preparing:
      return .localPreparing(progress: self.voice.localSpeechPreparationProgress)
    case .ready:
      return .localReady
    case .idle:
      if self.voice.localSpeechPreparationError != nil {
        return .localPreparationFailed
      }
      let selected = selectedTrustedLocalSpeechModelIdentifier
      guard !selected.isEmpty else {
        return .localNeedsPreparation(downloadIfNeeded: true)
      }
      if self.settings.enabledSpeechModelIDs.contains(selected),
        self.voice.downloadedLocalSpeechModels.contains(selected)
      {
        return .localReady
      }
      return .localNeedsPreparation(downloadIfNeeded: true)
    }
  }

  private var voiceSetupPrivacyReadiness: VoiceSetupPrivacyReadiness {
    if settings.isLoadingPrivacySettings {
      return .loading
    }
    if settings.privacySettingsLoadError != nil {
      return .unavailable
    }
    return .available(
      cloudConfirmationRequired: settings.privacyPolicySettings.cloudConfirmationRequired
    )
  }

  private var hasRecordedPreparationForSelectedLocalModel: Bool {
    let selectedModel = self.settings.localSpeechModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if selectedModel.isEmpty {
      return self.voice.downloadedLocalSpeechModels.contains {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
    return self.voice.downloadedLocalSpeechModels.contains(selectedModel)
  }
}
