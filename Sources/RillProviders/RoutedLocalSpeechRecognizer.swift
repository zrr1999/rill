import Foundation
import RillCore

public protocol LocalSpeechBackendRecognizer: SpeechRecognizer {
  var backend: LocalSpeechModelBackend { get }

  func releaseLoadedModel() async throws
  func stopRuntime() async throws
}

/// Keeps the public local-recognizer identity stable while routing exact model
/// identities to isolated provider runtimes. Only one final-model backend is
/// retained at a time so a model switch cannot silently accumulate memory.
public actor RoutedLocalSpeechRecognizer: SpeechRecognizer {
  public nonisolated let id: String
  public nonisolated let capabilities = SpeechRecognizerCapabilities(
    supportedHintKinds: [.keyterm]
  )

  private let settingsProvider: @Sendable () async throws -> LocalSpeechSettings
  private let backends: [LocalSpeechModelBackend: any LocalSpeechBackendRecognizer]
  private var activeBackend: LocalSpeechModelBackend?

  public init(
    id: String = "local-speech",
    settingsProvider: @escaping @Sendable () async throws -> LocalSpeechSettings,
    backends: [any LocalSpeechBackendRecognizer]
  ) {
    var indexed: [LocalSpeechModelBackend: any LocalSpeechBackendRecognizer] = [:]
    for backend in backends {
      precondition(indexed.updateValue(backend, forKey: backend.backend) == nil)
    }
    self.id = id
    self.settingsProvider = settingsProvider
    self.backends = indexed
  }

  public func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    let settings = try await settingsProvider()
    let modelIdentifier = LocalSpeechModelCatalog.effectiveModelIdentifier(
      settings: settings,
      workflow: request.workflow
    )
    let backend = try LocalSpeechModelCatalog.backend(for: modelIdentifier)
    try await activate(backend)
    return try await recognizer(for: backend).recognize(request)
  }

  /// Retires a different final-model backend before an explicit preparation
  /// step can load the selected model into memory.
  public func prepareForUse(of backend: LocalSpeechModelBackend) async throws {
    try await activate(backend)
  }

  public func releaseLoadedModel() async throws {
    activeBackend = nil
    try await releaseBoth()
  }

  public func stopRuntime() async throws {
    activeBackend = nil
    var firstError: Error?
    for backend in LocalSpeechModelBackend.allCases {
      guard let recognizer = backends[backend] else { continue }
      do {
        try await recognizer.stopRuntime()
      } catch {
        if firstError == nil { firstError = error }
      }
    }
    if let firstError { throw firstError }
  }

  private func activate(_ backend: LocalSpeechModelBackend) async throws {
    guard activeBackend != backend else { return }
    if let activeBackend {
      try await recognizer(for: activeBackend).releaseLoadedModel()
    }
    _ = try recognizer(for: backend)
    activeBackend = backend
  }

  private func releaseBoth() async throws {
    var firstError: Error?
    for backend in LocalSpeechModelBackend.allCases {
      guard let recognizer = backends[backend] else { continue }
      do {
        try await recognizer.releaseLoadedModel()
      } catch {
        if firstError == nil { firstError = error }
      }
    }
    if let firstError { throw firstError }
  }

  private func recognizer(
    for backend: LocalSpeechModelBackend
  ) throws -> any LocalSpeechBackendRecognizer {
    guard let recognizer = backends[backend] else {
      throw LocalSpeechModelSelectionError.backendUnavailable(backend)
    }
    return recognizer
  }
}
