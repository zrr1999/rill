import Foundation
import RillCore
import RillInputMethodContracts
@testable import RillInputMethodIPC
import RillKnowledge
import Testing

@testable import RillUI

@MainActor
struct InputMethodLearningTests {
  private func pendingState() -> TypingVocabularyState {
    var state = TypingVocabularyState()
    state.enabled = true
    state.allowedApplications = ["test.editor"]
    state.observe("Rill", application: "test.editor", now: Date())
    return state
  }

  private func waitUntilReady(_ model: InputMethodFeatureModel) async throws {
    for _ in 0..<100 where !model.isReady { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.isReady)
  }

  @Test func confirmationUpdatesTheNextSpeechHintsAndCanBeUndone() async throws {
    let directory = "/tmp/rill-hints-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let state = pendingState()
    let settings = UITestSettingsStore(storage: [
      .inputMethodLearning: String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    ])
    let source = VocabularyRuleSource(initialRules: [])
    let harness = makeHarness(settingsStore: settings, vocabularyRuleSource: source)
    for _ in 0..<100 where harness.model.isLoadingSettings {
      try await Task.sleep(for: .milliseconds(10))
    }
    harness.model.installInputMethodFeature(
      privacy: { .defaults }, install: { _ in "" }, bridgeDirectory: directory)
    let model = try #require(harness.model.inputMethod)
    try await waitUntilReady(model)
    #expect(
      try VocabularyRecognitionHintResolver().resolve(rules: source.currentRules()).hints.keyterms
        .isEmpty)
    await model.confirm(try #require(model.state.suggestions.first))
    #expect(
      try VocabularyRecognitionHintResolver().resolve(rules: source.currentRules()).hints.keyterms
        == ["Rill"])
    await model.remove(try #require(model.state.suggestions.first))
    #expect(
      try VocabularyRecognitionHintResolver().resolve(rules: source.currentRules()).hints.keyterms
        .isEmpty)
    await model.shutdown()
  }

  @Test(arguments: [true, false])
  func restartReconcilesInterruptedConfirmationAndRevocation(ruleExists: Bool) async throws {
    let directory = "/tmp/rill-restore-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var state = pendingState()
    let id = try #require(state.suggestions.first?.id)
    state.suggestions[0].confirmedRuleID = id
    state.suggestions[0].ownsConfirmedRule = true
    state.suggestions[0].status = ruleExists ? .pending : .confirmed
    let settings = UITestSettingsStore(storage: [
      .inputMethodLearning: String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    ])
    let model = InputMethodFeatureModel(
      settings: settings, privacy: { .defaults },
      confirmRule: { _, id in (id, true) },
      revokeRule: { _ in Issue.record("Reconciliation unexpectedly revoked a rule") },
      install: { _ in "" },
      ownedRuleIDs: { ruleExists ? [id] : [] }, bridgeDirectory: directory)
    model.start()
    try await waitUntilReady(model)
    #expect(model.state.suggestions.first?.status == (ruleExists ? .confirmed : .pending))
    #expect(model.state.suggestions.first?.ownsConfirmedRule == ruleExists)
    await model.shutdown()
  }

  @Test func failedIntentPersistenceDoesNotCreateAHiddenHotword() async throws {
    let directory = "/tmp/rill-fail-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let state = pendingState()
    let settings = UITestSettingsStore(
      storage: [
        .inputMethodLearning: String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
      ],
      failingSetKeys: [.inputMethodLearning])
    var confirmations = 0
    let model = InputMethodFeatureModel(
      settings: settings, privacy: { .defaults },
      confirmRule: { _, id in
        confirmations += 1
        return (id, true)
      },
      revokeRule: { _ in Issue.record("A failed intent unexpectedly revoked a rule") },
      install: { _ in "" }, bridgeDirectory: directory)
    model.start()
    try await waitUntilReady(model)
    await model.confirm(try #require(model.state.suggestions.first))
    #expect(confirmations == 0)
    #expect(model.state.suggestions.first?.status == .pending)
    #expect(model.error != nil)
    await model.shutdown()
  }

  @Test func clearingAndShutdownWaitForAnAcceptedConfirmation() async throws {
    let directory = "/tmp/rill-drain-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let state = pendingState()
    let settings = UITestSettingsStore(storage: [
      .inputMethodLearning: String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    ])
    var gate: CheckedContinuation<Void, Never>?
    let model = InputMethodFeatureModel(
      settings: settings, privacy: { .defaults },
      confirmRule: { _, id in
        await withCheckedContinuation { gate = $0 }
        return (id, true)
      },
      revokeRule: { _ in Issue.record("Pending clear unexpectedly revoked a rule") },
      install: { _ in "" }, bridgeDirectory: directory)
    model.start()
    try await waitUntilReady(model)
    let suggestion = try #require(model.state.suggestions.first)
    let confirmation = Task { await model.confirm(suggestion) }
    for _ in 0..<100 where gate == nil { try await Task.sleep(for: .milliseconds(10)) }
    let release = try #require(gate)
    await model.clearPending()
    #expect(model.state.suggestions.count == 1)
    var stopped = false
    let stop = Task {
      await model.shutdown()
      stopped = true
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!stopped)
    release.resume()
    await confirmation.value
    await stop.value
    let saved = try #require(try await settings.string(forKey: .inputMethodLearning))
    let restored = try JSONDecoder().decode(TypingVocabularyState.self, from: Data(saved.utf8))
    #expect(restored.suggestions.first?.confirmedRuleID == suggestion.id)
    #expect(restored.suggestions.first?.status == .confirmed)
  }

  @Test func revokedPolicyAndDuplicateCommitsCannotProduceSuggestions() async throws {
    let directory = "/tmp/rill-learning-\(UUID().uuidString.prefix(8))"
    let settings = UITestSettingsStore()
    var revokedRuleID: UUID?
    let model = InputMethodFeatureModel(
      settings: settings, privacy: { .defaults },
      confirmRule: { _, id in (id, true) }, revokeRule: { revokedRuleID = $0 },
      install: { _ in "" },
      secureInputEnabled: { false }, bridgeDirectory: directory)
    model.makeChannel = { try LocalInputMethodChannel(host: true, directory: $0, authenticate: { _, _ in true }) }
    model.start()
    for _ in 0..<100 where !model.isReady { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.isReady)
    let client = try LocalInputMethodChannel(host: false, directory: directory, authenticate: { _, _ in true })
    var policy: InputMethodLearningPolicy?
    client.receive = { message, _ in if case .policy(let value) = message.payload { policy = value }
    }
    model.setEnabled(true)
    model.setApplication("test.editor", allowed: true)
    client.didConnect = { _ in _ = client.send(InputMethodMessage(.hello), to: directory + "/host.sock") }
    _ = client.send(InputMethodMessage(.hello), to: directory + "/host.sock")
    for _ in 0..<100 where policy == nil { try await Task.sleep(for: .milliseconds(10)) }
    let current = try #require(policy)
    let event = InputMethodCommit(
      policyRevision: current.revision, application: "test.editor", text: "Rill")
    #expect(client.send(InputMethodMessage(.commit(event)), to: directory + "/host.sock"))
    #expect(client.send(InputMethodMessage(.commit(event)), to: directory + "/host.sock"))
    for _ in 0..<100 where model.state.suggestions.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.state.suggestions.first?.count == 1)
    model.setApplication("test.editor", allowed: false)
    let late = InputMethodCommit(
      policyRevision: current.revision, application: "test.editor", text: "SQLite")
    #expect(client.send(InputMethodMessage(.commit(late)), to: directory + "/host.sock"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(!model.state.suggestions.contains { $0.phrase == "SQLite" })
    let suggestion = try #require(model.state.suggestions.first)
    await model.confirm(suggestion)
    #expect(model.state.suggestions.first?.status == .confirmed)
    await model.remove(try #require(model.state.suggestions.first))
    #expect(revokedRuleID == suggestion.id)
    #expect(model.state.suggestions.isEmpty)
    await model.shutdown()
    client.shutdown()
    let saved = try #require(try await settings.string(forKey: .inputMethodLearning))
    #expect(!saved.contains("SQLite"))
    try FileManager.default.removeItem(atPath: directory)
  }
}
