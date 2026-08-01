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
      accessibilityRequired: builtinPushToTalkOutputMode == .pasteIntoApp,
      preferredSpeechEngine: preferredSpeechEngine,
      provider: voiceSetupProviderReadiness,
      privacy: voiceSetupPrivacyReadiness
    )
  }

  private var voiceSetupProviderReadiness: VoiceSetupProviderReadiness {
    guard !isLoadingSettings else { return .loading }

    guard localSpeechAvailability.isAvailable else {
      return .localUnavailable(localSpeechAvailability)
    }
    switch localSpeechPreparationState {
    case .preparing:
      return .localPreparing(progress: localSpeechPreparationProgress)
    case .ready:
      return .localReady
    case .idle:
      if localSpeechPreparationError != nil {
        return .localPreparationFailed
      }
      if hasRecordedPreparationForSelectedLocalModel {
        return .localPreviouslyPrepared
      }
      return .localNeedsPreparation(downloadIfNeeded: true)
    }
  }

  private var voiceSetupPrivacyReadiness: VoiceSetupPrivacyReadiness {
    if isLoadingPrivacySettings {
      return .loading
    }
    if privacySettingsLoadError != nil {
      return .unavailable
    }
    return .available(
      cloudConfirmationRequired: privacyPolicySettings.cloudConfirmationRequired
    )
  }

  private var hasRecordedPreparationForSelectedLocalModel: Bool {
    let selectedModel = localSpeechModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if selectedModel.isEmpty {
      return downloadedLocalSpeechModels.contains {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
    return downloadedLocalSpeechModels.contains(selectedModel)
  }
}
