import Foundation
import Testing
@testable import RillCore

struct WorkflowActionConfigurationTests {
  @Test func protectedWebhookReferenceIsOnlyADeclaration() throws {
    let reference = "workflow.webhook.v1:a0f99d93-7e4d-46ce-a188-8b713ef229da:3"
    let values = WorkflowOutputParameters(webhookReference: reference)
    #expect(WorkflowOutputConfigurationRequirement.webhook.state(of: values, stage: .declaration) == .configured)
    #expect(WorkflowOutputConfigurationRequirement.webhook.state(of: values, stage: .resolved) == .missing)
    #expect(throws: (any Error).self) {
      try WorkflowActionConfiguration(.init(id: ExternalOutputActionID.webhookPost, configuration: values))
    }
  }

  @Test(arguments: ["notes.md", "notes.markdown", "notes.txt", "bad\u{0001}.md", ""])
  func declarationAndExecutionShareMarkdownValidation(_ path: String) {
    let values = WorkflowOutputParameters(markdownPath: path)
    let declared = WorkflowOutputConfigurationRequirement.markdownFile.state(of: values, stage: .declaration)
    let resolved = WorkflowOutputConfigurationRequirement.markdownFile.state(of: values, stage: .resolved)
    #expect(declared == resolved)
    let parsed = try? WorkflowActionConfiguration(.init(id: ExternalOutputActionID.markdownAppend, configuration: values))
    #expect((parsed != nil) == (resolved == .configured))
  }
  @Test func recordRoutesAndCaptureExclusionBelongToTheAction() throws {
    let collection = UUID()
    let action = OutputActionReference(id: RecordActionID.store, configuration: .init(collections: [collection], buffer: "speech", excludeFromCapture: false))
    let parsed = try WorkflowActionConfiguration(action)
    guard case .record(let collections, let buffer) = parsed else {
      Issue.record("Expected record configuration")
      return
    }
    #expect(collections == [RecordCollectionID(collection)])
    #expect(buffer)
    #expect(!action.configuration.excludeFromCapture)
  }

}
