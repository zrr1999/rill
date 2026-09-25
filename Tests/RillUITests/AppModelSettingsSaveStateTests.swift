import XCTest

@testable import RillCore
@testable import RillUI

private enum FailThenSucceedSettingsStoreError: LocalizedError {
  case rejected

  var errorDescription: String? {
    "DO_NOT_LEAK_SETTINGS_STORE_DETAIL"
  }
}

private actor FailThenSucceedSettingsStore: SettingsStore {
  private var storage: [AppSettingKey: String] = [:]
  private var remainingFailures: [AppSettingKey: Int]
  private var writeAttempts: [AppSettingKey: Int] = [:]

  init(
    storage: [AppSettingKey: String] = [:],
    failures: [AppSettingKey: Int]
  ) {
    self.storage = storage
    remainingFailures = failures
  }

  func string(forKey key: AppSettingKey) async throws -> String? {
    storage[key]
  }

  func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
    keys.reduce(into: [:]) { result, key in
      result[key] = storage[key]
    }
  }

  func setString(_ value: String, forKey key: AppSettingKey) async throws {
    try recordAttempt(for: key)
    storage[key] = value
  }

  func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    for key in values.keys {
      try recordAttempt(for: key)
    }
    storage.merge(values) { _, newValue in newValue }
  }

  func removeValue(forKey key: AppSettingKey) async throws {
    try recordAttempt(for: key)
    storage[key] = nil
  }

  func snapshot(for key: AppSettingKey) -> (value: String?, attempts: Int) {
    (storage[key], writeAttempts[key, default: 0])
  }

  private func recordAttempt(for key: AppSettingKey) throws {
    writeAttempts[key, default: 0] += 1
    let failures = remainingFailures[key, default: 0]
    guard failures > 0 else { return }
    remainingFailures[key] = failures - 1
    throw FailThenSucceedSettingsStoreError.rejected
  }
}

private actor ShutdownRetryDelayProbe {
  private var delays: [Duration] = []

  func record(_ delay: Duration) {
    delays.append(delay)
  }

  func snapshot() -> [Duration] {
    delays
  }
}

private actor ShutdownDrainCompletionProbe {
  private var completed = false

  func markCompleted() {
    completed = true
  }

  func isCompleted() -> Bool {
    completed
  }
}

@MainActor
final class AppModelSettingsSaveStateTests: XCTestCase {
  func testLegacyLocalModelMigrationFailureIsVisibleAndRetryable() async throws {
    let defaultModel = "qwen3-asr-0.6b-int8"
    let store = FailThenSucceedSettingsStore(
      storage: [.localSpeechModel: "breeze-asr-25"],
      failures: [.localSpeechModel: 1]
    )
    let source = LocalSpeechSettingsSource()
    let models = [
      LocalSpeechModelDescriptor(
        id: defaultModel,
        englishName: "Qwen3-ASR 0.6B INT8",
        simplifiedChineseName: "Qwen3-ASR 0.6B INT8"
      ),
      LocalSpeechModelDescriptor(
        id: "sense-voice-small-int8",
        englishName: "SenseVoiceSmall INT8",
        simplifiedChineseName: "SenseVoiceSmall INT8"
      ),
    ]
    let harness = makeHarness(
      settingsStore: store,
      localSpeechSettingsSource: source,
      settingsWriteDebounceDuration: .zero,
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: defaultModel
    )

    await harness.model.waitForInitialVoiceConfiguration()
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertFalse(harness.model.settings.isLoading)
    XCTAssertEqual(harness.model.settings.localSpeechModel, defaultModel)
    XCTAssertEqual(try source.currentSettings().model, defaultModel)
    XCTAssertEqual(
      harness.model.settingsSaveState,
      .unsaved(
        UnsavedSettingsSummary(
          affectedChangeCount: 1,
          categories: [.speech]
        )
      )
    )
    var snapshot = await store.snapshot(for: .localSpeechModel)
    XCTAssertEqual(snapshot.value, "breeze-asr-25")
    XCTAssertEqual(snapshot.attempts, 1)

    harness.model.retryUnsavedSettingsSave()
    XCTAssertTrue(harness.model.settingsSaveState.isRetrying)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.settingsSaveState, .saved)
    snapshot = await store.snapshot(for: .localSpeechModel)
    XCTAssertEqual(snapshot.value, defaultModel)
    XCTAssertEqual(snapshot.attempts, 2)
  }

  func testWhisperKitSelectionPublishesBeforeDebouncedWriteAndSurvivesWriteFailure() async throws {
    let store = FailThenSucceedSettingsStore(failures: [.localSpeechModel: 1])
    let source = LocalSpeechSettingsSource()
    let models = [
      LocalSpeechModelDescriptor(
        id: "trusted-multilingual",
        englishName: "Multilingual",
        simplifiedChineseName: "多语种"
      ),
      LocalSpeechModelDescriptor(
        id: "trusted-cantonese",
        englishName: "Cantonese",
        simplifiedChineseName: "粤语"
      ),
    ]
    let harness = makeHarness(
      settingsStore: store,
      localSpeechSettingsSource: source,
      settingsWriteDebounceDuration: .milliseconds(50),
      trustedLocalSpeechModels: models,
      defaultLocalSpeechModelIdentifier: "trusted-multilingual"
    )
    await harness.model.waitForInitialVoiceConfiguration()
    XCTAssertEqual(try source.currentSettings().model, "trusted-multilingual")

    harness.model.applyLocalSpeechModel("trusted-cantonese")

    // Global hotkey capture reads this source directly, so it must observe
    // the UI selection before the debounced durable write starts.
    XCTAssertEqual(try source.currentSettings().model, "trusted-cantonese")
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertNotEqual(harness.model.settingsSaveState, SettingsSaveState.saved)
    XCTAssertEqual(try source.currentSettings().model, "trusted-cantonese")
    let snapshot = await store.snapshot(for: .localSpeechModel)
    XCTAssertNil(snapshot.value)
    XCTAssertEqual(snapshot.attempts, 1)
  }

  func testScalarWriteFailureRemainsUnsavedUntilRetrySucceedsWithoutLeakingErrorDetail() async {
    let store = FailThenSucceedSettingsStore(failures: [.interfaceLanguage: 1])
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await harness.model.waitForInitialVoiceConfiguration()

    let updatedLanguage: AppLanguage =
      harness.model.settings.language == .english
      ? .simplifiedChinese
      : .english
    harness.model.applyLanguage(updatedLanguage)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(
      harness.model.settingsSaveState,
      .unsaved(
        UnsavedSettingsSummary(
          affectedChangeCount: 1,
          categories: [.interface]
        )
      )
    )
    XCTAssertTrue(
      harness.model.history.eventFeed.contains {
        $0.english == "Some settings could not be saved. Retry from Settings."
          && $0.simplifiedChinese == "部分设置无法保存，请在设置页面重试。"
      }
    )
    XCTAssertFalse(
      harness.model.history.eventFeed.contains {
        $0.english.contains("DO_NOT_LEAK_SETTINGS_STORE_DETAIL")
          || $0.simplifiedChinese.contains("DO_NOT_LEAK_SETTINGS_STORE_DETAIL")
          || $0.english.contains(AppSettingKey.interfaceLanguage.rawValue)
          || $0.simplifiedChinese.contains(AppSettingKey.interfaceLanguage.rawValue)
      }
    )

    harness.model.retryUnsavedSettingsSave()
    XCTAssertTrue(harness.model.settingsSaveState.isRetrying)
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.settingsSaveState, .saved)
    let snapshot = await store.snapshot(for: .interfaceLanguage)
    XCTAssertEqual(snapshot.value, updatedLanguage.rawValue)
    XCTAssertEqual(snapshot.attempts, 2)
  }

  func testCollectionWriteFailureRetriesTheExactVocabularySnapshotAndClearsState() async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let workflowLibrary = String(
      decoding: try encoder.encode(
        WorkflowLibraryDocument(customWorkflows: [])
      ),
      as: UTF8.self
    )
    let vocabularyLibrary = String(
      decoding: try encoder.encode(
        VocabularyLibraryDocument(collections: [.personal()])
      ),
      as: UTF8.self
    )
    let store = FailThenSucceedSettingsStore(
      storage: [
        .workflowLibrary: workflowLibrary,
        .vocabularyLibrary: vocabularyLibrary,
      ],
      failures: [.vocabularyLibrary: 1]
    )
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.addVocabularyRule(
      kind: .mapping,
      pattern: "product term",
      replacement: "Product Term",
      matchMode: .exactPhrase,
      caseSensitive: false,
      scope: .init()
    )
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(
      harness.model.settingsSaveState,
      .unsaved(
        UnsavedSettingsSummary(
          affectedChangeCount: 1,
          categories: [.vocabulary]
        )
      )
    )

    harness.model.retryUnsavedSettingsSave()
    await harness.model.flushPendingPersistenceWrites()

    XCTAssertEqual(harness.model.settingsSaveState, .saved)
    let snapshot = await store.snapshot(for: .vocabularyLibrary)
    XCTAssertEqual(snapshot.attempts, 2)
    let payload = try XCTUnwrap(snapshot.value)
    let library = try JSONDecoder().decode(
      VocabularyLibraryDocument.self,
      from: Data(payload.utf8)
    )
    let storedRules = library.collections.flatMap(\.entries)
    XCTAssertEqual(
      storedRules.compactMap { entry in
        if case .replacement(let pattern, _, _, _) = entry.content {
          return pattern
        }
        return nil
      },
      ["product term"]
    )
  }

  func testShutdownDrainImmediatelyRetriesAndRecoversUnsavedScalar() async {
    let store = FailThenSucceedSettingsStore(failures: [.interfaceLanguage: 1])
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await harness.model.waitForInitialVoiceConfiguration()
    let updatedLanguage: AppLanguage =
      harness.model.settings.language == .english
      ? .simplifiedChinese
      : .english
    harness.model.applyLanguage(updatedLanguage)

    await harness.model.drainPendingSettingsWritesForApplicationShutdown { _ in
      XCTFail("An immediately successful retry must not enter backoff.")
    }

    XCTAssertEqual(harness.model.settingsSaveState, .saved)
    let snapshot = await store.snapshot(for: .interfaceLanguage)
    XCTAssertEqual(snapshot.value, updatedLanguage.rawValue)
    XCTAssertEqual(snapshot.attempts, 2)
  }

  func testShutdownDrainUsesCappedBackoffUntilSettingsRecover() async {
    let store = FailThenSucceedSettingsStore(failures: [.interfaceLanguage: 7])
    let delays = ShutdownRetryDelayProbe()
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await harness.model.waitForInitialVoiceConfiguration()
    let updatedLanguage: AppLanguage =
      harness.model.settings.language == .english
      ? .simplifiedChinese
      : .english
    harness.model.applyLanguage(updatedLanguage)

    await harness.model.drainPendingSettingsWritesForApplicationShutdown { delay in
      await delays.record(delay)
    }

    let recordedDelays = await delays.snapshot()
    XCTAssertEqual(
      recordedDelays,
      [
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(8),
      ]
    )
    XCTAssertEqual(harness.model.settingsSaveState, .saved)
    let snapshot = await store.snapshot(for: .interfaceLanguage)
    XCTAssertEqual(snapshot.value, updatedLanguage.rawValue)
    XCTAssertEqual(snapshot.attempts, 8)
  }

  func testShutdownDrainDoesNotReturnWhileSettingsKeepFailing() async {
    let store = FailThenSucceedSettingsStore(
      failures: [.interfaceLanguage: .max]
    )
    let delays = ShutdownRetryDelayProbe()
    let completion = ShutdownDrainCompletionProbe()
    let harness = makeHarness(
      settingsStore: store,
      settingsWriteDebounceDuration: .zero
    )
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.applyLanguage(harness.model.settings.language == .english
      ? .simplifiedChinese
      : .english)

    let drainTask = Task {
      await harness.model.drainPendingSettingsWritesForApplicationShutdown { delay in
        await delays.record(delay)
        try await Task.sleep(for: .seconds(3_600))
      }
      await completion.markCompleted()
    }
    for _ in 0..<200 {
      if !(await delays.snapshot()).isEmpty { break }
      try? await Task.sleep(for: .milliseconds(5))
    }

    let recordedDelays = await delays.snapshot()
    let completedBeforeCancellation = await completion.isCompleted()
    XCTAssertEqual(recordedDelays, [.milliseconds(500)])
    XCTAssertFalse(completedBeforeCancellation)
    drainTask.cancel()
    await drainTask.value
    let completedAfterCancellation = await completion.isCompleted()
    XCTAssertTrue(completedAfterCancellation)
    XCTAssertNotEqual(harness.model.settingsSaveState, .saved)
  }

  func testUnsavedSettingsPresentationIsFixedAndBilingual() {
    let summary = UnsavedSettingsSummary(
      affectedChangeCount: 2,
      categories: [.speech, .workflows]
    )

    XCTAssertEqual(
      L10n.settingsSaveFailureDescription(summary, language: .english),
      "2 changes in Speech, Workflows are active only for this session. Retry before quitting Rill."
    )
    XCTAssertEqual(
      L10n.settingsSaveFailureDescription(summary, language: .simplifiedChinese),
      "语音、工作流中的 2 项更改仅在本次会话中有效。请在退出 Rill 前重试。"
    )
    XCTAssertEqual(
      L10n.text(.settingsSaveRetry, language: .simplifiedChinese),
      "重试保存"
    )
  }
}
