import RillPlatform
import AppKit
import RillCore
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class SmartCleanupRenderTests: XCTestCase {
  func testRenderActivityTextSteps() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for language in AppLanguage.allCases {
      let chinese = language == .simplifiedChinese
      let recognized =
        chinese
        ? "明天先检查地普西克的接口 然后嗯修复工作流重启后关闭的问题 最后补一下测试"
        : "Tomorrow check the deep seek API then um fix workflows turning off after restart and add tests"
      let replaced =
        chinese
        ? "明天先检查 DeepSeek 的接口 然后嗯修复工作流重启后关闭的问题 最后补一下测试"
        : "Tomorrow check the DeepSeek API then um fix workflows turning off after restart and add tests"
      let cleaned =
        chinese
        ? "明天需要完成：\n1. 检查 DeepSeek 的接口。\n2. 修复工作流重启后关闭的问题。\n3. 补充测试。"
        : "Tomorrow:\n1. Check the DeepSeek API.\n2. Fix workflows turning off after restart.\n3. Add tests."
      let steps = [
        WorkflowTextStep(kind: .recognizeSpeech, outputText: recognized),
        WorkflowTextStep(kind: .applyVocabulary, outputText: replaced, didChange: true),
        WorkflowTextStep(kind: .normalizeWhitespace, outputText: replaced, didChange: false),
        WorkflowTextStep(
          kind: .llmRewrite, outputText: cleaned, didChange: true,
          tokenUsage: .init(inputTokens: 312, outputTokens: 86, totalTokens: 398)),
      ]
      for dark in [false, true] {
        let surface = VStack(alignment: .leading, spacing: 12) {
          Text(chinese ? "智能整理 · 详细日志" : "Smart Cleanup · Details").font(.title2.weight(.semibold))
          HistoryTextStepsView(steps: steps, previewMode: .full, language: language)
          Divider()
          Text(chinese ? "润色跳过时" : "When cleanup is skipped").font(.headline)
          HistoryTextStepsView(
            steps: [
              WorkflowTextStep(kind: .llmRewrite, result: .skipped, outputText: replaced)
            ], previewMode: .restricted, language: language)
        }.padding(24)
        let size = NSSize(width: 700, height: 700)
        let view = NSHostingView(
          rootView:
            surface
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        for _ in 0..<5 { await Task.yield() }
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("activity-steps-\(language.rawValue)-\(dark ? "dark" : "light").png"))
        window.close()
      }
    }
  }

  func testRenderCleanupSettingsAndWorkflowFiles() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    let dictation = try XCTUnwrap(workflows.first { $0.titleKey == .speechRecognition })
    for language in AppLanguage.allCases {
      for dark in [false, true] {
        let decision = JevPanelFixture()
        let ttsOptions = [
          TTSModelOption(id: "tts-4bit", precision: "INT4", approximateDownloadByteCount: 1_694_000_000, isDefault: false),
          TTSModelOption(id: "tts-8bit", precision: "INT8", approximateDownloadByteCount: 1_974_000_000, isDefault: true),
          TTSModelOption(id: "tts-bf16", precision: "BF16", approximateDownloadByteCount: 2_500_000_000, isDefault: false),
        ]
        let model = makeHarness(
          workflows: workflows,
          settingsStore: UITestSettingsStore(storage: [
            .openAIBaseURL: LLMTextProcessing.deepSeekBaseURL,
            .openAIModel: LLMTextProcessing.deepSeekModel,
          ]),
          ttsModelOptions: ttsOptions, defaultTTSModelIdentifier: "tts-8bit",
          recordWorkspace: RecordWorkspaceModel(store: decision.store, cloudRanking: decision.service)
        ).model
        await model.waitForInitialVoiceConfiguration()
        model.setInterfaceLanguage(language)
        model.vocabulary.addVocabularyEntry(to: VocabularyCollection.personalID, kind: .hotword, pattern: "Rill")
        model.vocabulary.addVocabularyEntry(to: VocabularyCollection.personalID, kind: .mapping, pattern: "地普西克", replacement: "DeepSeek")
        let surfaces: [(String, AnyView, NSSize)] = [
          (
            "vocabulary-manager", AnyView(VocabularyCollectionCard(model: model, collection: model.vocabulary.vocabularyCollections[0]).padding(24)),
            NSSize(width: 560, height: 360)
          ),
          ("llm-provider", AnyView(SettingsView(model: model, pane: .voice).llmProviderSettingsSection.padding(24)), NSSize(width: 720, height: 760)),
          ("llm-provider-compact", AnyView(SettingsView(model: model, pane: .voice).llmProviderSettingsSection.padding(20)), NSSize(width: 480, height: 880)),
          (
            "decision-provider-compact", AnyView(SettingsView(model: model, pane: .voice).decisionProviderSettingsSection.padding(20)),
            NSSize(width: 480, height: 680)
          ),
          ("tts-provider-compact", AnyView(SettingsView(model: model, pane: .voice).ttsServiceSettingsSection.padding(20)), NSSize(width: 480, height: 680)),
          ("asr-provider-compact", AnyView(SettingsView(model: model, pane: .voice).speechEngineSection.padding(20)), NSSize(width: 480, height: 880)),
          (
            "workflow-outputs-compact",
            AnyView(
              VStack(alignment: .leading) {
                WorkflowOutputChoices(model: model, workflow: dictation)
              }.padding(20)), NSSize(width: 360, height: 220)
          ),
          ("workflow-files", AnyView(WorkflowsView(model: model)), NSSize(width: 960, height: 540)),
        ]
        for (name, surface, size) in surfaces {
          let view = NSHostingView(
            rootView:
              surface
              .frame(width: size.width, height: size.height, alignment: .topLeading)
              .clipped()
              .environment(\.colorScheme, dark ? .dark : .light)
              .background(Color(nsColor: .windowBackgroundColor)))
          let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
          window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
          window.isReleasedWhenClosed = false
          window.contentView = view
          view.frame = NSRect(origin: .zero, size: size)
          window.layoutIfNeeded()
          for _ in 0..<5 { await Task.yield() }
          view.layoutSubtreeIfNeeded()
          let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
          view.cacheDisplay(in: view.bounds, to: representation)
          let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
          try png.write(to: output.appendingPathComponent("\(name)-\(language.rawValue)-\(dark ? "dark" : "light").png"))
          window.close()
        }
        await model.recordWorkspace.shutdown()
        await model.stopSettingsReadTasksForApplicationShutdown()
        await model.flushPendingPersistenceWrites()
      }
    }
  }
}
