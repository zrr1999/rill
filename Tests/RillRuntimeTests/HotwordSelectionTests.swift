import Foundation
import RillDomainTestSupport
import os
import Testing
@testable import RillCore
@testable import RillWorkflows

@MainActor
struct HotwordSelectionTests {
  @Test(arguments: [false, true])
  func liveAdmissionFreezesVocabularyThroughProcessingQueue(cached: Bool) async throws {
    let fixture = HotwordFixture()
    if cached { try await fixture.populate() }
    let expectedTerms = cached ? ["Spore", "Rill"] : ["Rill", "Spore"]
    let context = fixture.context
    let workflow = fixture.workflow
    let options = SpeechRecognitionRequestOptions(modelID: fixture.options.modelID,
      vocabulary: .init(revision: UUID(), collections: fixture.collections),
      language: fixture.options.language)
    let vocabulary = VocabularyRuleSource()
    vocabulary.updateCollections(fixture.collections)
    let recognizer = HotwordRecognitionProbe()
    let recognizers = SpeechRecognizerRegistry(recognizers: [recognizer])
    let actions = OutputActionRegistry(actions: [HotwordOutputProbe()])
    let compiler = WorkflowPlanCompiler(recognizerRegistry: recognizers,
      transformerRegistry: .init(transformers: []), actionRegistry: actions)
    let resolver = LiveRecognitionContextResolver(compiler: compiler,
      collections: { try vocabulary.currentCollections() }, selection: fixture.selection, sanitize: { $0 })
    var gate = PrivacyRunGate(settingsProvider: { .init(cloudConfirmationRequired: false) },
      cloudConfirmationProvider: { _, _, _ in false })
    gate.prepareLiveRecognition = { runID, workflow, context, options, lifetime in
      try await resolver.prepare(runID: runID, workflow: workflow, context: context,
        options: options, lifetime: lifetime)
    }
    vocabulary.markUnavailable(reason: "library changed after snapshot")
    let runID = UUID()
    let live = try await gate.issueLiveAudioSession(runID: runID,
      privacyContextProvider: { context }, contextProvider: { _ in context },
      recognitionOptionsProvider: { _, _ in options }, workflow: workflow,
      revocationHandler: { _, _ in })
    #expect(live.audioCaptureOptions.hints.keyterms == expectedTerms)
    #expect(await fixture.provider.requests.count == (cached ? 1 : 0))
    vocabulary.markUnavailable(reason: "library changed after admission")
    let capture = HotwordCaptureProbe(ranking: fixture.provider)
    try await live.startCapture(.init(runID: runID, workflow: workflow,
      options: live.audioCaptureOptions, audioLifetime: live.audioLifetime), using: capture)
    if !cached {
      await fixture.provider.waitForRequest()
      #expect(await capture.startedBeforeCloud)
      await fixture.provider.finish()
    }
    let audio = try await capture.finishCapture()
    try await live.sealCapture()
    let lease = try await live.processingLeaseForEnqueue()
    let bus = EventBus()
    let coordinator = makeTestSessionCoordinator(privacyContextProvider: { context }, recognizerRegistry: recognizers,
      transformerRegistry: .init(transformers: []), actionRegistry: actions,
      candidateResolver: CandidateResolver(eventBus: bus), eventBus: bus,
      vocabularyCollectionProvider: { try vocabulary.currentCollections() })
    let queue = makeTestCapturedAudioProcessingQueue(sessionCoordinator: coordinator, eventBus: bus)
    let stream = await bus.stream()
    let drained = Task {
      var started = false
      for await event in stream {
        if case .audioProcessingQueueUpdated(let state) = event {
          if state.pendingCount > 0 { started = true }
          if started && state.pendingCount == 0 { return }
        }
      }
    }
    let transfer = await queue.enqueue(authorizationLease: lease, triggerEvent: nil,
      deferredCapture: .resolved(audio))
    #expect(transfer == .accepted)
    await drained.value
    await queue.shutdown()
    let received = try #require(await recognizer.options.first)
    #expect(received.hints.keyterms == expectedTerms)
    #expect(received.vocabulary == nil)
    #expect(received.modelID == "model-a")
    #expect(received.language == "Chinese")
    await fixture.selection.shutdown()
  }

  @Test func failedRecognitionCancelsItsStartedHotwordPreparation() async throws {
    let fixture = HotwordFixture()
    let recognizers = SpeechRecognizerRegistry(recognizers: [FailingHotwordRecognizer()])
    let actions = OutputActionRegistry(actions: [HotwordOutputProbe()])
    let compiler = WorkflowPlanCompiler(recognizerRegistry: recognizers,
      transformerRegistry: .init(transformers: []), actionRegistry: actions)
    let plan = try compiler.compile(workflow: fixture.workflow, collections: fixture.collections,
      context: VocabularyRuleContext(contextSnapshot: fixture.context))
    let gate = HotwordCancellationBarrier()
    let preparation = HotwordRankingPreparation { await gate.runUntilCancelled() }
    preparation.recordingStarted()
    await gate.waitUntilStarted()
    let bus = EventBus()
    let coordinator = makeTestSessionCoordinator(recognizerRegistry: recognizers,
      transformerRegistry: .init(transformers: []), actionRegistry: actions,
      candidateResolver: CandidateResolver(eventBus: bus), eventBus: bus)
    let result = await coordinator.runReportingOutcome(workflow: fixture.workflow,
      contextSnapshot: fixture.context, preparedRecognition: .init(options: fixture.options,
        plan: plan, hotwordPreparation: preparation))
    guard case .failed = result else { Issue.record("Expected failed recognition"); preparation.cancel(); return }
    await preparation.wait()
    #expect(await gate.observedCancellation)
    #expect(preparation.isFinished)
  }

  @Test func importedAudioDoesNotPrepareOrUploadHotwords() async throws {
    let called = OSAllocatedUnfairLock(initialState: false)
    var gate = PrivacyRunGate(settingsProvider: { .init(cloudConfirmationRequired: false) },
      cloudConfirmationProvider: { _, _, _ in false })
    gate.prepareLiveRecognition = { _, _, _, _, _ in
      called.withLock { $0 = true }
      return nil
    }
    let context = hotwordContext()
    let lease = try await gate.issueAudioProcessingLease(runID: UUID(),
      privacyContextProvider: { context }, contextProvider: { _ in context },
      recognitionOptionsProvider: { _, _ in .empty }, workflow: hotwordWorkflow())
    #expect(!called.withLock { $0 })
    #expect(lease.preparedRecognition == nil)
    lease.cancel()
  }

  @Test func coldRunNeverWaitsAndOnlyNextMatchingRunUsesRanking() async throws {
    let fixture = HotwordFixture()
    let first = try fixture.select()
    #expect(first.status == .miss)
    #expect(first.terms == ["Rill", "Spore"])
    #expect(await fixture.provider.requests.isEmpty)
    let preparation = try #require(first.preparation)
    preparation.recordingStarted()
    await fixture.provider.waitForRequest()
    let overlapping = try fixture.select()
    overlapping.preparation?.recordingStarted()
    await overlapping.preparation?.wait()
    #expect(overlapping.terms == first.terms)
    #expect(await fixture.provider.requests.count == 1)
    await fixture.provider.finish()
    await preparation.wait()
    let cached = try fixture.select()
    #expect(cached.status == .hit)
    #expect(cached.terms == ["Spore", "Rill"])
    #expect(first.terms == ["Rill", "Spore"])
    #expect(cached.preparation == nil)
    await fixture.selection.shutdown()
  }

  @Test func contextVocabularyWorkflowLanguageAndModelInvalidateCache() async throws {
    let fixture = HotwordFixture()
    try await fixture.populate()
    #expect(try fixture.select().status == .hit)
    var context = fixture.context
    context.focus.selectedText = "different topic"
    #expect(try fixture.select(context: context).status == .miss)
    var workflow = fixture.workflow
    workflow.name = "Different workflow"
    #expect(try fixture.select(workflow: workflow).status == .miss)
    var collections = fixture.collections
    collections[0].entries[0].priority += 1
    #expect(try fixture.select(collections: collections).status == .miss)
    #expect(try fixture.select(options: .init(modelID: "model-a", language: "English")).status == .miss)
    #expect(try fixture.select(options: .init(modelID: "model-b", language: "Chinese")).status == .miss)
    fixture.clock.withLock { $0 += 301 }
    #expect(try fixture.select().status == .miss)
    await fixture.selection.shutdown()
  }

  @Test func cacheEvictsLeastRecentlyUsedBeyondThirtyTwoEntries() async throws {
    let fixture = HotwordFixture()
    for index in 0..<33 {
      var context = fixture.context
      context.focus.selectedText = "topic-\(index)"
      try await fixture.populate(context: context)
    }
    var context = fixture.context
    context.focus.selectedText = "topic-0"
    #expect(try fixture.select(context: context).status == .miss)
    context.focus.selectedText = "topic-32"
    #expect(try fixture.select(context: context).status == .hit)
    await fixture.selection.shutdown()
  }

  @Test func privacyRevocationAndRestorationCannotResurrectCachedScores() async throws {
    let fixture = HotwordFixture()
    try await fixture.populate()
    #expect(try fixture.select().status == .hit)
    let original = try fixture.privacy.currentSettings()
    fixture.privacy.markUnavailable(reason: "revoked")
    fixture.privacy.update(original)
    #expect(try fixture.select().status == .miss)
    await fixture.selection.shutdown()
  }

  @Test func disablingCancelsInflightWorkAndRejectsLateResult() async throws {
    let fixture = HotwordFixture()
    let first = try fixture.select()
    first.preparation?.recordingStarted()
    await fixture.provider.waitForRequest()
    fixture.selection.configure(isEnabled: false)
    await first.preparation?.wait()
    #expect(try fixture.select().status == .disabled)
    await fixture.provider.finish()
    await fixture.selection.shutdown()
  }

  @Test func sharedCredentialRevocationCancelsInflightWorkAndRejectsCache() async throws {
    let fixture = HotwordFixture()
    let first = try fixture.select()
    first.preparation?.recordingStarted()
    await fixture.provider.waitForRequest()
    fixture.credentials.clear()
    await first.preparation?.wait()
    #expect(try fixture.select().status == .disabled)
    await fixture.provider.finish()
    try fixture.credentials.setKey("replacement-test-key")
    #expect(try fixture.select().status == .disabled)
    await fixture.selection.shutdown()
  }

  @Test func cancellationBeforeStartNeverSendsAndShutdownDrainsIgnoringProvider() async throws {
    let fixture = HotwordFixture()
    let cancelled = try fixture.select()
    cancelled.preparation?.cancel()
    cancelled.preparation?.recordingStarted()
    await cancelled.preparation?.wait()
    #expect(await fixture.provider.requests.isEmpty)
    let active = try fixture.select()
    active.preparation?.recordingStarted()
    await fixture.provider.waitForRequest()
    let shutdownFinished = OSAllocatedUnfairLock(initialState: false)
    let shutdown = Task {
      await fixture.selection.shutdown()
      shutdownFinished.withLock { $0 = true }
    }
    await active.preparation?.wait()
    #expect(!shutdownFinished.withLock { $0 })
    await fixture.provider.finish()
    await shutdown.value
    #expect(shutdownFinished.withLock { $0 })
    #expect(try fixture.select().status == .disabled)
  }

  @Test func deadlineDoesNotRetryOrAcceptLateResults() async throws {
    let fixture = HotwordFixture(timeout: .milliseconds(40))
    let selected = try fixture.select()
    selected.preparation?.recordingStarted()
    await fixture.provider.waitForRequest()
    await selected.preparation?.wait()
    #expect(await fixture.provider.requests.count == 1)
    #expect(try fixture.select().status == .miss)
    await fixture.provider.finish()
    await fixture.selection.shutdown()
  }

  @Test func failureAndInvalidScoresKeepLocalOrdering() async throws {
    for invalid in [false, true] {
      let fixture = HotwordFixture()
      let first = try fixture.select()
      first.preparation?.recordingStarted()
      await fixture.provider.waitForRequest()
      if invalid { await fixture.provider.finish(scores: []) }
      else { await fixture.provider.fail() }
      await first.preparation?.wait()
      let next = try fixture.select()
      #expect(next.status == .miss)
      #expect(next.terms == ["Rill", "Spore"])
      #expect(await fixture.provider.requests.count == 1)
      await fixture.selection.shutdown()
    }
  }

  @Test func policyRevocationCancelsPredictionWithoutCancellingLocalAudio() async throws {
    let fixture = HotwordFixture()
    let lifetime = AudioCaptureLifetime(runID: UUID())
    let first = try fixture.select(lifetime: lifetime)
    first.preparation?.recordingStarted()
    await fixture.provider.waitForRequest()
    fixture.privacy.markUnavailable(reason: "test")
    await first.preparation?.wait()
    #expect(lifetime.isActive)
    #expect(try fixture.select().status == .privacy)
    await fixture.provider.finish()
    await fixture.selection.shutdown()
  }

  @Test func sourceAndCurrentPrivacyBothApplyAndNoExtraContextIsCaptured() async throws {
    let fixture = HotwordFixture()
    var sensitive = fixture.context
    sensitive.focus.secureInput = true
    #expect(try fixture.select(context: sensitive).status == .privacy)
    fixture.focus.value.secureInput = true
    #expect(try fixture.select().status == .privacy)
    fixture.focus.value.secureInput = false
    fixture.focus.value.bundleIdentifier = "other-app"
    #expect(try fixture.select().status == .privacy)
    #expect(await fixture.provider.requests.isEmpty)
    await fixture.selection.shutdown()
  }

  @Test func oversizedSelectionIsOmittedAndDiagnosticsContainNoText() async throws {
    let fixture = HotwordFixture()
    var context = fixture.context
    context.focus.selectedText = String(repeating: "secret-selection", count: 200)
    let first = try fixture.select(context: context)
    first.preparation?.recordingStarted()
    await fixture.provider.waitForRequest()
    let request = try #require(await fixture.provider.requests.first)
    #expect(request.selectedText.isEmpty)
    #expect(request.candidates == ["Rill", "Spore"])
    await fixture.provider.finish()
    await first.preparation?.wait()
    let events = fixture.events.withLock { $0 }
    #expect(events.count == 1)
    #expect(events[0].event == "hotword-ranking.completed")
    #expect(events[0].metadata["hotwordRankingOutcome"] == "ready")
    #expect(events[0].metadata["hotwordCandidateCount"] == "2")
    #expect(events[0].metadata["durationMillis"] != nil)
    let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    #expect(!encoded.contains("secret-selection"))
    #expect(!encoded.contains("private-clipboard"))
    #expect(!encoded.contains("unit-test-key"))
    #expect(!encoded.contains("Spore"))
    await fixture.selection.shutdown()
  }
}

@MainActor
private final class HotwordFocus {
  var value: FocusSnapshot
  init(_ value: FocusSnapshot) { self.value = value }
}

@MainActor
private final class HotwordFixture {
  let provider = HotwordRankingProbe()
  let credentials = JevSessionSettingsSource()
  let privacy = PrivacyPolicySettingsSource(initialSettings: .init(cloudConfirmationRequired: true))
  let clock = OSAllocatedUnfairLock(initialState: 0.0)
  let events = OSAllocatedUnfairLock(initialState: [DiagnosticEvent]())
  let focus: HotwordFocus
  let context: ContextSnapshot
  let workflow: WorkflowDefinition
  let collections: [VocabularyCollection]
  let candidates: [HotwordCandidate]
  let selection: HotwordSelection
  let options = SpeechRecognitionRequestOptions(modelID: "model-a", language: "Chinese")

  init(timeout: Duration = .seconds(2)) {
    context = hotwordContext()
    focus = HotwordFocus(context.focus)
    collections = [.personal(entries: [
      .init(content: .hotword(phrase: "Rill"), createdAt: .distantPast),
      .init(content: .hotword(phrase: "Spore"), createdAt: .distantFuture),
    ])]
    candidates = collections[0].entries.map {
      HotwordCandidate(id: $0.id, term: $0.legacyRule().pattern, priority: $0.priority)
    }
    workflow = hotwordWorkflow()
    selection = HotwordSelection(provider: provider, settings: credentials, privacy: privacy,
      currentFocus: { [focus] in focus.value },
      report: { [events] event in events.withLock { $0.append(DiagnosticEventSanitizer.sanitize(event)) } },
      now: { [clock] in Date(timeIntervalSince1970: clock.withLock { $0 }) }, timeout: timeout)
    try! credentials.setKey("unit-test-key")
    selection.configure(isEnabled: true)
  }

  func select(context: ContextSnapshot? = nil, workflow: WorkflowDefinition? = nil,
    collections: [VocabularyCollection]? = nil, options: SpeechRecognitionRequestOptions? = nil,
    lifetime: AudioCaptureLifetime? = nil) throws -> HotwordSelection.Selection {
    let runID = UUID()
    return try selection.select(runID: runID, workflow: workflow ?? self.workflow,
      collections: collections ?? self.collections, context: context ?? self.context,
      options: options ?? self.options, candidates: candidates,
      lifetime: lifetime ?? AudioCaptureLifetime(runID: runID))
  }

  func populate(context: ContextSnapshot? = nil) async throws {
    let selected = try select(context: context)
    selected.preparation?.recordingStarted()
    await provider.waitForRequest()
    await provider.finish()
    await selected.preparation?.wait()
  }
}

private actor HotwordRankingProbe: HotwordRankingProvider {
  var requests: [HotwordRankingRequest] = []
  private var continuation: CheckedContinuation<[HotwordRankingScore], Error>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  func score(_ request: HotwordRankingRequest, apiKey _: String) async throws -> [HotwordRankingScore] {
    requests.append(request)
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      for observer in observers { observer.resume() }
      observers.removeAll()
    }
  }

  func waitForRequest() async {
    if continuation != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func finish(scores: [HotwordRankingScore]? = nil) {
    let value = scores ?? requests.last!.candidates.indices.map { index in
      HotwordRankingScore(score: index == 1 ? 2 : 1, confidence: 1,
        probabilities: index == 1 ? [0, 0, 1] : [0, 1, 0])
    }
    continuation?.resume(returning: value)
    continuation = nil
  }

  func fail() {
    continuation?.resume(throwing: URLError(.notConnectedToInternet))
    continuation = nil
  }
}

private func hotwordContext() -> ContextSnapshot {
  .init(focus: .init(applicationName: "Editor", bundleIdentifier: "example.editor", processIdentifier: 42,
    focusedRole: "AXTextArea", selectedText: "Spore grammar", secureInput: false),
    clipboard: .init(plainText: "private-clipboard", changeCount: 123))
}

private func hotwordWorkflow() -> WorkflowDefinition {
  .init(name: "Dictation", plan: .init(setup: .init(
    speechRoute: .init(recognizerID: "local-speech"),
    vocabularyBindings: [.init(collectionID: VocabularyCollection.personalID, uses: [.recognitionHints])]),
    process: .init(steps: [.init(kind: .recognizeSpeech)]),
    output: .init(actions: [.init(id: "system-clipboard.copy")])),
    ui: .init(symbolName: "waveform", accentColorName: "blue"))
}

private actor HotwordRecognitionProbe: SpeechRecognizer {
  nonisolated let id = "local-speech"
  nonisolated let capabilities = SpeechRecognizerCapabilities(supportedHintKinds: [.keyterm])
  var options: [SpeechRecognitionRequestOptions] = []
  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    options.append(request.options)
    return .init(rawText: "Rill", bestText: "Rill")
  }
}

private struct HotwordOutputProbe: OutputAction {
  let id = "system-clipboard.copy"
  func execute(record _: RecordDraft, context _: ActionContext) async throws -> ActionResult { .copiedToClipboard }
}

private struct HotwordContextProbe: ContextProvider {
  func captureContext() async -> ContextSnapshot { hotwordContext() }
}

private actor HotwordCaptureProbe: AudioCaptureService {
  let ranking: HotwordRankingProbe
  var startedBeforeCloud = false
  init(ranking: HotwordRankingProbe) { self.ranking = ranking }
  func startCapture(_: AudioCaptureRequest) async throws { startedBeforeCloud = await ranking.requests.isEmpty }
  func finishCapture() async throws -> CapturedAudio {
    try .init(durationSeconds: 1, format: .init(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      inlineData: Data([0, 0]))
  }
  func cancelCapture() async {}
}

private struct FailingHotwordRecognizer: SpeechRecognizer {
  enum Failure: Error { case unavailable }
  let id = "local-speech"
  let capabilities = SpeechRecognizerCapabilities(supportedHintKinds: [.keyterm])
  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    throw Failure.unavailable
  }
}

private actor HotwordCancellationBarrier {
  private var started = false
  private var suspended: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  private(set) var observedCancellation = false
  func runUntilCancelled() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        started = true
        observers.forEach { $0.resume() }; observers = []
        if Task.isCancelled { continuation.resume() } else { suspended = continuation }
      }
      observedCancellation = Task.isCancelled
    } onCancel: { Task { await self.release() } }
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { observers.append($0) }
  }
  private func release() { suspended?.resume(); suspended = nil }
}
