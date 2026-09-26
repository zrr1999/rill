import AppKit
import Carbon
import Foundation
import Observation
import RillCore
import RillInputMethodContracts
import RillInputMethodIPC
import RillKnowledge

@MainActor
@Observable
public final class InputMethodFeatureModel {
  public private(set) var state = TypingVocabularyState()
  public private(set) var isReady = false
  public private(set) var isInstalling = false
  public private(set) var installationState: InputMethodInstallationState = .notInstalled
  public private(set) var status: String?
  public private(set) var error: String?
  private let settings: any SettingsStore
  private let privacy: () throws -> PrivacyPolicySettings
  private let confirmRule: (String, UUID) async throws -> (UUID, Bool)
  private let revokeRule: (UUID) async throws -> Void
  private let ownedRuleIDs: () async throws -> Set<UUID>
  private let secureInputEnabled: () -> Bool
  private let install: (URL?) async throws -> String
  private let inspectInstallation: () -> InputMethodInstallationState
  private let enableInputSource: () throws -> String
  private let writes = PersistenceWriteCoordinator()
  private var loadTask: Task<Void, Never>?
  private var maintenance: Timer?
  private var channel: LocalInputMethodChannel?
  var makeChannel: (String) throws -> LocalInputMethodChannel = {
    try LocalInputMethodChannel(host: true, directory: $0)
  }
  private var policyRevision = UUID()
  private var publishedApplications: Set<String> = []
  private var seenEvents: Set<UUID> = []
  private var eventOrder: [UUID] = []
  private var stopped = false
  private var busyIDs: Set<UUID> = []
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
  private let bridgeDirectory: String

  public init(
    settings: any SettingsStore, privacy: @escaping () throws -> PrivacyPolicySettings,
    confirmRule: @escaping (String, UUID) async throws -> (UUID, Bool),
    revokeRule: @escaping (UUID) async throws -> Void,
    install: @escaping (URL?) async throws -> String,
    inspectInstallation: @escaping () -> InputMethodInstallationState = { .notInstalled },
    enableInputSource: @escaping () throws -> String = { throw CocoaError(.featureUnsupported) },
    ownedRuleIDs: @escaping () async throws -> Set<UUID> = { [] },
    secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
    bridgeDirectory: String = LocalInputMethodChannel.directory
  ) {
    self.settings = settings
    self.privacy = privacy
    self.bridgeDirectory = bridgeDirectory
    self.confirmRule = confirmRule
    self.revokeRule = revokeRule
    self.install = install
    self.inspectInstallation = inspectInstallation
    self.enableInputSource = enableInputSource
    self.installationState = inspectInstallation()
    self.ownedRuleIDs = ownedRuleIDs
    self.secureInputEnabled = secureInputEnabled
  }

  public func start() {
    guard loadTask == nil, !stopped else { return }
    loadTask = Task { [weak self, settings] in
      do {
        let encoded = try await settings.string(forKey: .inputMethodLearning)
        try Task.checkCancellation()
        guard let self, !self.stopped else { return }
        if let encoded {
          let loaded = try JSONDecoder().decode(
            TypingVocabularyState.self, from: Data(encoded.utf8))
          guard loaded.version == 1, loaded.suggestions.count <= 1_000 else {
            throw CocoaError(.coderReadCorrupt)
          }
          self.state = loaded
        }
        try await self.reconcileConfirmations()
        guard !self.stopped else { return }
        self.state.expire(at: Date())
        self.channel = try self.makeChannel(self.bridgeDirectory)
        self.channel?.receive = { [weak self] message, sender in
          self?.receive(message, sender: sender)
        }
        self.isReady = true
        self.maintenance = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) {
          [weak self] _ in
          Task { @MainActor [weak self] in await self?.expireSuggestions() }
        }
        self.persist()
      } catch is CancellationError {
      } catch { self?.error = "输入法学习暂不可用，未开始采集。重新打开 Rill 后重试。" }
    }
  }

  public func setEnabled(_ enabled: Bool) {
    guard isReady, !stopped else { return }
    state.enabled = enabled
    invalidatePolicy()
    persist()
  }

  public func setApplication(_ bundleID: String, allowed: Bool) {
    guard isReady, !stopped, !bundleID.isEmpty else { return }
    if allowed {
      state.allowedApplications.insert(bundleID)
    } else {
      state.allowedApplications.remove(bundleID)
    }
    invalidatePolicy()
    persist()
  }

  public func confirm(_ suggestion: TypingVocabularySuggestion) async {
    guard isReady, !stopped,
      state.suggestions.contains(where: { $0.id == suggestion.id && $0.status == .pending }),
      busyIDs.insert(suggestion.id).inserted
    else { return }
    defer { finishMutation(suggestion.id) }
    do {
      guard let pendingIndex = state.suggestions.firstIndex(where: { $0.id == suggestion.id })
      else { return }
      // Persist the deterministic source ID before creating a vocabulary entry. Recovery can
      // finish the confirmation, and deletion can undo it even if the second write fails.
      state.suggestions[pendingIndex].confirmedRuleID = suggestion.id
      state.suggestions[pendingIndex].ownsConfirmedRule = true
      persist()
      await writes.flush()
      let saved = try await settings.string(forKey: .inputMethodLearning)
      guard let saved,
        let document = try? JSONDecoder().decode(
          TypingVocabularyState.self, from: Data(saved.utf8)),
        document.suggestions.contains(where: { $0.id == suggestion.id && $0.ownsConfirmedRule })
      else {
        throw CocoaError(.fileWriteUnknown)
      }
      let (ruleID, ownsRule) = try await confirmRule(suggestion.phrase, suggestion.id)
      guard let index = state.suggestions.firstIndex(where: { $0.id == suggestion.id }) else {
        return
      }
      state.suggestions[index].status = .confirmed
      state.suggestions[index].confirmedRuleID = ruleID
      state.suggestions[index].ownsConfirmedRule = ownsRule
      persist()
    } catch { self.error = "词汇未能保存，建议仍保留，请重试。" }
  }

  public func ignore(_ id: UUID) async {
    guard isReady, !stopped,
      let suggestion = state.suggestions.first(where: { $0.id == id && $0.status == .pending }),
      busyIDs.insert(id).inserted
    else { return }
    defer { finishMutation(id) }
    do {
      if suggestion.ownsConfirmedRule { try await revokeRule(id) }
      guard let index = state.suggestions.firstIndex(where: { $0.id == id }) else { return }
      state.suggestions[index].status = .ignored
      state.suggestions[index].confirmedRuleID = nil
      state.suggestions[index].ownsConfirmedRule = false
      persist()
    } catch { self.error = "无法撤销这条词汇，请重试。" }
  }

  public func remove(_ suggestion: TypingVocabularySuggestion) async {
    guard isReady, !stopped,
      let suggestion = state.suggestions.first(where: { $0.id == suggestion.id }),
      busyIDs.insert(suggestion.id).inserted
    else { return }
    defer { finishMutation(suggestion.id) }
    do {
      if suggestion.ownsConfirmedRule, let id = suggestion.confirmedRuleID {
        try await revokeRule(id)
      }
      state.suggestions.removeAll { $0.id == suggestion.id }
      persist()
    } catch { self.error = "无法撤销这条词汇，请重试。" }
  }

  public func clearPending() async {
    guard isReady, !stopped else { return }
    invalidatePolicy()
    let pending = state.suggestions.filter { $0.status != .confirmed && !busyIDs.contains($0.id) }
    for suggestion in pending { await remove(suggestion) }
  }

  public func installInputMethod(importing directory: URL? = nil) async {
    guard !isInstalling, !stopped else { return }
    isInstalling = true
    status = nil
    error = nil
    defer {
      isInstalling = false
      refreshInstallationState()
      resumeMutationWaiters()
    }
    do { status = try await install(directory) } catch { self.error = error.localizedDescription }
  }

  public func refreshInstallationState() {
    guard !isInstalling, !stopped else { return }
    let current = inspectInstallation()
    if current != installationState { status = nil }
    installationState = current
  }

  public func enableInputMethod() {
    guard !isInstalling, !stopped else { return }
    status = nil
    error = nil
    defer { refreshInstallationState() }
    do { status = try enableInputSource() } catch { self.error = error.localizedDescription }
  }

  private func invalidatePolicy() {
    policyRevision = UUID()
    publishedApplications = []
    seenEvents.removeAll()
    eventOrder.removeAll()
  }

  private func policy() -> InputMethodLearningPolicy {
    var allowed = state.enabled && isReady && !stopped ? state.allowedApplications : []
    if secureInputEnabled() { allowed = [] }
    if let privacy = try? privacy() {
      for rule in privacy.sensitiveAppRules
      where rule.enabled
        && (rule.blocksSelectedText || rule.blocksWorkflowCapture || rule.blocksClipboardHistory)
      {
        allowed = allowed.filter {
          $0.caseInsensitiveCompare(rule.bundleIdentifier) != .orderedSame
        }
      }
    } else {
      allowed = []
    }
    if allowed != publishedApplications {
      policyRevision = UUID()
      publishedApplications = allowed
    }
    return InputMethodLearningPolicy(
      revision: policyRevision, applications: allowed, expiresAt: Date().addingTimeInterval(5))
  }

  private func receive(_ message: InputMethodMessage, sender: String) {
    let policy = policy()
    switch message.payload {
    case .hello: channel?.send(InputMethodMessage(.policy(policy)), to: sender)
    case .policy: break
    case .commit(let commit):
      guard commit.isValid, commit.policyRevision == policy.revision,
        policy.permits(commit.application), abs(commit.timestamp.timeIntervalSinceNow) < 5,
        seenEvents.insert(commit.id).inserted
      else { return }
      eventOrder.append(commit.id)
      if eventOrder.count > 2_048 { seenEvents.remove(eventOrder.removeFirst()) }
      state.observe(commit.text, application: commit.application, now: Date())
      persist()
    }
  }

  private func persist() {
    do {
      let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
      writes.replace(
        for: .inputMethodLearning, debounce: .milliseconds(150),
        operation: { [settings] in
          try await settings.setString(encoded, forKey: .inputMethodLearning)
        },
        completion: { [weak self] result in
          if case .failure(let error) = result, !(error is CancellationError) {
            self?.error = "输入法设置尚未保存，请重试。"
          }
        })
    } catch { self.error = "输入法设置尚未保存，请重试。" }
  }

  private func finishMutation(_ id: UUID) {
    busyIDs.remove(id)
    resumeMutationWaiters()
  }

  private func resumeMutationWaiters() {
    if busyIDs.isEmpty && !isInstalling {
      let waiters = mutationWaiters
      mutationWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private func reconcileConfirmations() async throws {
    let persistedIDs = try await ownedRuleIDs()
    for index in state.suggestions.indices where !busyIDs.contains(state.suggestions[index].id) {
      let id = state.suggestions[index].id
      if state.suggestions[index].status == .confirmed {
        if state.suggestions[index].ownsConfirmedRule,
          let ruleID = state.suggestions[index].confirmedRuleID, !persistedIDs.contains(ruleID)
        {
          state.suggestions[index].status = .pending
          state.suggestions[index].confirmedRuleID = nil
          state.suggestions[index].ownsConfirmedRule = false
        }
        continue
      }
      guard state.suggestions[index].status == .pending else { continue }
      if persistedIDs.contains(id) {
        state.suggestions[index].status = .confirmed
        state.suggestions[index].confirmedRuleID = id
        state.suggestions[index].ownsConfirmedRule = true
      } else {
        state.suggestions[index].confirmedRuleID = nil
        state.suggestions[index].ownsConfirmedRule = false
      }
    }
  }

  private func expireSuggestions() async {
    guard !stopped else { return }
    do {
      try await reconcileConfirmations()
      guard !stopped else { return }
      state.expire(at: Date())
      persist()
    } catch { self.error = "词汇建议暂时无法整理，请重试。" }
  }

  public func shutdown() async {
    stopped = true
    invalidatePolicy()
    channel?.shutdown()
    channel = nil
    maintenance?.invalidate()
    maintenance = nil
    loadTask?.cancel()
    await loadTask?.value
    while !busyIDs.isEmpty || isInstalling {
      await withCheckedContinuation { mutationWaiters.append($0) }
    }
    await writes.flush()
  }
}
