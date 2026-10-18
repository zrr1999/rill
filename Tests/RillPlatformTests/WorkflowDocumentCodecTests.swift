import Foundation
import RillCore
import RillPlatform
import Testing

struct WorkflowDocumentCodecTests {
  static let source = """
    schema_version = 1
    id = "54B31E01-96AC-4A0F-BB82-0A8CB12DD629"
    name = "Reply"
    enabled = false
    [trigger]
    kind = "manual"
    [input]
    kind = "text"
    [[process]]
    id = "rewrite"
    kind = "llm-rewrite"
    reasoning = "none"
    prompt = "Rewrite the supplied text."
    decision = { optional = true }
    [output]
    strategy = "immediate"
    [[output.actions]]
    id = "save"
    kind = "record.store"
    [[output.actions]]
    id = "copy"
    kind = "system-clipboard.copy"
    optional = true
    """
  @Test func roundTripPreservesExplicitIntentAndIdentity() throws {
    let codec = WorkflowDocumentCodec()
    let original = try codec.decode(Self.source)
    let encoded = try codec.encode(original)
    #expect(encoded.contains("schema_version = 1"))
    #expect(!encoded.contains("format ="))
    #expect(try codec.decode(encoded) == original)
    #expect(original.workflow.plan.process.steps.first?.reasoning == .some(.none))
    #expect(original.workflow.plan.process.steps.first?.decision?.optional == true)
    #expect(original.workflow.plan.output.actions.last?.optional == true)
  }
  @Test(arguments: ["none", "low", "high"])
  func taskDoesNotChooseReasoning(_ value: String) throws {
    let source = Self.source.replacingOccurrences(of: "reasoning = \"none\"", with: "reasoning = \"\(value)\"")
    #expect(try WorkflowDocumentCodec().decode(source).workflow.plan.process.steps[0].reasoning?.rawValue == value)
  }
  @Test(arguments: ["auto", "inherit", "medium", "xhigh"])
  func rejectsNativeOrImplicitLevels(_ value: String) {
    #expect(throws: (any Error).self) {
      try WorkflowDocumentCodec().decode(Self.source.replacingOccurrences(of: "reasoning = \"none\"", with: "reasoning = \"\(value)\""))
    }
  }
  @Test func rejectsMissingReasoningAndUnknownFields() {
    let invalid = [
      Self.source.replacingOccurrences(of: "reasoning = \"none\"", with: ""),
      Self.source.replacingOccurrences(of: "reasoning = \"none\"", with: "reasoning = \"none\"\nmodel_role = \"fast\""),
      Self.source + "\n[options]\nmodel = \"old\"\n",
      Self.source + "\n[metadata]\n\"text.polishing-gate\" = \"classification\"\n",
      Self.source + "\n[output.actions.config]\nmodel = \"old\"\n",
      Self.source.replacingOccurrences(of: "kind = \"llm-rewrite\"", with: "kind = \"normalize-whitespace\""),
      Self.source.replacingOccurrences(of: "decision = { optional = true }", with: "decision = { optional = true, provider = \"jev\" }"),
    ]
    for source in invalid { #expect(throws: (any Error).self) { try WorkflowDocumentCodec().decode(source) } }
  }
  @Test(arguments: ["0", "2", "3", "\"1\"", "1.0", "true"])
  func rejectsUnsupportedSchemaVersions(_ version: String) {
    let source = Self.source.replacingOccurrences(of: "schema_version = 1", with: "schema_version = \(version)")
    #expect(throws: (any Error).self) { try WorkflowDocumentCodec().decode(source) }
  }
  @Test func rejectsMissingSchemaVersionAndRetiredLayouts() {
    let invalid = [
      Self.source.replacingOccurrences(of: "schema_version = 1", with: ""),
      Self.source.replacingOccurrences(of: "schema_version = 1", with: "format = \"rill.workflow\"\nversion = 1"),
      Self.source.replacingOccurrences(of: "schema_version = 1", with: "schema_version = 1\nformat = \"rill.workflow\"\nversion = 1"),
      Self.source.replacingOccurrences(of: "schema_version = 1", with: "schema_version = 1\npipeline = []"),
    ]
    for source in invalid { #expect(throws: (any Error).self) { try WorkflowDocumentCodec().decode(source) } }
  }
  @Test func rejectsJSON() {
    #expect(throws: (any Error).self) { try WorkflowDocumentCodec().decode("{\"schemaVersion\":2,\"workflows\":[]}") }
  }
  @Test func emptyOutputIsValid() throws {
    let source = Self.source.components(separatedBy: "[[output.actions]]")[0]
    #expect(try WorkflowDocumentCodec().decode(source).workflow.plan.output.actions.isEmpty)
  }

  @Test func rejectsUnavailableCollectionEventTriggers() throws {
    let source = Self.source.replacingOccurrences(of: "kind = \"manual\"", with: "kind = \"record-collection\"")
    #expect(throws: (any Error).self) { try WorkflowDocumentCodec().decode(source) }
    var document = try WorkflowDocumentCodec().decode(Self.source)
    document.workflow.properties.automation = .init(
      rule: .init(eventKind: .recordCreated, sourceCollectionID: RecordCollection.voiceInputID), actionKind: .editRecord)
    #expect(throws: (any Error).self) { try WorkflowDocumentCodec().encode(document) }
  }

  @Test func rewriteFailurePolicyRoundTripsAndRejectsOtherTasks() throws {
    let source = Self.source.replacingOccurrences(of: "reasoning = \"none\"", with: "reasoning = \"none\"\non_failure = \"preserve-input\"")
    let codec = WorkflowDocumentCodec()
    let document = try codec.decode(source)
    #expect(document.workflow.plan.process.steps.first?.postProcessStep?.failurePolicy == .preserveInput)
    #expect(try codec.decode(codec.encode(document)) == document)
    #expect(throws: (any Error).self) { try codec.decode(source.replacingOccurrences(of: "llm-rewrite", with: "llm-answer")) }
  }

  @Test func duplicatePendingBufferOutputsAreRejected() throws {
    var document = try WorkflowDocumentCodec().decode(Self.source)
    document.workflow.plan.output.actions = (1...2).map { index in
      var action = OutputActionReference(id: RecordActionID.store)
      action.documentID = "pending-\(index)"
      action.configuration.buffer = "speech"
      return action
    }
    #expect(throws: (any Error).self) { try WorkflowDocumentCodec().encode(document) }
  }

  @Test func packagedWorkflowsUseTheSameParser() throws {
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    #expect(workflows.count == 5)
    for workflow in workflows {
      #expect(!workflow.plan.process.steps.isEmpty)
      for step in workflow.plan.process.allSteps where [.llmRewrite, .llmAnswer].contains(step.kind) {
        #expect(step.reasoning != nil)
      }
    }
  }
}
