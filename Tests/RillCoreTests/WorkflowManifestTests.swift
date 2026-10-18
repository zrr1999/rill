import Foundation
import RillCore
import Testing

struct WorkflowManifestTests {
  @Test func declarationOwnsEnablementAndPreview() {
    var route = WorkflowSpeechRoute(recognizerID: "local-speech")
    route.livePreviewPlacement = .cursor
    var workflow = WorkflowDefinition(
      name: "Dictation", plan: .init(setup: .init(speechRoute: route), process: .init(steps: [.init(kind: .recognizeSpeech)]), output: .init(actions: [])),
      ui: .init(symbolName: "mic", accentColorName: "blue"))
    #expect(workflow.resolvedLivePreviewPlacement == .cursor)
    workflow.plan.setup.speechRoute?.livePreviewEnabled = false
    #expect(workflow.resolvedLivePreviewPlacement == .overlay)
    workflow.properties.defaultEnabled = false
    #expect(!workflow.isEnabledByDefault)
    workflow.properties.availability = .planned
    #expect(workflow.availability == .planned)
  }
}
