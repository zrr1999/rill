import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillPlatform
@testable import RillProviders
@testable import RillRuntime
@testable import RillUI

private actor AppBootstrapLocalSpeechPreparationProbe {
  enum Event: Equatable {
    case model
    case audioFrontend
    case streamingPreview
    case streamingPreviewFailure
  }

  private var events: [Event] = []

  func prepareModel() -> String {
    events.append(.model)
    return "prepared-model"
  }

  func prepareAudioFrontend() {
    events.append(.audioFrontend)
  }

  func prepareStreamingPreview() {
    events.append(.streamingPreview)
  }

  func recordStreamingPreviewFailure() {
    events.append(.streamingPreviewFailure)
  }

  func snapshot() -> [Event] {
    events
  }
}

private actor AppBootstrapExplanationProbe {
  private var privacyCaptureCount = 0
  private var confirmationCount = 0

  func capture(_ context: ContextSnapshot) -> ContextSnapshot {
    privacyCaptureCount += 1
    return context
  }

  func recordConfirmation() {
    confirmationCount += 1
  }

  func snapshot() -> (privacyCaptures: Int, confirmations: Int) {
    (privacyCaptureCount, confirmationCount)
  }
}

private actor AppBootstrapPrivacyContextSequenceProbe {
  private let contexts: [ContextSnapshot]
  private var index = 0

  init(contexts: [ContextSnapshot]) {
    self.contexts = contexts
  }

  func next() -> ContextSnapshot {
    let context = contexts[min(index, contexts.count - 1)]
    index += 1
    return context
  }

  func count() -> Int {
    index
  }
}

private struct AppBootstrapExplanationRecognizer: SpeechRecognizer {
  let id = "sherpa-onnx.local"

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    RecognitionResult(rawText: "", bestText: "")
  }
}

private struct AppBootstrapExplanationTransformer: TextTransformer {
  let id = "transformer.openai.responses.rewrite"
  let supportedKinds: [PostProcessStepKind] = [.llmRewrite]

  func transform(
    text: String,
    step: PostProcessStep,
    context: TransformContext
  ) async throws -> String {
    text
  }
}

private struct AppBootstrapExplanationAction: OutputAction {
  let id = "inject.text"

  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    .injected
  }
}

private actor AppBootstrapSettingsStore: SensitiveSettingsStore {
  private var storage: [AppSettingKey: String]
  private let unavailableKeys: Set<AppSettingKey>
  private var writeCounts: [AppSettingKey: Int] = [:]
  private var removalCounts: [AppSettingKey: Int] = [:]
  private var residuePurgeCount = 0

  init(
    storage: [AppSettingKey: String],
    unavailableKeys: Set<AppSettingKey> = []
  ) {
    self.storage = storage
    self.unavailableKeys = unavailableKeys
  }

  func string(forKey key: AppSettingKey) async throws -> String? {
    storage[key]
  }

  func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
    keys.reduce(into: [:]) { partialResult, key in
      if let value = storage[key] {
        partialResult[key] = value
      }
    }
  }

  func settingsSnapshot(
    forKeys keys: [AppSettingKey]
  ) async throws -> SettingsStoreReadSnapshot {
    var values = try await strings(forKeys: keys)
    let requestedUnavailableKeys = unavailableKeys.intersection(Set(keys))
    for key in requestedUnavailableKeys {
      values.removeValue(forKey: key)
    }
    return SettingsStoreReadSnapshot(
      values: values,
      unavailableKeys: requestedUnavailableKeys
    )
  }

  func setString(_ value: String, forKey key: AppSettingKey) async throws {
    storage[key] = value
    writeCounts[key, default: 0] += 1
  }

  func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    for (key, value) in values {
      storage[key] = value
      writeCounts[key, default: 0] += 1
    }
  }

  func removeValue(forKey key: AppSettingKey) async throws {
    storage.removeValue(forKey: key)
    removalCounts[key, default: 0] += 1
  }

  func writeCount(for key: AppSettingKey) -> Int {
    writeCounts[key, default: 0]
  }

  func removalCount(for key: AppSettingKey) -> Int {
    removalCounts[key, default: 0]
  }

  func storedValue(for key: AppSettingKey) -> String? {
    storage[key]
  }

  func purgeSensitiveStorageResidue() async throws {
    residuePurgeCount += 1
  }

  func purgeCount() -> Int {
    residuePurgeCount
  }
}

private actor AppBootstrapCredentialStore: SecureCredentialStore {
  private var storage: [SecureCredentialKey: String]
  private var removalCounts: [SecureCredentialKey: Int] = [:]

  init(storage: [SecureCredentialKey: String]) {
    self.storage = storage
  }

  func credential(for key: SecureCredentialKey) async throws -> String? {
    storage[key]
  }

  func setCredential(_ value: String, for key: SecureCredentialKey) async throws {
    storage[key] = value
  }

  func removeCredential(for key: SecureCredentialKey) async throws {
    storage.removeValue(forKey: key)
    removalCounts[key, default: 0] += 1
  }

  func storedValue(for key: SecureCredentialKey) -> String? {
    storage[key]
  }

  func removalCount(for key: SecureCredentialKey) -> Int {
    removalCounts[key, default: 0]
  }
}

private actor AppBootstrapSecureWebhookStore: SecureWebhookConfigurationStore {
  private var operationCount = 0

  func configuration(
    for reference: WebhookConfigurationReference
  ) async throws -> WebhookProtectedConfiguration? {
    operationCount += 1
    return nil
  }

  func setConfiguration(
    _ configuration: WebhookProtectedConfiguration,
    for reference: WebhookConfigurationReference
  ) async throws {
    operationCount += 1
  }

  func calls() -> Int {
    operationCount
  }
}

private actor AppBootstrapClipboardHistory: ClipboardHistoryMaintaining {
  private let clearResult: ClipboardCleanupResult

  init(clearResult: ClipboardCleanupResult) {
    self.clearResult = clearResult
  }

  func pruneHistory(olderThan cutoff: Date) async throws -> ClipboardCleanupResult {
    clearResult
  }

  func clearHistory() async throws -> ClipboardCleanupResult {
    clearResult
  }

  func clearHistory(through upperBound: Date) async throws -> ClipboardCleanupResult {
    clearResult
  }
}

private actor AppBootstrapHistoryRepository: HistoryRepository {
  private var clearCount: Int
  private var currentGeneration: RunHistoryWriteGeneration = .initial
  private var lastClearIntentID: UUID?

  init(clearCount: Int = 0) {
    self.clearCount = clearCount
  }

  func save(_ record: HistoryRecord) async throws {}

  func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
    currentGeneration
  }

  func records(matching query: HistoryQuery) async throws -> [HistoryRecord] {
    []
  }

  func deleteRecords(olderThan cutoff: Date) async throws -> Int {
    0
  }

  func deleteAllRecords() async throws -> Int {
    clearCount
  }

  func deleteRecords(through upperBound: Date) async throws -> Int {
    clearCount
  }

  func deleteRecords(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    if currentGeneration == transition.nextGeneration,
      lastClearIntentID == transition.intentID
    {
      return 0
    }
    guard currentGeneration == transition.previousGeneration else {
      throw RunHistoryGenerationError.clearTransitionConflict
    }
    currentGeneration = transition.nextGeneration
    lastClearIntentID = transition.intentID
    defer { clearCount = 0 }
    return clearCount
  }
}

private actor AppBootstrapDiagnosticRepository: DiagnosticRepository {
  private var clearCount: Int
  private var currentGeneration: RunHistoryWriteGeneration = .initial
  private var lastClearIntentID: UUID?

  init(clearCount: Int = 0) {
    self.clearCount = clearCount
  }

  func save(_ event: DiagnosticEvent) async throws {}

  func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
    currentGeneration
  }

  func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
    []
  }

  func deleteEvents(olderThan cutoff: Date) async throws -> Int {
    0
  }

  func deleteAllEvents() async throws -> Int {
    clearCount
  }

  func deleteEvents(through upperBound: Date) async throws -> Int {
    clearCount
  }

  func deleteEvents(
    obsoletedBy transition: RunHistoryClearTransition,
    preservingLegacyRowsAfter legacyUpperBound: Date?
  ) async throws -> Int {
    if currentGeneration == transition.nextGeneration,
      lastClearIntentID == transition.intentID
    {
      return 0
    }
    guard currentGeneration == transition.previousGeneration else {
      throw RunHistoryGenerationError.clearTransitionConflict
    }
    currentGeneration = transition.nextGeneration
    lastClearIntentID = transition.intentID
    defer { clearCount = 0 }
    return clearCount
  }
}

private actor AppBootstrapMaintenanceEventRecorder {
  private var events: [LocalHistoryMaintenanceEvent] = []

  func record(_ event: LocalHistoryMaintenanceEvent) {
    events.append(event)
  }

  func recordedEvents() -> [LocalHistoryMaintenanceEvent] {
    events
  }
}

private actor AppBootstrapRichPasteProbe {
  struct Snapshot: Sendable {
    var captureCount: Int
    var deliveredItemIDs: [UUID]
    var deliveredContexts: [ContextSnapshot]
    var injectedSnapshot: ClipboardSnapshot?
    var targetFocus: FocusSnapshot?
    var markedItemIDs: [UUID]
    var failures: [String]
  }

  private var captureCount = 0
  private var deliveredItemIDs: [UUID] = []
  private var deliveredContexts: [ContextSnapshot] = []
  private var injectedSnapshot: ClipboardSnapshot?
  private var targetFocus: FocusSnapshot?
  private var markedItemIDs: [UUID] = []
  private var failures: [String] = []

  func capture(_ context: ContextSnapshot) -> ContextSnapshot {
    captureCount += 1
    return context
  }

  func deliver(_ itemID: UUID, context: ContextSnapshot) {
    deliveredItemIDs.append(itemID)
    deliveredContexts.append(context)
  }

  func inject(_ snapshot: ClipboardSnapshot, targetFocus: FocusSnapshot) {
    injectedSnapshot = snapshot
    self.targetFocus = targetFocus
  }

  func markUsed(_ itemID: UUID) {
    markedItemIDs.append(itemID)
  }

  func recordFailure(_ message: String) {
    failures.append(message)
  }

  func snapshot() -> Snapshot {
    Snapshot(
      captureCount: captureCount,
      deliveredItemIDs: deliveredItemIDs,
      deliveredContexts: deliveredContexts,
      injectedSnapshot: injectedSnapshot,
      targetFocus: targetFocus,
      markedItemIDs: markedItemIDs,
      failures: failures
    )
  }
}

private func makeClipboardItemUseLease(
  for item: ClipboardHistoryItem
) -> ClipboardItemUseLease {
  ClipboardItemUseLease(leaseID: UUID(), item: item)
}

final class AppBootstrapTests: XCTestCase {
  func testTTSPreparationProgressDoesNotResetWhenLoadingStarts() {
    XCTAssertEqual(
      AppBootstrap.displayedTTSPreparationProgress(
        .init(phase: .downloading, completedUnitCount: 1, totalUnitCount: 2)
      ),
      0.475,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      AppBootstrap.displayedTTSPreparationProgress(
        .init(phase: .downloading, completedUnitCount: 2, totalUnitCount: 2)
      ),
      0.95,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      AppBootstrap.displayedTTSPreparationProgress(
        .init(phase: .loading, completedUnitCount: 0, totalUnitCount: 1)
      ),
      0.95,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      AppBootstrap.displayedTTSPreparationProgress(
        .init(phase: .loading, completedUnitCount: 1, totalUnitCount: 1)
      ),
      1,
      accuracy: 0.000_001
    )
  }

  func testFileHistoryItemUsesPanelRichPasteWithPrivacyFocusTarget() async throws {
    let item = ClipboardHistoryItem(
      groupID: ClipboardGroup.defaultGroupID,
      contentKind: .files,
      text: "",
      fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
      sourceKind: .system
    )
    let targetFocus = FocusSnapshot(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 42,
      focusedRole: "AXTextArea",
      selectedText: "",
      secureInput: false
    )
    let privacyContext = ContextSnapshot(
      focus: targetFocus,
      clipboard: ClipboardSnapshot(plainText: "", changeCount: 7)
    )
    let probe = AppBootstrapRichPasteProbe()
    let target = try XCTUnwrap(ClipboardPasteTargetIdentity(focus: targetFocus))

    await AppBootstrap.useClipboardItem(
      item,
      target: target,
      capturePrivacyContext: {
        await probe.capture(privacyContext)
      },
      deliverText: { subject, context in
        await probe.deliver(subject.itemID, context: context)
      },
      claimRichItem: { _ in makeClipboardItemUseLease(for: item) },
      injectClipboardSnapshot: { snapshot, focus in
        await probe.inject(snapshot, targetFocus: focus)
      },
      completeUse: { _ in
        await probe.markUsed(item.id)
      },
      failUse: { _ in },
      reportFailure: { message in
        await probe.recordFailure(message)
      }
    )

    let result = await probe.snapshot()
    XCTAssertEqual(result.captureCount, 1)
    XCTAssertTrue(result.deliveredItemIDs.isEmpty)
    XCTAssertTrue(result.deliveredContexts.isEmpty)
    XCTAssertEqual(result.injectedSnapshot, item.clipboardSnapshot)
    XCTAssertEqual(result.targetFocus, targetFocus)
    XCTAssertEqual(result.markedItemIDs, [item.id])
    XCTAssertTrue(result.failures.isEmpty)
  }

  func testRichHistoryItemDoesNotInjectWhenExactClaimFindsItemDrift() async throws {
    let item = ClipboardHistoryItem(
      groupID: ClipboardGroup.defaultGroupID,
      contentKind: .files,
      text: "",
      fileURLs: [URL(fileURLWithPath: "/tmp/stale.pdf")],
      sourceKind: .system
    )
    let targetFocus = FocusSnapshot(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 42,
      focusedRole: "AXTextArea",
      selectedText: "",
      secureInput: false
    )
    let privacyContext = ContextSnapshot(
      focus: targetFocus,
      clipboard: ClipboardSnapshot(plainText: "", changeCount: 7)
    )
    let probe = AppBootstrapRichPasteProbe()
    let target = try XCTUnwrap(ClipboardPasteTargetIdentity(focus: targetFocus))

    await AppBootstrap.useClipboardItem(
      item,
      target: target,
      capturePrivacyContext: { await probe.capture(privacyContext) },
      deliverText: { subject, context in
        await probe.deliver(subject.itemID, context: context)
      },
      claimRichItem: { _ in
        throw ClipboardItemUseLeaseError.sourceChanged
      },
      injectClipboardSnapshot: { snapshot, focus in
        await probe.inject(snapshot, targetFocus: focus)
      },
      completeUse: { _ in await probe.markUsed(item.id) },
      failUse: { _ in },
      reportFailure: { message in await probe.recordFailure(message) }
    )

    let result = await probe.snapshot()
    XCTAssertEqual(result.captureCount, 1)
    XCTAssertTrue(result.deliveredItemIDs.isEmpty)
    XCTAssertNil(result.injectedSnapshot)
    XCTAssertTrue(result.markedItemIDs.isEmpty)
    XCTAssertEqual(
      result.failures,
      ["The selected clipboard item changed before it could be used."]
    )
  }

  func testTextHistoryItemUsesTheValidatedPrivacyContext() async throws {
    let item = ClipboardHistoryItem(
      groupID: ClipboardGroup.defaultGroupID,
      text: "saved text",
      sourceKind: .system
    )
    let targetFocus = FocusSnapshot(
      applicationName: "Editor",
      bundleIdentifier: "com.example.Editor",
      processIdentifier: 42,
      focusedRole: "AXTextArea",
      selectedText: "",
      secureInput: false
    )
    let privacyContext = ContextSnapshot(
      focus: targetFocus,
      clipboard: ClipboardSnapshot(plainText: "", changeCount: 9)
    )
    let target = try XCTUnwrap(ClipboardPasteTargetIdentity(focus: targetFocus))
    let probe = AppBootstrapRichPasteProbe()

    await AppBootstrap.useClipboardItem(
      item,
      target: target,
      capturePrivacyContext: { await probe.capture(privacyContext) },
      deliverText: { subject, context in
        await probe.deliver(subject.itemID, context: context)
      },
      claimRichItem: { _ in makeClipboardItemUseLease(for: item) },
      injectClipboardSnapshot: { snapshot, focus in
        await probe.inject(snapshot, targetFocus: focus)
      },
      completeUse: { _ in await probe.markUsed(item.id) },
      failUse: { _ in },
      reportFailure: { message in await probe.recordFailure(message) }
    )

    let result = await probe.snapshot()
    XCTAssertEqual(result.captureCount, 1)
    XCTAssertEqual(result.deliveredItemIDs, [item.id])
    XCTAssertEqual(result.deliveredContexts, [privacyContext])
    XCTAssertNil(result.injectedSnapshot)
    XCTAssertNil(result.targetFocus)
    XCTAssertTrue(result.markedItemIDs.isEmpty)
    XCTAssertTrue(result.failures.isEmpty)
  }

  func testTextHistoryItemDoesNothingWhenRestoredTargetChanged() async throws {
    try await assertClipboardPasteIsBlockedAfterTargetChange(
      item: ClipboardHistoryItem(
        groupID: ClipboardGroup.defaultGroupID,
        text: "saved text",
        sourceKind: .system
      )
    )
  }

  func testRichHistoryItemDoesNothingWhenRestoredTargetChanged() async throws {
    try await assertClipboardPasteIsBlockedAfterTargetChange(
      item: ClipboardHistoryItem(
        groupID: ClipboardGroup.defaultGroupID,
        contentKind: .files,
        text: "",
        fileURLs: [URL(fileURLWithPath: "/tmp/private-file.pdf")],
        sourceKind: .system
      )
    )
  }

  private func assertClipboardPasteIsBlockedAfterTargetChange(
    item: ClipboardHistoryItem
  ) async throws {
    let lockedTarget = try XCTUnwrap(
      ClipboardPasteTargetIdentity(
        processIdentifier: 42,
        bundleIdentifier: "com.example.EditorA"
      )
    )
    let changedContext = ContextSnapshot(
      focus: FocusSnapshot(
        applicationName: "Editor B",
        bundleIdentifier: "com.example.EditorB",
        processIdentifier: 84,
        focusedRole: "AXTextArea",
        selectedText: "",
        secureInput: false
      ),
      clipboard: ClipboardSnapshot(plainText: "", changeCount: 10)
    )
    let probe = AppBootstrapRichPasteProbe()

    await AppBootstrap.useClipboardItem(
      item,
      target: lockedTarget,
      capturePrivacyContext: { await probe.capture(changedContext) },
      deliverText: { subject, context in
        await probe.deliver(subject.itemID, context: context)
      },
      claimRichItem: { _ in makeClipboardItemUseLease(for: item) },
      injectClipboardSnapshot: { snapshot, focus in
        await probe.inject(snapshot, targetFocus: focus)
      },
      completeUse: { _ in await probe.markUsed(item.id) },
      failUse: { _ in },
      reportFailure: { message in await probe.recordFailure(message) }
    )

    let result = await probe.snapshot()
    XCTAssertEqual(result.captureCount, 1)
    XCTAssertTrue(result.deliveredItemIDs.isEmpty)
    XCTAssertTrue(result.deliveredContexts.isEmpty)
    XCTAssertNil(result.injectedSnapshot)
    XCTAssertNil(result.targetFocus)
    XCTAssertTrue(result.markedItemIDs.isEmpty)
    XCTAssertEqual(
      result.failures,
      ["Clipboard paste was blocked because the restored target application changed."]
    )
  }

  func testWorkflowExplanationActionUsesPrivacyOnlyEvaluationWithoutConfirmation() async throws {
    let selectionCanary = "PRIVATE-SELECTION-CANARY"
    let clipboardCanary = "PRIVATE-CLIPBOARD-CANARY"
    let probe = AppBootstrapExplanationProbe()
    let context = ContextSnapshot(
      focus: FocusSnapshot(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        processIdentifier: 42,
        focusedRole: "AXTextArea",
        selectedText: selectionCanary,
        secureInput: true
      ),
      clipboard: ClipboardSnapshot(
        plainText: clipboardCanary,
        changeCount: 7
      )
    )
    let gate = PrivacyRunGate(
      settingsProvider: {
        PrivacyPolicySettings(
          sensitiveAppRules: [],
          cloudConfirmationRequired: true
        )
      },
      cloudConfirmationProvider: { _, _, _ in
        await probe.recordConfirmation()
        return true
      }
    )
    let service = WorkflowExplainService(
      recognizerRegistry: SpeechRecognizerRegistry(
        recognizers: [AppBootstrapExplanationRecognizer()]
      ),
      transformerRegistry: TextTransformerRegistry(
        transformers: [AppBootstrapExplanationTransformer()]
      ),
      actionRegistry: OutputActionRegistry(
        actions: [AppBootstrapExplanationAction()]
      )
    )
    let workflow = WorkflowDefinition(
      name: "Cloud text preview",
      trigger: .manual,
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        postProcessSteps: [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")],
        outputActions: [OutputActionReference(id: "inject.text")]
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
    let plan: WorkflowResolvedExecutionPlan
    switch WorkflowExecutionPlanResolver.resolve(
      workflow,
      initiatedBy: .manual,
      recognizer: .declared,
      output: .declared
    ) {
    case .resolved(let resolved):
      plan = resolved
    case .blocked:
      return XCTFail("Expected a resolved workflow plan")
    }
    let action = AppBootstrap.makeWorkflowExplanationAction(
      service: service,
      privacyRunGate: gate,
      privacyContextProvider: {
        await probe.capture(context)
      }
    )

    let receipt = await action(plan)
    let calls = await probe.snapshot()
    let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

    XCTAssertEqual(calls.privacyCaptures, 1)
    XCTAssertEqual(calls.confirmations, 0)
    XCTAssertEqual(receipt.status, .requiresConfirmation)
    XCTAssertTrue(receipt.privacyReasons.contains(.cloudConfirmationRequired))
    XCTAssertEqual(receipt.redactedInputCategories.count, 2)
    XCTAssertTrue(receipt.redactedInputCategories.contains(.focusedSelection))
    XCTAssertTrue(receipt.redactedInputCategories.contains(.clipboardText))
    XCTAssertFalse(encoded.contains(selectionCanary))
    XCTAssertFalse(encoded.contains(clipboardCanary))
    XCTAssertFalse(encoded.contains("com.apple.Notes"))
    XCTAssertFalse(encoded.contains("AXTextArea"))
  }





  func testPackagedRuntimeExcludesWebhookAndRetainsSecureExternalActions() {
    let registry = OutputActionRegistry(
      actions: AppBootstrap.makeExternalOutputActions(
        markdownCleanupCoordinator: MarkdownFileAppendCoordinator(
          cleanupDiagnosticReporter: { _ in }
        )
      )
    )

    XCTAssertNil(registry.action(for: ExternalOutputActionID.webhookPost))
    XCTAssertNotNil(registry.action(for: ExternalOutputActionID.shortcutsRun))
    XCTAssertNotNil(registry.action(for: ExternalOutputActionID.markdownAppend))
  }



  func testRecognitionRunPreflightBlocksLegacyClipboardAutomation() async {
    let preflight = AppBootstrap.makeRecognitionRunPreflight()
    let workflow = WorkflowDefinition(
      name: "Legacy Clipboard Automation",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
      metadata: ["eventType": "groupItemCreated"]
    )

    do {
      try await preflight(workflow)
      XCTFail("Expected legacy clipboard automation to fail preflight.")
    } catch let error as SessionCoordinator.SessionError {
      guard case .unsupportedWorkflow(.legacyClipboardAutomationUnsupported) = error else {
        return XCTFail("Unexpected preflight error: \(error)")
      }
    } catch {
      XCTFail("Unexpected preflight error: \(error)")
    }
  }

  func testRecognitionRunPreflightRejectsUnknownTrustedLocalModelOverride() async {
    let trustedModels = Set(SherpaOnnxModelID.allCases.map(\.rawValue))
    let preflight = AppBootstrap.makeRecognitionRunPreflight(
      trustedLocalModelIdentifiers: trustedModels
    )
    let workflow = WorkflowDefinition(
      name: "Unknown Local Model",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal"),
      metadata: [WorkflowMetadataKey.localSpeechModelOverride: "unreviewed-model"]
    )

    do {
      try await preflight(workflow)
      XCTFail("Expected an unknown local model override to fail closed.")
    } catch let error as LocalSpeechModelSelectionError {
      XCTAssertEqual(error, .unsupportedModelIdentifier("unreviewed-model"))
    } catch {
      XCTFail("Unexpected preflight error: \(error)")
    }
  }

  func testPublicDistributionExposesOnlyApprovedPinnedModels() async throws {
    var expectedModelIdentifiers = [SherpaOnnxModelID.qwen3ASR06BInt8.rawValue]
    #if arch(arm64)
      expectedModelIdentifiers.append(MLXAudioModelID.qwen3ASR06BInt8.rawValue)
      expectedModelIdentifiers.append(MLXAudioModelID.qwen3ASR17BInt8.rawValue)
    #endif
    XCTAssertEqual(
      AppBootstrap.distributableLocalSpeechModels.map(\.id),
      expectedModelIdentifiers
    )
    XCTAssertTrue(
      Set(expectedModelIdentifiers).isSubset(
        of: LocalSpeechModelCatalog.distributableModelIdentifiers
      )
    )
    XCTAssertEqual(
      AppBootstrap.distributableLocalSpeechModels.first?.id,
      SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    )
    XCTAssertEqual(
      AppBootstrap.distributableLocalSpeechModels.first?.recommendedSystemMemoryGiB,
      16
    )
    XCTAssertEqual(
      AppBootstrap.distributableLocalSpeechModels.map(\.hardwareRecommendationPriority),
      Array(10..<(10 + AppBootstrap.distributableLocalSpeechModels.count * 10)).filter {
        $0.isMultiple(of: 10)
      }
    )
    XCTAssertFalse(
      AppBootstrap.distributableLocalSpeechModels.contains {
        $0.quantization == .fp16
      }
    )
    XCTAssertTrue(
      AppBootstrap.distributableLocalSpeechModels.allSatisfy {
        $0.parameterCountMillions > 0
          && $0.recommendedSystemMemoryGiB >= $0.minimumSystemMemoryGiB
      }
    )
    #if arch(arm64)
      XCTAssertEqual(
        AppBootstrap.distributableLocalSpeechModels.map(\.englishName),
        [
          "Qwen3-ASR · 0.6B · INT8",
          "Qwen3-ASR · 0.6B · INT8",
          "Qwen3-ASR · 1.7B · INT8",
        ]
      )
      XCTAssertEqual(
        AppBootstrap.distributableLocalSpeechModels.map(\.engine),
        [.sherpaOnnx, .mlxAudioSwift, .mlxAudioSwift]
      )
      XCTAssertEqual(
        AppBootstrap.distributableLocalSpeechModels.map(\.simplifiedChineseName),
        AppBootstrap.distributableLocalSpeechModels.map(\.englishName)
      )
    #endif

    let normalized = try AppBootstrap.sherpaOnnxConfiguration(
      settings: LocalSpeechSettings(model: SherpaOnnxModelID.senseVoiceSmallInt8.rawValue)
    )
    XCTAssertEqual(normalized.modelIdentifier, SherpaOnnxModelID.qwen3ASR06BInt8.rawValue)
    let retiredVariant = try AppBootstrap.sherpaOnnxConfiguration(
      settings: LocalSpeechSettings(model: SherpaOnnxModelID.funASRNano08BFP16.rawValue),
      trustedModelIdentifiers: Set(expectedModelIdentifiers)
    )
    XCTAssertEqual(
      retiredVariant.modelIdentifier,
      SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    )
    let retiredCohere = try AppBootstrap.sherpaOnnxConfiguration(
      settings: LocalSpeechSettings(model: SherpaOnnxModelID.cohereTranscribe2BInt8.rawValue),
      trustedModelIdentifiers: Set(expectedModelIdentifiers)
    )
    XCTAssertEqual(
      retiredCohere.modelIdentifier,
      SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    )
    for candidate in [
      SherpaOnnxModelID.omnilingualASRCTCV2300MInt8,
      .omnilingualASRCTCV21BInt8,
    ] {
      let normalizedCandidate = try AppBootstrap.sherpaOnnxConfiguration(
        settings: LocalSpeechSettings(model: candidate.rawValue),
        trustedModelIdentifiers: Set(expectedModelIdentifiers)
      )
      XCTAssertEqual(
        normalizedCandidate.modelIdentifier,
        SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
      )
    }

    let workflow = WorkflowDefinition(
      name: "Preview Override",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal"),
      metadata: [
        WorkflowMetadataKey.localSpeechModelOverride:
          SherpaOnnxModelID.senseVoiceSmallInt8.rawValue
      ]
    )
    let preflight = AppBootstrap.makeRecognitionRunPreflight()

    do {
      try await preflight(workflow)
      XCTFail("A preview-only workflow override must fail before capture.")
    } catch {
      XCTAssertEqual(
        error as? LocalSpeechModelSelectionError,
        .unsupportedModelIdentifier(SherpaOnnxModelID.senseVoiceSmallInt8.rawValue)
      )
    }
  }

  func testBuiltinCatalogContainsSpeechRecognitionAndVoiceAssistant() throws {
    let workflows = BuiltinWorkflowCatalog().manifest().workflows

    XCTAssertEqual(workflows.map(\.titleKey), [.speechRecognition, .voiceAssistant])

    let speechRecognition = try XCTUnwrap(
      workflows.first { $0.titleKey == .speechRecognition }
    )
    XCTAssertEqual(speechRecognition.trigger, .hotkey)
    XCTAssertTrue(speechRecognition.prefersAutomaticRecognizerSelection)
    XCTAssertEqual(
      speechRecognition.plan.process.steps.map(\.kind),
      [.recognizeSpeech, .applyVocabulary, .normalizeWhitespace]
    )
    XCTAssertEqual(
      speechRecognition.plan.setup.vocabularyBindings.first?.uses,
      Set(VocabularyBindingUse.allCases)
    )
    XCTAssertEqual(speechRecognition.plan.output.actions.map(\.id), ["inject.text"])
    XCTAssertTrue(speechRecognition.isEnabledByDefault)

    let voiceAssistant = try XCTUnwrap(
      workflows.first { $0.titleKey == .voiceAssistant }
    )
    XCTAssertEqual(voiceAssistant.trigger, .wakeWord)
    XCTAssertTrue(voiceAssistant.prefersAutomaticRecognizerSelection)
    XCTAssertEqual(voiceAssistant.plan.setup.wakeWord?.phrases, ["Hey Rill"])
    XCTAssertEqual(
      voiceAssistant.plan.process.steps.map(\.kind),
      [.recognizeSpeech, .applyVocabulary, .normalizeWhitespace, .llmRewrite]
    )
    XCTAssertFalse(
      voiceAssistant.plan.process.steps.last?.prompt?.isEmpty ?? true
    )
    let speak = try XCTUnwrap(voiceAssistant.plan.output.actions.first)
    XCTAssertEqual(speak.id, SpeechOutputActionID.speak)
    XCTAssertEqual(
      speak.configuration[SpeechOutputActionConfigurationKey.provider],
      SpeechSynthesisProvider.automatic.rawValue
    )
    XCTAssertEqual(
      speak.configuration[SpeechOutputActionConfigurationKey.voice],
      Qwen3TTSVoice.vivian.rawValue
    )
    let assistantDraft = try XCTUnwrap(WorkflowEditorDraft(workflow: voiceAssistant))
    XCTAssertEqual(assistantDraft.destination, .speakOnly)
    XCTAssertTrue(assistantDraft.speaksResult)
    XCTAssertEqual(assistantDraft.speechVoice, .vivian)
    XCTAssertFalse(voiceAssistant.isEnabledByDefault)
  }

  func testRecognitionRunPreflightRequiresReadyLocalSpeechSessionSettings() async throws {
    let source = LocalSpeechSettingsSource()
    let trustedModels = Set(SherpaOnnxModelID.allCases.map(\.rawValue))
    let preflight = AppBootstrap.makeRecognitionRunPreflight(
      trustedLocalModelIdentifiers: trustedModels,
      localSpeechSettingsProvider: {
        try source.currentSettings()
      }
    )
    let workflow = WorkflowDefinition(
      name: "Local",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
    )

    do {
      try await preflight(workflow)
      XCTFail("Expected loading session settings to fail before capture.")
    } catch {
      XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .notReady)
      XCTAssertEqual(error.localizedDescription, "Local speech settings are still loading.")
    }

    source.update(LocalSpeechSettings(model: SherpaOnnxModelID.senseVoiceSmallInt8.rawValue))
    try await preflight(workflow)

    source.markUnavailable()
    do {
      try await preflight(workflow)
      XCTFail("Expected unavailable session settings to fail before capture.")
    } catch {
      XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .unavailable)
      XCTAssertEqual(error.localizedDescription, "Local speech settings are unavailable.")
    }
  }

  func testRecognitionRunPreflightRejectsConfiguredModelOutsideTrustedCatalog() async {
    let workflow = WorkflowDefinition(
      name: "Local",
      pipeline: PipelineDeclaration(
        recognizerID: "sherpa-onnx.local",
        outputActions: []
      ),
      ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
    )

    let preflight = AppBootstrap.makeRecognitionRunPreflight(
      trustedLocalModelIdentifiers: [SherpaOnnxModelID.qwen3ASR06BInt8.rawValue],
      localSpeechSettingsProvider: {
        LocalSpeechSettings(model: "unreviewed-model")
      }
    )

    do {
      try await preflight(workflow)
      XCTFail("Expected an untrusted configured model to fail before capture.")
    } catch let error as LocalSpeechModelSelectionError {
      XCTAssertEqual(error, .unsupportedModelIdentifier("unreviewed-model"))
    } catch {
      XCTFail("Unexpected preflight error: \(error)")
    }
  }

  func testSherpaConfigurationUsesOnlyReleaseCatalogIdentity() throws {
    let trustedModels = Set(SherpaOnnxModelID.allCases.map(\.rawValue))
    let selected = try AppBootstrap.sherpaOnnxConfiguration(
      settings: LocalSpeechSettings(
        model: " \(SherpaOnnxModelID.senseVoiceSmallInt8.rawValue) ",
        modelRepo: "ambient/repository",
        modelToken: "secret-canary",
        modelFolder: "/tmp/ambient-model",
        language: " zh ",
        downloadIfNeeded: false,
        prewarm: true
      ),
      trustedModelIdentifiers: trustedModels
    )
    XCTAssertEqual(selected.modelIdentifier, SherpaOnnxModelID.senseVoiceSmallInt8.rawValue)
    XCTAssertEqual(selected.language, "zh")
    XCTAssertFalse(selected.downloadIfNeeded)
    XCTAssertTrue(selected.prewarm)

    let normalized = try AppBootstrap.sherpaOnnxConfiguration(
      settings: LocalSpeechSettings(model: "unreviewed-model"),
      trustedModelIdentifiers: trustedModels,
      defaultModelIdentifier: SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    )
    XCTAssertEqual(normalized.modelIdentifier, SherpaOnnxModelID.qwen3ASR06BInt8.rawValue)

    XCTAssertThrowsError(
      try AppBootstrap.sherpaOnnxConfiguration(
        settings: LocalSpeechSettings(),
        trustedModelIdentifiers: trustedModels,
        defaultModelIdentifier: "missing-model"
      )
    ) { error in
      XCTAssertEqual(error as? SherpaOnnxModelInstallationError, .invalidCatalogDescriptor)
    }
  }

  func testSpeechWorkerLocationNeverFallsBackOutsideAnAppBundle() {
    let appBundle = URL(fileURLWithPath: "/Applications/Rill.app", isDirectory: true)
    let resolved = AppBootstrap.speechWorkerExecutableURL(
      bundleURL: appBundle,
      mainExecutableURL: URL(fileURLWithPath: "/tmp/unreviewed/RillApp")
    )

    XCTAssertEqual(
      resolved.path,
      "/Applications/Rill.app/Contents/Helpers/RillSpeechWorker"
    )

    let developmentExecutable = URL(
      fileURLWithPath: "/tmp/rill/.build/arm64-apple-macosx/debug/RillApp"
    )
    XCTAssertEqual(
      AppBootstrap.speechWorkerExecutableURL(
        bundleURL: developmentExecutable.deletingLastPathComponent(),
        mainExecutableURL: developmentExecutable
      ).path,
      "/tmp/rill/.build/arm64-apple-macosx/debug/RillSpeechWorker"
    )
  }

  func testSpeechWorkerAvailabilityRejectsSymlink() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("RillSpeechWorker")
    XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    XCTAssertTrue(AppBootstrap.speechWorkerExecutableIsAvailable(at: executable))

    let link = directory.appendingPathComponent("RillSpeechWorker-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    XCTAssertFalse(AppBootstrap.speechWorkerExecutableIsAvailable(at: link))
  }

  func testModelInstallationConfigurationCannotPrewarmInTheHostProcess() {
    let selected = SherpaOnnxRecognizer.Configuration(
      modelIdentifier: SherpaOnnxModelCatalog.defaultModelID.rawValue,
      language: "zh-CN",
      downloadIfNeeded: false,
      prewarm: true,
      threadCount: 4
    )

    let installation = AppBootstrap.modelInstallationConfiguration(from: selected)

    XCTAssertTrue(selected.prewarm)
    XCTAssertFalse(installation.prewarm)
    XCTAssertEqual(installation.modelIdentifier, selected.modelIdentifier)
    XCTAssertEqual(installation.language, selected.language)
    XCTAssertEqual(installation.downloadIfNeeded, selected.downloadIfNeeded)
    XCTAssertEqual(installation.threadCount, selected.threadCount)
  }

  func testLocalSpeechResourcePreparationWarmsAuthorizedAudioFrontendWhenEnabled() async throws {
    let probe = AppBootstrapLocalSpeechPreparationProbe()
    let model = try await AppBootstrap.prepareLocalSpeechModelAndAudioFrontend(
      prewarmAudioFrontend: true,
      prepareModel: { await probe.prepareModel() },
      prepareAudioFrontend: { await probe.prepareAudioFrontend() }
    )

    XCTAssertEqual(model, "prepared-model")
    let events = await probe.snapshot()
    XCTAssertEqual(events, [.model, .audioFrontend])
  }

  func testLocalSpeechResourcePreparationSkipsAudioFrontendWhenDisabled() async throws {
    let probe = AppBootstrapLocalSpeechPreparationProbe()
    let model = try await AppBootstrap.prepareLocalSpeechModelAndAudioFrontend(
      prewarmAudioFrontend: false,
      prepareModel: { await probe.prepareModel() },
      prepareAudioFrontend: { await probe.prepareAudioFrontend() }
    )

    XCTAssertEqual(model, "prepared-model")
    let events = await probe.snapshot()
    XCTAssertEqual(events, [.model])
  }

  func testStreamingPreviewPreparationIsBestEffortAfterFinalModel() async throws {
    enum PreviewFailure: Error { case unavailable }
    let probe = AppBootstrapLocalSpeechPreparationProbe()

    let prepared = try await AppBootstrap.prepareFinalModelAndStreamingPreview(
      prepareFinalModel: { await probe.prepareModel() },
      prepareStreamingPreview: {
        await probe.prepareStreamingPreview()
        throw PreviewFailure.unavailable
      },
      reportStreamingPreviewFailure: { _ in
        await probe.recordStreamingPreviewFailure()
      }
    )

    XCTAssertEqual(prepared, "prepared-model")
    let events = await probe.snapshot()
    XCTAssertEqual(
      events,
      [.model, .streamingPreview, .streamingPreviewFailure]
    )
  }

  func testStreamingPreviewPreparationPropagatesCancellation() async {
    do {
      _ = try await AppBootstrap.prepareFinalModelAndStreamingPreview(
        prepareFinalModel: { "prepared-model" },
        prepareStreamingPreview: { throw CancellationError() }
      )
      XCTFail("Cancellation must not be converted into optional preview loss.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testStartupPurgesRetiredWhisperCredentialWithoutChangingSherpaSettings() async throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/RillApp/AppBootstrap.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(
      source.range(of: "private static func startBackgroundServices(")
    )
    let end = try XCTUnwrap(
      source.range(
        of: "private static func makeContainer(",
        range: start.upperBound..<source.endIndex
      )
    )
    let startupBody = String(source[start.lowerBound..<end.lowerBound])
    let purgeCall = try XCTUnwrap(
      startupBody.range(
        of:
          #"platform\.credentialStore\.removeCredential\(\s*for:\s*\.legacyWhisperKitModelToken\s*\)"#,
        options: .regularExpression
      )
    )
    let manifestDiagnostic = try XCTUnwrap(
      startupBody.range(of: "runtime.workflowManifestStartupDiagnostic")
    )
    XCTAssertLessThan(
      startupBody.distance(from: startupBody.startIndex, to: purgeCall.lowerBound),
      startupBody.distance(from: startupBody.startIndex, to: manifestDiagnostic.lowerBound),
      "The retired credential purge must remain an application-startup operation."
    )

    let qwenModel = SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    let legacySettingsStore = AppBootstrapSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechModel: qwenModel,
        .legacyWhisperKitModelToken: "retired-sqlite-token",
        .localSpeechPrewarm: "true",
      ]
    )
    let keychainStore = AppBootstrapCredentialStore(
      storage: [
        .openAIAPIKey: "current-openai-key",
        .legacyWhisperKitModelToken: "retired-keychain-token",
      ]
    )
    let credentialStore = MigratingSecureCredentialStore(
      secureStore: keychainStore,
      legacySettingsStore: legacySettingsStore
    )

    try await credentialStore.removeCredential(for: .legacyWhisperKitModelToken)

    let retainedSettings = try await legacySettingsStore.strings(
      forKeys: [.preferredSpeechEngine, .localSpeechModel, .localSpeechPrewarm]
    )
    let retiredSQLiteToken = await legacySettingsStore.storedValue(for: .legacyWhisperKitModelToken)
    let retiredKeychainToken = await keychainStore.storedValue(for: .legacyWhisperKitModelToken)
    let currentOpenAIKey = await keychainStore.storedValue(for: .openAIAPIKey)
    let sqliteTokenRemovalCount =
      await legacySettingsStore.removalCount(for: .legacyWhisperKitModelToken)
    let keychainTokenRemovalCount =
      await keychainStore.removalCount(for: .legacyWhisperKitModelToken)
    let sherpaSettingRemovalCounts = await [
      legacySettingsStore.removalCount(for: .preferredSpeechEngine),
      legacySettingsStore.removalCount(for: .localSpeechModel),
      legacySettingsStore.removalCount(for: .localSpeechPrewarm),
    ]

    XCTAssertNil(retiredSQLiteToken)
    XCTAssertNil(retiredKeychainToken)
    XCTAssertEqual(
      retainedSettings,
      [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechModel: qwenModel,
        .localSpeechPrewarm: "true",
      ]
    )
    XCTAssertEqual(currentOpenAIKey, "current-openai-key")
    XCTAssertEqual(sqliteTokenRemovalCount, 1)
    XCTAssertEqual(keychainTokenRemovalCount, 1)
    XCTAssertEqual(sherpaSettingRemovalCounts, [0, 0, 0])
  }

  func testStartupPurgesRetiredCloudSpeechCredentialAndSettings() async throws {
    let localModel = SherpaOnnxModelID.qwen3ASR06BInt8.rawValue
    let settingsStore = AppBootstrapSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechModel: localModel,
        .retiredDeepgramAPIKey: "retired-sqlite-key",
        .retiredDeepgramBaseURL: "https://retired.example.invalid",
        .retiredDeepgramModel: "retired-model",
        .retiredDeepgramLanguage: "en",
      ]
    )
    let keychainStore = AppBootstrapCredentialStore(
      storage: [
        .openAIAPIKey: "current-openai-key",
        .retiredDeepgramAPIKey: "retired-keychain-key",
      ]
    )
    let credentialStore = MigratingSecureCredentialStore(
      secureStore: keychainStore,
      legacySettingsStore: settingsStore
    )

    await AppBootstrap.purgeRetiredCloudSpeechConfiguration(
      credentialStore: credentialStore,
      settingsStore: settingsStore
    )

    let retiredAPIKey = await settingsStore.storedValue(for: .retiredDeepgramAPIKey)
    let retiredBaseURL = await settingsStore.storedValue(for: .retiredDeepgramBaseURL)
    let retiredModel = await settingsStore.storedValue(for: .retiredDeepgramModel)
    let retiredLanguage = await settingsStore.storedValue(for: .retiredDeepgramLanguage)
    let retiredKeychainKey = await keychainStore.storedValue(for: .retiredDeepgramAPIKey)
    let currentOpenAIKey = await keychainStore.storedValue(for: .openAIAPIKey)
    let retainedEngine = try await settingsStore.string(forKey: .preferredSpeechEngine)
    let retainedModel = try await settingsStore.string(forKey: .localSpeechModel)

    XCTAssertNil(retiredAPIKey)
    XCTAssertNil(retiredBaseURL)
    XCTAssertNil(retiredModel)
    XCTAssertNil(retiredLanguage)
    XCTAssertNil(retiredKeychainKey)
    XCTAssertEqual(currentOpenAIKey, "current-openai-key")
    XCTAssertEqual(retainedEngine, PreferredSpeechEngine.local.rawValue)
    XCTAssertEqual(retainedModel, localModel)
  }

  func testClipboardGroupRegistrationKeepsExecutionSupportSeparateFromEnabledState() throws {
    let workflow = WorkflowDefinition(
      name: "Group Automation",
      pipeline: PipelineDeclaration(
        recognizerID: "context.selection",
        outputActions: [OutputActionReference(id: "clipboard.copy")]
      ),
      ui: WorkflowUIConfig(
        symbolName: "doc.on.clipboard",
        accentColorName: "blue"
      ),
      metadata: [
        WorkflowMetadataKey.legacyEventType: "groupItemCreated",
        WorkflowMetadataKey.legacySourceGroupID:
          ClipboardGroup.voiceGroupID.uuidString,
        WorkflowMetadataKey.legacyExcludePolishTag: "true",
        WorkflowMetadataKey.legacyGroupActionKind:
          ClipboardGroupActionKind.editItem.rawValue,
      ]
    )

    let registration = try XCTUnwrap(
      AppBootstrap.makeClipboardGroupWorkflowRegistration(
        for: workflow,
        isEnabled: false
      )
    )

    XCTAssertEqual(registration.workflowID, workflow.id)
    XCTAssertFalse(registration.isEnabled)
    XCTAssertFalse(registration.isExecutionSupported)
  }

  func testLocalHistoryMaintenanceUsesProtectedSettingsAndSeparateResiduePurger() async throws {
    let rawStore = AppBootstrapSettingsStore(storage: [:])
    let secureWebhookStore = AppBootstrapSecureWebhookStore()
    let protectedSettings = WebhookProtectingSettingsStore(
      settingsStore: rawStore,
      secureStore: secureWebhookStore
    )
    let eventRecorder = AppBootstrapMaintenanceEventRecorder()
    let maintenance = try XCTUnwrap(
      AppBootstrap.makeLocalHistoryMaintenance(
        clipboardHistory: AppBootstrapClipboardHistory(
          clearResult: ClipboardCleanupResult(
            removedCount: 2,
            preservedActiveCount: 1
          )
        ),
        historyRepository: AppBootstrapHistoryRepository(),
        runReceiptRepository: InMemoryWorkflowRunReceiptRepository(),
        diagnosticRepository: AppBootstrapDiagnosticRepository(),
        settingsStore: protectedSettings,
        residuePurger: rawStore,
        eventReporter: { event in
          await eventRecorder.record(event)
        }
      )
    )

    let result = await maintenance.clearClipboardHistory()
    let stateWriteCount = await rawStore.writeCount(for: .localHistoryMaintenanceState)
    let stateRemovalCount = await rawStore.removalCount(for: .localHistoryMaintenanceState)
    let rawPurgeCount = await rawStore.purgeCount()
    let secureWebhookCalls = await secureWebhookStore.calls()
    let events = await eventRecorder.recordedEvents()

    XCTAssertEqual(
      result,
      .completed(
        LocalHistoryMaintenanceCounts(
          clipboardRemovedCount: 2,
          preservedActiveClipboardCount: 1
        )
      )
    )
    XCTAssertEqual(stateWriteCount, 2)
    XCTAssertEqual(stateRemovalCount, 1)
    XCTAssertEqual(rawPurgeCount, 1)
    XCTAssertEqual(secureWebhookCalls, 0)
    XCTAssertEqual(events.map(\.outcome), [.completed])
  }

  func testLocalHistoryMaintenanceRequiresBothLogicalSettingsAndResiduePurger() {
    let clipboardHistory = AppBootstrapClipboardHistory(
      clearResult: ClipboardCleanupResult(removedCount: 0, preservedActiveCount: 0)
    )
    let historyRepository = AppBootstrapHistoryRepository()
    let diagnosticRepository = AppBootstrapDiagnosticRepository()
    let logicalSettings = AppBootstrapSettingsStore(storage: [:])

    XCTAssertNil(
      AppBootstrap.makeLocalHistoryMaintenance(
        clipboardHistory: clipboardHistory,
        historyRepository: historyRepository,
        runReceiptRepository: InMemoryWorkflowRunReceiptRepository(),
        diagnosticRepository: diagnosticRepository,
        settingsStore: nil,
        residuePurger: logicalSettings
      )
    )
    XCTAssertNil(
      AppBootstrap.makeLocalHistoryMaintenance(
        clipboardHistory: clipboardHistory,
        historyRepository: historyRepository,
        runReceiptRepository: InMemoryWorkflowRunReceiptRepository(),
        diagnosticRepository: diagnosticRepository,
        settingsStore: logicalSettings,
        residuePurger: nil
      )
    )
  }

  func testLocalHistoryMaintenanceWiresRunAndDiagnosticRepositoriesTogether() async throws {
    let store = AppBootstrapSettingsStore(storage: [:])
    let maintenance = try XCTUnwrap(
      AppBootstrap.makeLocalHistoryMaintenance(
        clipboardHistory: AppBootstrapClipboardHistory(
          clearResult: ClipboardCleanupResult(
            removedCount: 0,
            preservedActiveCount: 0
          )
        ),
        historyRepository: AppBootstrapHistoryRepository(clearCount: 2),
        runReceiptRepository: InMemoryWorkflowRunReceiptRepository(),
        diagnosticRepository: AppBootstrapDiagnosticRepository(clearCount: 3),
        settingsStore: store,
        residuePurger: store
      )
    )

    let result = await maintenance.clearRunHistory()

    XCTAssertEqual(
      result,
      .completed(
        LocalHistoryMaintenanceCounts(
          runRemovedCount: 2,
          diagnosticRemovedCount: 3
        )
      )
    )
  }

  func testLocalHistoryMaintenanceDiagnosticContainsOnlyCountsOutcomeAndReason() {
    let diagnostic = AppBootstrap.localHistoryMaintenanceDiagnostic(
      for: LocalHistoryMaintenanceEvent(
        outcome: .pending,
        counts: LocalHistoryMaintenanceCounts(
          clipboardRemovedCount: 3,
          runRemovedCount: 4,
          runReceiptRemovedCount: 6,
          diagnosticRemovedCount: 5,
          preservedActiveClipboardCount: 2
        ),
        pendingReason: .physicalPurgeFailed
      )
    )

    XCTAssertEqual(diagnostic.level, .warning)
    XCTAssertEqual(diagnostic.event, "history.maintenance.pending")
    XCTAssertEqual(
      diagnostic.metadata,
      [
        "outcome": "pending",
        "clipboardRemovedCount": "3",
        "runRemovedCount": "4",
        "runReceiptRemovedCount": "6",
        "diagnosticRemovedCount": "5",
        "preservedActiveClipboardCount": "2",
        "totalRemovedCount": "18",
        "pendingReason": "physical-purge-failed",
      ]
    )

    let blockedDiagnostic = AppBootstrap.localHistoryMaintenanceDiagnostic(
      for: LocalHistoryMaintenanceEvent(
        outcome: .blocked,
        counts: LocalHistoryMaintenanceCounts(),
        blockReason: .invalidPendingState
      )
    )
    XCTAssertEqual(blockedDiagnostic.level, .error)
    XCTAssertEqual(blockedDiagnostic.metadata["blockReason"], "invalid-pending-state")
  }


  func testLocalSpeechPreparationBoundaryMapsProviderErrorsToPayloadFreeStages() throws {
    let cases: [(any Error, LocalSpeechPreparationFailure.Stage)] = [
      (SherpaOnnxModelInstallationError.invalidCatalogDescriptor, .trustRoot),
      (SherpaOnnxModelInstallationError.downloadFailed, .resolution),
      (SherpaOnnxModelInstallationError.archiveDigestMismatch, .integrity),
      (
        SherpaOnnxRecognizer.RecognizerError.unsupportedModelIdentifier("unreviewed-model"),
        .trustRoot
      ),
      (SherpaOnnxRecognizer.RecognizerError.modelNotInstalled("qwen"), .resolution),
      (SherpaOnnxRecognizer.RecognizerError.invalidAudioFile, .runtime),
      (LocalSpeechModelSelectionError.unsupportedModelIdentifier("unreviewed"), .trustRoot),
      (SpeechWorkerClientError.remoteFailure(.modelUnavailable), .resolution),
      (SpeechWorkerClientError.requestTimedOut, .runtime),
    ]

    for (providerFailure, expectedStage) in cases {
      let failure = try XCTUnwrap(
        AppBootstrap.localSpeechPreparationFailure(for: providerFailure)
      )
      XCTAssertEqual(failure.stage, expectedStage)
      XCTAssertEqual(
        failure.localizedDescription,
        L10n.localSpeechPreparationFailure(expectedStage).english
      )
    }

    let canary = "path=/Users/private/model token=must-not-leak digest=0123456789abcdef"
    let unknown = NSError(
      domain: "AppBootstrapTests.provider",
      code: 7,
      userInfo: [NSLocalizedDescriptionKey: canary]
    )
    let generic = try XCTUnwrap(AppBootstrap.localSpeechPreparationFailure(for: unknown))
    XCTAssertEqual(generic.stage, .generic)
    XCTAssertEqual(
      generic.localizedDescription,
      L10n.localSpeechPreparationFailure(.generic).english
    )
    XCTAssertFalse(generic.localizedDescription.contains("/Users/private/model"))
    XCTAssertFalse(generic.localizedDescription.contains("must-not-leak"))
    XCTAssertFalse(generic.localizedDescription.contains("0123456789abcdef"))
    XCTAssertNil(AppBootstrap.localSpeechPreparationFailure(for: CancellationError()))
    XCTAssertNil(AppBootstrap.localSpeechPreparationFailure(for: URLError(.cancelled)))
  }

  func testWorkflowManifestResourceReturnsFixedMissingDiagnostic() {
    let result = WorkflowManifestResource.load(
      manifestURL: nil,
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [])
    )

    XCTAssertEqual(result.manifest, BuiltinWorkflowCatalog().manifest())
    XCTAssertEqual(result.diagnostic.event, "workflow-manifest.bundle.missing")
    XCTAssertEqual(result.diagnostic.level, .warning)
    XCTAssertEqual(
      result.diagnostic.metadata,
      [
        "reason": "resource-unavailable",
        "source": "packaged-resource",
      ]
    )
  }

  func testMLXModelUsesNativeSwiftBackendWithoutPythonRuntimeInstructions() throws {
    let modelID = MLXAudioModelID.qwen3ASR17BInt8.rawValue

    XCTAssertEqual(try LocalSpeechModelCatalog.backend(for: modelID), .mlxAudioSwift)
    #if arch(arm64)
      let model = try XCTUnwrap(
        AppBootstrap.distributableLocalSpeechModels.first { $0.id == modelID }
      )
      XCTAssertTrue(model.englishDetail.contains("native Swift MLX backend"))
      XCTAssertFalse(model.englishDetail.localizedCaseInsensitiveContains("python"))
      XCTAssertFalse(model.englishDetail.localizedCaseInsensitiveContains("uv"))
    #endif
  }

  func testWorkflowManifestResourceFallbackDiagnosticOmitsLoaderFailurePayload() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("BuiltinWorkflowManifest.json")
    let canary = "token=must-not-leak path=/Users/private/workflow-manifest.json"
    try Data("{\"invalid\":\"\(canary)\"}".utf8).write(to: manifestURL)

    let result = WorkflowManifestResource.load(
      manifestURL: manifestURL,
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [])
    )

    XCTAssertEqual(result.manifest, BuiltinWorkflowCatalog().manifest())
    XCTAssertEqual(result.diagnostic.event, "workflow-manifest.fallback")
    XCTAssertEqual(result.diagnostic.level, .warning)
    XCTAssertEqual(
      result.diagnostic.metadata,
      [
        "reason": "load-or-validation-failed",
        "source": "packaged-resource",
      ]
    )
    let serializedDiagnostic =
      ([result.diagnostic.message]
      + result.diagnostic.metadata.flatMap { [$0.key, $0.value] }).joined(separator: " ")
    XCTAssertFalse(serializedDiagnostic.contains(canary))
    XCTAssertFalse(serializedDiagnostic.contains(directory.path))
  }

  func testStartupTemporaryFileCleanupRemovesOrphanAndEmitsCountOnlyDiagnostic() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = directory.appendingPathComponent("rill-startup-orphan.wav")
    try Data("temporary".utf8).write(to: artifact)
    try FileManager.default.setAttributes(
      [
        .modificationDate: Date().addingTimeInterval(
          -RillTemporaryFileJanitor.defaultMinimumAge - 60
        )
      ],
      ofItemAtPath: artifact.path
    )
    let service = RillTemporaryFileCleanupService(
      janitor: RillTemporaryFileJanitor(temporaryDirectory: directory)
    )

    let diagnostic = await AppBootstrap.runStartupTemporaryFileCleanup(using: service)
    let sanitized = DiagnosticEventSanitizer.sanitize(diagnostic)

    XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    XCTAssertEqual(diagnostic.level, .info)
    XCTAssertEqual(diagnostic.event, "temporary-files.cleanup.completed")
    XCTAssertEqual(
      diagnostic.metadata,
      [
        "source": "startup",
        "temporaryFileRemovedCount": "1",
        "temporaryFileFailureCount": "0",
      ]
    )
    XCTAssertEqual(sanitized.metadata, diagnostic.metadata)
    XCTAssertFalse(diagnostic.metadata.values.contains { $0.contains(directory.path) })
  }

  func testStartupTemporaryFileCleanupFailureExposesOnlyCountAndType() async throws {
    let directory = try makeTemporaryDirectory()
    let parent = directory.deletingLastPathComponent()
    let link = parent.appendingPathComponent("rill-bootstrap-link-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    let service = RillTemporaryFileCleanupService(
      janitor: RillTemporaryFileJanitor(temporaryDirectory: link)
    )

    let diagnostic = await AppBootstrap.runStartupTemporaryFileCleanup(using: service)
    let sanitized = DiagnosticEventSanitizer.sanitize(diagnostic)

    XCTAssertEqual(diagnostic.level, .warning)
    XCTAssertEqual(diagnostic.event, "temporary-files.cleanup.pending")
    XCTAssertEqual(diagnostic.metadata["temporaryFileRemovedCount"], "0")
    XCTAssertEqual(diagnostic.metadata["temporaryFileFailureCount"], "1")
    XCTAssertEqual(
      diagnostic.metadata["temporaryFileFailureOperations"],
      "inspect-temporary-directory"
    )
    XCTAssertNil(diagnostic.metadata["temporaryFileFailureArtifactKinds"])
    XCTAssertEqual(sanitized.metadata, diagnostic.metadata)
    XCTAssertFalse(diagnostic.metadata.values.contains { $0.contains(link.path) })
    XCTAssertFalse(diagnostic.metadata.values.contains { $0.contains(directory.path) })
  }

  func testCloudPrivacyConfirmationCopyCoversSpeechTextMixedAndDefensiveDestinations() {
    let speechOnly = CloudPrivacyConfirmationCopy.informativeText(
      workflowName: "Voice",
      processingDestinations: [.cloudSpeech],
      usesChinese: false
    )
    XCTAssertTrue(speechOnly.contains("microphone audio"))
    XCTAssertTrue(speechOnly.contains("cloud-recognition terms"))
    XCTAssertTrue(speechOnly.contains("continuously checks"))
    XCTAssertTrue(speechOnly.contains("stops the run"))
    XCTAssertFalse(speechOnly.contains("final text"))

    let textOnly = CloudPrivacyConfirmationCopy.informativeText(
      workflowName: "Voice",
      processingDestinations: [.cloudText],
      usesChinese: false
    )
    XCTAssertTrue(textOnly.contains("final transcript"))
    XCTAssertTrue(textOnly.contains("configured cloud text service"))
    XCTAssertTrue(textOnly.contains("Always Allow"))
    XCTAssertTrue(textOnly.contains("Settings > Privacy"))
    XCTAssertFalse(textOnly.contains("microphone audio"))

    let mixed = CloudPrivacyConfirmationCopy.informativeText(
      workflowName: "Voice",
      processingDestinations: [.cloudSpeech, .cloudText],
      usesChinese: true
    )
    XCTAssertTrue(mixed.contains("麦克风音频"))
    XCTAssertTrue(mixed.contains("云端识别术语"))
    XCTAssertTrue(mixed.contains("最终转写"))
    XCTAssertTrue(mixed.contains("配置的云端文本服务"))
    XCTAssertTrue(mixed.contains("始终允许"))
    XCTAssertTrue(mixed.contains("设置 > 隐私"))

    let defensive = CloudPrivacyConfirmationCopy.informativeText(
      workflowName: "Voice",
      processingDestinations: [],
      usesChinese: false
    )
    XCTAssertTrue(defensive.contains("could not be classified"))
    XCTAssertTrue(defensive.contains("Nothing from this run has left this Mac yet"))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rill-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

}
