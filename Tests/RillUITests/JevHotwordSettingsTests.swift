import Foundation
import Testing
import RillWorkflows
@testable import RillCore
@testable import RillUI

@MainActor
struct JevHotwordSettingsTests {
  @Test func settingsDefaultOffAndRevocationIsSynchronous() async throws {
    let context = ContextSnapshot(focus: .init(applicationName: "Editor", bundleIdentifier: "example.editor",
      processIdentifier: 42, focusedRole: "AXTextArea", selectedText: "", secureInput: false),
      clipboard: .init(plainText: "", changeCount: 0))
    let fixture = JevPanelFixture()
    let service = HotwordSelection(provider: NeverHotwordProvider(), settings: fixture.service.settings,
      privacy: .init(initialSettings: .defaults), currentFocus: { context.focus })
    let settings = JevAPISettingsModel(service: fixture.service, hotwordSelection: service)
    let workflow = WorkflowDefinition(name: "Dictation", pipeline: .init(recognizerID: "local-speech", outputActions: []),
      ui: .init(symbolName: "waveform", accentColorName: "blue"))
    func selection() throws -> HotwordSelection.Selection {
      let id = UUID()
      return try service.select(runID: id, workflow: workflow, collections: [], context: context,
        options: .init(modelID: "qwen"), candidates: [.init(id: UUID(), term: "Rill", priority: 0)],
        lifetime: .init(runID: id))
    }
    #expect(!settings.isHotwordSelectionEnabled)
    #expect(!settings.isConfigured)
    settings.setKey(" unit-test-key ")
    #expect(settings.isConfigured)
    #expect(!settings.isPolishingEnabled)
    #expect(try selection().status == .disabled)
    settings.isHotwordSelectionEnabled = true
    let ready = try selection()
    #expect(ready.status == .miss)
    settings.setKey("bad")
    #expect(settings.isHotwordSelectionEnabled)
    #expect(ready.preparation?.isFinished == false)
    settings.setKey("replacement-test-key")
    #expect(settings.isHotwordSelectionEnabled)
    #expect(!settings.isPolishingEnabled)
    #expect(ready.preparation?.isFinished == true)
    settings.isHotwordSelectionEnabled = false
    #expect(ready.preparation?.isFinished == true)
    #expect(try selection().status == .disabled)
    settings.isHotwordSelectionEnabled = true
    settings.setKey("")
    #expect(!settings.isConfigured)
    #expect(!settings.isHotwordSelectionEnabled)
    #expect(try selection().status == .disabled)
    await service.shutdown()
  }
}

private struct NeverHotwordProvider: HotwordRankingProvider {
  func score(_: HotwordRankingRequest, apiKey _: String) async throws -> [HotwordRankingScore] {
    Issue.record("Editing settings must not send requests.")
    throw HotwordRankingError.invalidInput
  }
}
