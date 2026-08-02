import RillCore

public enum VoiceAssistantLLMReadiness: Sendable, Equatable {
  case notRequired
  case loading
  case credentialMissing
  case credentialInaccessible
  case configurationInvalid
  case configured
  case verifying
  case verified
  case verificationFailed(OpenAIVerificationFailure?)

  public var permitsListening: Bool {
    switch self {
    case .notRequired, .configured, .verified:
      true
    case .loading,
      .credentialMissing,
      .credentialInaccessible,
      .configurationInvalid,
      .verifying,
      .verificationFailed:
      false
    }
  }
}

public enum VoiceAssistantPrivacyReadiness: Sendable, Equatable {
  case notRequired
  case loading
  case unavailable
  case ready(cloudConfirmationRequired: Bool)

  public var permitsListening: Bool {
    switch self {
    case .notRequired, .ready:
      true
    case .loading, .unavailable:
      false
    }
  }
}

public enum VoiceAssistantSpeechOutputReadiness: Sendable, Equatable {
  case notRequired
  case localVoice
  case preparingLocalVoice
  case systemFallback
}

/// A presentation and activation projection for the built-in assistant.
/// Runtime privacy authorization and provider validation remain authoritative
/// for every run; this state prevents a known-incomplete setup from starting
/// continuous listening in the first place.
public struct VoiceAssistantReadiness: Sendable, Equatable {
  public var microphone: PermissionState
  public var localSpeech: VoiceAssistantResourceState
  public var llm: VoiceAssistantLLMReadiness
  public var privacy: VoiceAssistantPrivacyReadiness
  public var speechOutput: VoiceAssistantSpeechOutputReadiness

  public init(
    microphone: PermissionState,
    localSpeech: VoiceAssistantResourceState,
    llm: VoiceAssistantLLMReadiness,
    privacy: VoiceAssistantPrivacyReadiness,
    speechOutput: VoiceAssistantSpeechOutputReadiness
  ) {
    self.microphone = microphone
    self.localSpeech = localSpeech
    self.llm = llm
    self.privacy = privacy
    self.speechOutput = speechOutput
  }

  public var isLocalSpeechReady: Bool {
    if case .ready = localSpeech { return true }
    return false
  }

  public var canEnableListening: Bool {
    microphone == .granted
      && isLocalSpeechReady
      && llm.permitsListening
      && privacy.permitsListening
  }
}
