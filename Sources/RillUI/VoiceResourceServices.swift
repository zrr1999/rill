import Foundation
import RillCore

public struct VoiceResourceServices: Sendable {
  let prepareWakeWordModel: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> String
  let selectTTSModel: @Sendable (String) -> Void
  let downloadedTTSModelIdentifiers: Set<String>
  let validateWakeWordConfiguration: @Sendable (WakeWordConfiguration) async throws -> Void
  let stopSpeechPlayback: @MainActor @Sendable () -> Bool

  public init(
    prepareWakeWordModel:
      @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> String,
    selectTTSModel: @escaping @Sendable (String) -> Void,
    downloadedTTSModelIdentifiers: Set<String>,
    validateWakeWordConfiguration: @escaping @Sendable (WakeWordConfiguration) async throws -> Void,
    stopSpeechPlayback: @escaping @MainActor @Sendable () -> Bool
  ) {
    self.prepareWakeWordModel = prepareWakeWordModel
    self.selectTTSModel = selectTTSModel
    self.downloadedTTSModelIdentifiers = downloadedTTSModelIdentifiers
    self.validateWakeWordConfiguration = validateWakeWordConfiguration
    self.stopSpeechPlayback = stopSpeechPlayback
  }
}
