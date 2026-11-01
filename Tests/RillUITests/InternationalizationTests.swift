import Foundation
import RillCore
import RillInputMethodContracts
import RillPlatform
import RillRecords
import RillTestSupport
import Testing

@testable import RillUI

@MainActor
struct InternationalizationTests {
  @Test func negotiatesSupportedLanguagesInPreferenceOrder() {
    #expect(AppLanguage.preferred(for: ["fr-FR", "zh-Hans", "en-US"]) == .simplifiedChinese)
    #expect(AppLanguage.preferred(for: ["de-DE", "en-GB", "zh-Hans"]) == .english)
    #expect(AppLanguage.preferred(for: ["zh-TW", "en"]) == .simplifiedChinese)
    #expect(AppLanguage.preferred(for: ["fr", "de"]) == .english)
    #expect(AppLanguage.preferred(for: []) == .english)
  }

  @Test(arguments: AppLanguage.allCases)
  func formattingUsesAppLanguageAndPreservesRegionalPreferences(language: AppLanguage) {
    let region = Locale(identifier: "de_DE@hours=h23;numbers=latn;calendar=gregorian")
    let locale = language.formattingLocale(region: region)
    #expect(locale.language.languageCode?.identifier == (language == .english ? "en" : "zh"))
    #expect(locale.region == region.region)
    #expect(locale.hourCycle == region.hourCycle)
    #expect(locale.numberingSystem == region.numberingSystem)
    #expect(locale.calendar.identifier == region.calendar.identifier)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    let text = formatter.localizedString(fromTimeInterval: -60)
    #expect(text == (language == .english ? "1 minute ago" : "1分钟前"))
  }

  @Test func countsUsePluralRulesAndPreserveUserContent() {
    for count in [0, 1, 2, 1200] {
      #expect(L10n.routeWorkflowsCount(count, language: .english) == "\(count) \(count == 1 ? "workflow" : "workflows")")
      #expect(L10n.workflowVocabularyEntryCount(count, language: .english) == "\(count) \(count == 1 ? "entry" : "entries")")
      #expect(
        L10n.inputMethodSuggestionDetail(count: count, applications: "50% %@ Notes", language: .english)
          == "\(count) \(count == 1 ? "time" : "times") · 50% %@ Notes")
      #expect(L10n.inputMethodSuggestionDetail(count: count, applications: "50% %@ Notes", language: .simplifiedChinese) == "\(count) 次 · 50% %@ Notes")
    }
  }

  @Test func installationFailuresAndSuccessCanSwitchLanguageWithoutReinstalling() async throws {
    var fails = true
    var actual = InputMethodInstallationState.notInstalled
    let model = InputMethodFeatureModel(
      settings: UITestSettingsStore(), privacy: { .defaults },
      confirmRule: { _, id in (id, true) }, revokeRule: { _ in Issue.record("Installation unexpectedly revoked a vocabulary rule") },
      install: { _ in
        actual = fails ? .registrationPending : .registered
        if fails { throw InputMethodRegistrationError.unavailable }
      }, inspectInstallation: { actual })
    await model.installInputMethod()
    #expect(model.installationState == .registrationPending)
    let error = try #require(model.error)
    #expect(error.english.contains("Log out and back in"))
    #expect(error.simplifiedChinese.contains("注销并重新登录"))
    #expect(error.english.contains("Reinstallation is unnecessary"))
    fails = false
    await model.installInputMethod()
    let status = try #require(model.status)
    #expect(status.english.contains("dictionary were preserved"))
    #expect(status.simplifiedChinese.contains("词库已保留"))
    #expect(model.installationState == .registered)
    await model.shutdown()
  }

  @Test func recordFailureKeepsDiagnosticsAndLocalizesItsPrimaryMessage() async throws {
    let model = RecordWorkspaceModel(store: RecordStore())
    await model.addRecord(RecordID(), to: [RecordCollection.inboxID])
    let failure = try #require(model.errorPresentation)
    #expect(failure.english == "The selected record is unavailable.")
    #expect(failure.simplifiedChinese == "所选记录不可用。")
    #expect(model.errorMessage == "The selected record is unavailable.")
    model.dismissError()
    #expect(model.errorMessage == nil)
    #expect(model.errorPresentation == nil)
    await model.shutdown()
  }

  @Test func existingRunSpeechAndPrivacyFailuresFollowLanguageChanges() async throws {
    let model = makeHarness(
      settingsStore: UITestSettingsStore(
        storage: [.localSpeechPrewarm: "false"], failingSetKeys: [.privacyHistoryPreviewMode]),
      prepareLocalSpeechAction: { _, _ in throw CocoaError(.fileReadCorruptFile) }
    ).model
    await model.waitForInitialVoiceConfiguration()
    model.applyLanguage(.english)
    model.handle(.runFailed(runID: nil, workflow: nil, message: "Microphone access is required. Grant access in System Settings and retry."))
    model.prepareLocalSpeechModel()
    await model.voice.waitForLocalSpeechPreparation()
    model.setPrivacyHistoryPreviewMode(.disabled)
    await model.settings.writes.flush()
    let englishRun = try #require(model.lastFailure)
    let englishSpeech = try #require(model.voice.localSpeechPreparationError)
    let englishPrivacy = try #require(model.settings.privacySettingsSaveError)
    model.applyLanguage(.simplifiedChinese)
    #expect(model.lastFailure != englishRun)
    #expect(model.lastFailure?.contains("麦克风") == true)
    #expect(model.voice.localSpeechPreparationError != englishSpeech)
    #expect(model.settings.privacySettingsSaveError != englishPrivacy)
    model.applyLanguage(.english)
    #expect(model.lastFailure == englishRun)
    #expect(model.voice.localSpeechPreparationError == englishSpeech)
    #expect(model.settings.privacySettingsSaveError == englishPrivacy)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.stopLocalSpeechPreparationForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test(arguments: [4, 5])
  func workflowFileFailuresSwitchLanguageAndPreserveParserDetails(issueCount: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = "name = ["
    try source.write(to: directory.appendingPathComponent("50% workflow.toml"), atomically: true, encoding: .utf8)
    for index in 1..<issueCount {
      try source.write(to: directory.appendingPathComponent("extra-\(index).toml"), atomically: true, encoding: .utf8)
    }
    let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
    let model = makeHarness(settingsStore: UITestSettingsStore(), workflowFileStore: store).model
    await model.waitForInitialVoiceConfiguration()
    model.applyLanguage(.simplifiedChinese)
    #expect(model.workflowLibrary.workflowLibraryError?.contains("无法解析或验证 TOML 文档") == true)
    #expect(model.workflowLibrary.workflowLibraryError?.contains("50% workflow.toml") == true)
    #expect(model.workflowLibrary.workflowLibraryError?.contains("另外还有 \(issueCount - 3) 个文件问题") == true)
    let diagnostics = try #require(model.workflowLibrary.workflowFileIssues.first?.message)
    model.applyLanguage(.english)
    #expect(model.workflowLibrary.workflowLibraryError?.contains("could not be parsed or validated") == true)
    #expect(model.workflowLibrary.workflowLibraryError?.contains(diagnostics) == true)
    let extraIssues = issueCount - 3
    #expect(model.workflowLibrary.workflowLibraryError?.contains("\(extraIssues) additional file \(extraIssues == 1 ? "issue" : "issues"))") == true)
    let oversized = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: oversized) }
    try String(repeating: " ", count: XDGWorkflowFileStore.maximumFileSize + 1).write(to: oversized, atomically: true, encoding: .utf8)
    #expect(await model.importWorkflowFile(from: oversized) == nil)
    #expect(model.workflowLibrary.workflowLibraryError?.contains("exceeds the 1 MiB size limit") == true)
    model.applyLanguage(.simplifiedChinese)
    #expect(model.workflowLibrary.workflowLibraryError?.contains("超过 1 MiB") == true)
    #expect(try String(contentsOf: directory.appendingPathComponent("50% workflow.toml"), encoding: .utf8) == source)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func wakeWorkflowValidationFailureUsesItsDiagnosticAndFollowsLanguageChanges() async throws {
    let validationError = NSError(
      domain: "WakePhraseValidation", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "The wake phrase is not in the selected model vocabulary (50%)."])
    let validationLog = ProbeActionLog()
    let model = makeHarness(
      workflowFileStore: WakeWorkflowSaveFailureStore(),
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: { _ in
        await validationLog.increment()
        throw validationError
      })
    ).model
    await model.waitForInitialVoiceConfiguration()
    model.applyLanguage(.english)
    await model.saveWorkflowDraft(
      WorkflowEditorDraft(
        name: "Wake Assistant", eventType: .wakeWord,
        wakePhrasesText: "Hey Rill", destination: .copyToClipboard))
    #expect(await validationLog.snapshot() == 1)
    #expect(model.workflowLibrary.customWorkflows.isEmpty)
    let english = try #require(model.workflowLibrary.workflowEditorError)
    #expect(english == L10n.runWakeWordWorkflowSaveFailed(detail: validationError.localizedDescription, language: .english))
    model.applyLanguage(.simplifiedChinese)
    #expect(
      model.workflowLibrary.workflowEditorError
        == L10n.runWakeWordWorkflowSaveFailed(detail: validationError.localizedDescription, language: .simplifiedChinese))
    #expect(model.workflowLibrary.workflowEditorError != english)
    model.applyLanguage(.english)
    #expect(model.workflowLibrary.workflowEditorError == english)
    #expect(await validationLog.snapshot() == 1)
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func wakeWorkflowSaveFailureLocalizesAndPreservesItsDiagnostic() async throws {
    var workflow = makeDefaultWorkflow()
    workflow.trigger = .wakeWord
    workflow.plan.setup.wakeWord = WakeWordConfiguration(phrases: ["Hey Rill"])
    let model = makeHarness(
      workflows: [workflow], workflowFileStore: WakeWorkflowSaveFailureStore(),
      voiceResourceServices: makeVoiceResourceServicesForTesting(validateWakeWordConfiguration: { configuration in
        #expect(configuration.phrases == ["Hey Rill"])
      })
    ).model
    await model.waitForInitialVoiceConfiguration()
    let result = await model.updateWakeWordSettings(phrases: ["Hey Rill"], enableListening: false)
    guard case .failed(let message) = result else {
      Issue.record("Expected the workflow file save to fail")
      return
    }
    let diagnostic = WorkflowFileStoreError.unsupportedSchema(37).localizedDescription
    #expect(message.english.contains("The workflow TOML file could not be saved"))
    #expect(message.english.contains(diagnostic))
    #expect(message.simplifiedChinese.contains("无法保存工作流 TOML 文件"))
    #expect(message.simplifiedChinese.contains("版本"))
    #expect(message.simplifiedChinese.contains(diagnostic))
    await model.stopSettingsReadTasksForApplicationShutdown()
    await model.flushPendingPersistenceWrites()
  }

  @Test func builtinNamesPreserveCustomOverridesAndRecordContent() throws {
    #expect(L10n.collectionName(.inbox, language: .simplifiedChinese) == "收件箱")
    #expect(L10n.collectionName(.voiceInput, language: .simplifiedChinese) == "语音输入")
    var renamed = RecordCollection.inbox
    renamed.name = "我的 50% Inbox"
    #expect(L10n.collectionName(renamed, language: .english) == renamed.name)
    #expect(L10n.collectionName(renamed, language: .simplifiedChinese) == renamed.name)
    let speech = try #require(RecordBuffer.defaults.first { $0.id == RecordBuffer.speechID })
    #expect(L10n.bufferName(speech, language: .simplifiedChinese) == "语音")
    let provenance = RecordProvenance(source: .init(kind: .systemClipboard))
    let header = RecordHeader(record: Record(payload: .image(Data()), provenance: provenance), byteCount: 0)
    #expect(L10n.recordPreview(header, language: .simplifiedChinese) == "图片")
    #expect(L10n.recordSource(provenance, language: .simplifiedChinese) == "系统剪贴板")
    #expect(L10n.recordSource(provenance, language: .english) == "System Clipboard")
  }
}

private struct WakeWorkflowSaveFailureStore: WorkflowFileStore {
  let configurationDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  func load() async -> WorkflowFileLoadResult { .init() }
  func save(workflow _: WorkflowDefinition, isEnabled _: Bool, replacing _: URL?) async throws -> URL {
    throw WorkflowFileStoreError.unsupportedSchema(37)
  }
  func saveDocument(_ document: WorkflowDocument, replacing fileURL: URL?, expected: WorkflowFileExpectation) async throws -> WorkflowFileRecord {
    throw WorkflowFileStoreError.unsupportedSchema(37)
  }
  func delete(fileURL _: URL) async throws { throw WorkflowFileStoreError.unsupportedSchema(37) }
}
