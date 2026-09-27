import Foundation
import Testing
@testable import RillCore

struct WorkflowActionConfigurationTests {
  @Test func protectedWebhookReferenceIsOnlyADeclaration() throws {
    let reference = "workflow.webhook.v1:a0f99d93-7e4d-46ce-a188-8b713ef229da:3"
    let values = [ExternalOutputActionConfigurationKey.webhookSecureReference: reference]
    #expect(WorkflowOutputConfigurationRequirement.webhook.state(of: values, stage: .declaration) == .configured)
    #expect(WorkflowOutputConfigurationRequirement.webhook.state(of: values, stage: .resolved) == .missing)
    #expect(throws: (any Error).self) {
      try WorkflowActionConfiguration(.init(id: ExternalOutputActionID.webhookPost, configuration: values))
    }
  }

  @Test(arguments: ["notes.md", "notes.markdown", "notes.txt", "bad\u{0001}.md", ""])
  func declarationAndExecutionShareMarkdownValidation(_ path: String) {
    let values = [ExternalOutputActionConfigurationKey.markdownAppendPath: path]
    let declared = WorkflowOutputConfigurationRequirement.markdownFile.state(of: values, stage: .declaration)
    let resolved = WorkflowOutputConfigurationRequirement.markdownFile.state(of: values, stage: .resolved)
    #expect(declared == resolved)
    let parsed = try? WorkflowActionConfiguration(.init(id: ExternalOutputActionID.markdownAppend, configuration: values))
    #expect((parsed != nil) == (resolved == .configured))
  }
}
