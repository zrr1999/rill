import CryptoKit
import Foundation
import RillCore

/// Session-only policy, cache and task owner. UI revocation is synchronous.
@MainActor
public final class HotwordSelection {
  public enum Status: String, Sendable {
    case disabled, ineligible, privacy, hit, miss, unavailable
  }

  public struct Selection: Sendable {
    public let terms: [String]
    public let status: Status
    public let preparation: HotwordRankingPreparation?
  }

  private struct CacheEntry {
    let terms: [String]
    let expires: Date
    var access: UInt64
  }

  private struct Identity: Encodable {
    let request: HotwordRankingRequest
    let workflow: WorkflowDefinition
    let collections: [VocabularyCollection]
    let candidates: [HotwordCandidate]
    let bundleIdentifier: String?
    let selectionDigest: String
    let language: String?
    let model: String
    let authorization: UUID
    let privacy: PrivacyPolicySettings
    let privacyRevision: UInt64
    let rubric = HotwordRankingPolicy.version
  }

  private let provider: any HotwordRankingProvider
  private let settings: JevSessionSettingsSource
  private let privacy: PrivacyPolicySettingsSource
  private let currentFocus: @MainActor @Sendable () -> FocusSnapshot
  private let now: @Sendable () -> Date
  private let timeout: Duration
  private let operations = BoundedOperation(maxConcurrentOperations: 1)
  private let report: @Sendable (DiagnosticEvent) async -> Void
  private var authorization: UUID?
  private var credential: JevSessionSettingsSource.Authorization?
  private var cache: [String: CacheEntry] = [:]
  private var access: UInt64 = 0
  private var preparations: [UUID: HotwordRankingPreparation] = [:]
  private var activeKey: String?
  private var lastPrivacy: PrivacyPolicySettingsSource.Snapshot?
  private var closed = false

  public init(provider: any HotwordRankingProvider, settings: JevSessionSettingsSource, privacy: PrivacyPolicySettingsSource,
    currentFocus: @escaping @MainActor @Sendable () -> FocusSnapshot,
    report: @escaping @Sendable (DiagnosticEvent) async -> Void = { _ in },
    now: @escaping @Sendable () -> Date = Date.init, timeout: Duration = .seconds(2)) {
    self.provider = provider
    self.settings = settings
    self.privacy = privacy
    self.currentFocus = currentFocus
    self.report = report
    self.now = now
    self.timeout = timeout
  }

  public func configure(isEnabled: Bool) {
    invalidate()
    credential = !closed && isEnabled ? settings.rankingAuthorization() : nil
    authorization = credential == nil ? nil : UUID()
  }

  public func select(runID: UUID, workflow: WorkflowDefinition, collections: [VocabularyCollection],
    context: ContextSnapshot, options: SpeechRecognitionRequestOptions, candidates: [HotwordCandidate],
    lifetime: AudioCaptureLifetime) throws -> Selection {
    let fallback = candidates.map(\.term)
    guard !closed, let authorization, credentialIsCurrent else {
      configure(isEnabled: false)
      return Selection(terms: fallback, status: .disabled, preparation: nil)
    }
    guard !candidates.isEmpty, candidates.count <= 50, let model = options.modelID else {
      return Selection(terms: fallback, status: .ineligible, preparation: nil)
    }
    guard let policy = permittedPolicy(for: context.focus) else {
      invalidate()
      return Selection(terms: fallback, status: .privacy, preparation: nil)
    }
    if lastPrivacy != policy { invalidate(); lastPrivacy = policy }
    let request = HotwordRankingRequest(application: context.focus.applicationName ?? "",
      workflow: workflow.name, selectedText: context.focus.selectedText, candidates: fallback)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let key = Self.digest(try encoder.encode(Identity(request: request, workflow: workflow,
      collections: collections, candidates: candidates, bundleIdentifier: context.focus.bundleIdentifier,
      selectionDigest: Self.digest(Data(context.focus.selectedText.utf8)), language: options.language,
      model: model, authorization: authorization, privacy: policy.settings, privacyRevision: policy.revision)))
    cache = cache.filter { $0.value.expires > now() }
    access &+= 1
    if var cached = cache[key] {
      cached.access = access
      cache[key] = cached
      return Selection(terms: cached.terms, status: .hit, preparation: nil)
    }
    preparations = preparations.filter { !$0.value.isFinished }
    var focus = context.focus
    focus.selectedText = ""
    let sourceFocus = focus
    let preparation = HotwordRankingPreparation { [weak self] in
      await self?.warm(key: key, runID: runID, request: request, candidates: candidates,
        authorization: authorization, policy: policy, focus: sourceFocus, lifetime: lifetime)
    }
    preparations[runID] = preparation
    return Selection(terms: fallback, status: .miss, preparation: preparation)
  }

  private func warm(key: String, runID: UUID, request: HotwordRankingRequest,
    candidates: [HotwordCandidate], authorization: UUID, policy: PrivacyPolicySettingsSource.Snapshot,
    focus: FocusSnapshot, lifetime: AudioCaptureLifetime) async {
    guard !Task.isCancelled, !closed, activeKey == nil,
      self.authorization == authorization, lifetime.isActive,
      permittedPolicy(for: focus) == policy else { return }
    if let cached = cache[key], cached.expires > now() { return }
    activeKey = key
    defer { activeKey = nil }
    guard let credential, settings.isCurrent(credential) else { return }
    let start = ContinuousClock.now
    // Privacy changes and capture cancellation also interrupt a blocked network call.
    let monitor = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        guard let self, self.authorization == authorization else { return }
        guard self.credentialIsCurrent else {
          self.configure(isEnabled: false)
          return
        }
        if self.permittedPolicy(for: focus) != policy
          || Self.wasRevoked(lifetime) {
          self.invalidate()
          return
        }
      }
    }
    defer { monitor.cancel() }
    var outcome = "ready"
    do {
      let scores = try await operations.run(timeout: timeout) { [self, provider] in
        guard await permitsRequest(authorization: authorization, policy: policy,
          focus: focus, lifetime: lifetime) else { throw CancellationError() }
        return try await provider.score(request, apiKey: credential.apiKey)
      }
      try Task.checkCancellation()
      guard !closed, self.authorization == authorization, credentialIsCurrent, !Self.wasRevoked(lifetime),
        permittedPolicy(for: focus) == policy else { return }
      let terms = try HotwordRankingPolicy.ranked(candidates, scores: scores)
      access &+= 1
      cache[key] = CacheEntry(terms: terms, expires: now().addingTimeInterval(300), access: access)
      if cache.count > 32, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
        cache.removeValue(forKey: oldest)
      }
    } catch is CancellationError {
      outcome = "cancelled"
    } catch OperationDeadlineError.timedOut {
      outcome = "timeout"
    } catch {
      outcome = "unavailable"
    }
    let elapsed = start.duration(to: .now).components
    let millis = max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    await report(DiagnosticEvent(runID: runID, subsystem: .session, level: .debug,
      event: "hotword-ranking.completed", message: "Hotword ranking completed.",
      metadata: ["hotwordRankingOutcome": outcome, "hotwordCandidateCount": String(candidates.count),
        "durationMillis": String(millis)]))
  }

  private func permittedPolicy(for source: FocusSnapshot) -> PrivacyPolicySettingsSource.Snapshot? {
    guard let policy = try? privacy.currentSnapshot() else { return nil }
    let current = currentFocus()
    guard source.bundleIdentifier != nil, current.bundleIdentifier == source.bundleIdentifier,
      current.processIdentifier == source.processIdentifier else { return nil }
    for focus in [source, current] {
      let context = ContextSnapshot(focus: focus, clipboard: .init(plainText: "", changeCount: 0))
      let decision = PrivacyPolicy.evaluate(context: context, processingDestinations: [.cloudText], settings: policy.settings)
      guard !focus.secureInput, !decision.blocksCloudProcessing, decision.allowsWorkflowCapture,
        !decision.reasons.contains(.unknownFocusContext),
        !decision.redactedPromptVariables.contains(.selected)
      else { return nil }
    }
    // The separate, session-only switch is the explicit consent for this destination and payload.
    return policy
  }

  private func permitsRequest(authorization: UUID, policy: PrivacyPolicySettingsSource.Snapshot,
    focus: FocusSnapshot, lifetime: AudioCaptureLifetime) -> Bool {
    !closed && self.authorization == authorization && credentialIsCurrent && !Self.wasRevoked(lifetime)
      && permittedPolicy(for: focus) == policy
  }

  private func invalidate() {
    cache.removeAll()
    for preparation in preparations.values { preparation.cancel() }
  }

  private var credentialIsCurrent: Bool {
    credential.map { settings.isCurrent($0) } ?? false
  }

  public func shutdown() async {
    closed = true
    configure(isEnabled: false)
    let pending = Array(preparations.values)
    for preparation in pending { await preparation.wait() }
    await operations.shutdown()
    preparations.removeAll()
  }

  private static func wasRevoked(_ lifetime: AudioCaptureLifetime) -> Bool {
    if case .revoked = lifetime.state { return true }
    return false
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// A run can start warming only after microphone admission; cancellation works before or after start.
public final class HotwordRankingPreparation: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (@Sendable () async -> Void)?
  private var task: Task<Void, Never>?
  private var finished = false

  init(action: @escaping @Sendable () async -> Void) { self.action = action }

  public var isFinished: Bool { lock.withLock { finished } }

  public func recordingStarted() {
    lock.withLock {
      guard let action, !finished else { return }
      self.action = nil
      task = Task { [weak self] in
        if !Task.isCancelled { await action() }
        self?.lock.withLock { self?.finished = true }
      }
    }
  }

  public func cancel() {
    lock.withLock {
      action = nil
      task?.cancel()
      if task == nil { finished = true }
    }
  }

  public func wait() async {
    let pending = lock.withLock { task }
    await pending?.value
  }
}
