import CryptoKit
import Foundation
import RillCore
import TOML

public struct WorkflowDocumentCodec: Sendable {
  public init() {}

  public func decode(_ source: String) throws -> WorkflowDocument {
    let decoder = TOMLDecoder()
    decoder.limits.maxInputSize = XDGWorkflowFileStore.maximumFileSize
    decoder.limits.maxDepth = 64
    decoder.limits.maxArrayLength = 1_024
    decoder.limits.maxTableKeys = 1_024
    let shape = try decoder.decode(DocumentShape.self, from: source)
    guard shape.table?["schema_version"]?.integer == WorkflowDocument.schemaVersion else {
      throw WorkflowDocumentError("schema_version", "Unsupported workflow format. Use schema_version = 1; this file has not been changed.")
    }
    try shape.validateDocument()
    let document = try decoder.decode(WorkflowFileDocument.self, from: source).document()
    try validate(document)
    return document
  }

  public func encode(_ document: WorkflowDocument, validating: Bool = true) throws -> String {
    if validating { try validate(document) }
    let encoder = TOMLEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encodeToString(WorkflowFileDocument(document))
  }

  public func validate(_ document: WorkflowDocument) throws {
    try XDGWorkflowFileStore.validate(document.workflow)
    let workflow = document.workflow
    guard workflow.properties.automation == nil else { throw WorkflowDocumentError("trigger", "Record collection event automation is unavailable.") }
    guard (workflow.inputKind == .audio) == (workflow.plan.setup.speechRoute != nil) else {
      throw WorkflowDocumentError(
        "input.kind",
        "Audio input requires a speech route; text and record input must omit it.")
    }
    guard workflow.plan.process.allSteps.count <= 256 else {
      throw WorkflowDocumentError("process", "A workflow can contain at most 256 steps.")
    }
    var keys = Set<String>()
    for step in workflow.plan.process.allSteps {
      try insertKey(step.documentID ?? step.id.uuidString, into: &keys)
    }
    for (index, action) in workflow.plan.output.actions.enumerated() {
      _ = try DocumentAction(action, index: index).action()
      try insertKey(action.documentID ?? "output-\(index + 1)", into: &keys)
    }
  }

  private func insertKey(_ key: String, into keys: inout Set<String>) throws {
    guard !key.isEmpty, key.utf8.count <= 128,
      key.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 95
      })
    else {
      throw WorkflowDocumentError(
        "id", "Step IDs must contain 1–128 ASCII letters, digits, underscores, or hyphens.")
    }
    guard keys.insert(key).inserted else {
      throw WorkflowDocumentError("id", "Duplicate step ID: \(key)")
    }
  }
}

private struct WorkflowFileDocument: Codable {
  var schema_version = WorkflowDocument.schemaVersion
  var id: UUID
  var name: String
  var description: String?
  var enabled: Bool?
  var trigger: DocumentTrigger
  var input: DocumentInput
  var ui: WorkflowTOMLUI?
  var setup: WorkflowTOMLSetup?
  var process: [DocumentStep]?
  var output: DocumentOutput

  init(_ document: WorkflowDocument) {
    let workflow = document.workflow
    id = workflow.id
    name = workflow.name
    description = workflow.documentDescription
    enabled = document.isEnabled
    trigger = DocumentTrigger(
      kind: workflow.trigger.tomlValue,
      gesture: workflow.properties.gesture, exclusive_group: workflow.exclusiveGroupIdentifier)
    input = DocumentInput(kind: workflow.inputKind)
    ui = WorkflowTOMLUI(config: workflow.ui)
    setup = WorkflowTOMLSetup(phase: workflow.plan.setup)
    process = workflow.plan.process.steps.map(DocumentStep.init)
    output = DocumentOutput(workflow.plan.output)
  }

  func document() throws -> WorkflowDocument {
    guard let binding = TriggerBinding(tomlValue: trigger.kind) else {
      throw WorkflowDocumentError("trigger.kind", "Unknown trigger kind.")
    }
    let properties = WorkflowProperties(gesture: trigger.gesture, exclusiveGroup: trigger.exclusive_group)
    var workflow = try WorkflowDefinition(
      id: id, name: name, trigger: binding,
      plan: WorkflowPlan(
        setup: setup?.phase() ?? WorkflowSetupPhase(),
        process: WorkflowProcessPhase(
          steps: (process ?? []).map { try $0.step(workflowID: id) }),
        output: output.phase()
      ),
      ui: ui?.config ?? WorkflowUIConfig(symbolName: "sparkles", accentColorName: "blue"),
      properties: properties
    )
    workflow.documentDescription = description
    workflow.declaredInputKind = input.kind
    return WorkflowDocument(workflow: workflow, isEnabled: enabled ?? false)
  }
}

private struct DocumentTrigger: Codable {
  var kind: String
  var gesture: String?
  var exclusive_group: String? = nil
}
private struct DocumentInput: Codable { var kind: WorkflowInputKind }

private struct DocumentStep: Codable {
  var id: String
  var kind: String
  var description: String?
  var prompt: String?
  var record_duration: Bool?
  var reasoning: ReasoningLevel?
  var optional: Bool?
  var on_failure: WorkflowTaskFailurePolicy?
  var decision: WorkflowServiceRequirement?
  var preserve_content: Bool?
  var uncertainty: WorkflowTOMLUncertainty?
  var condition: DocumentCondition?
  var then: [DocumentStep]?
  var `else`: [DocumentStep]?

  init(_ step: WorkflowProcessStep) {
    id = step.documentID ?? step.id.uuidString
    kind = step.kind.tomlValue
    description = step.nodeDescription
    prompt = step.prompt
    record_duration = step.recordDuration
    reasoning = step.reasoning
    optional = step.optional ? true : nil
    on_failure = step.failurePolicy == .fail ? nil : step.failurePolicy
    decision = step.decision
    preserve_content = step.preservesContent ? true : nil
    uncertainty = step.uncertaintyPolicy.map(WorkflowTOMLUncertainty.init)
    condition = step.condition.map(DocumentCondition.init)
    then = step.thenSteps.map { $0.map(DocumentStep.init) }
    `else` = step.elseSteps.map { $0.map(DocumentStep.init) }
  }

  func step(workflowID: UUID) throws -> WorkflowProcessStep {
    guard let stepKind = WorkflowProcessStepKind(tomlValue: kind) else {
      throw WorkflowDocumentError("process.\(id).kind", "Unknown step kind: \(kind)")
    }
    var step = try WorkflowProcessStep(
      id: Self.runtimeID(id, workflowID: workflowID), kind: stepKind,
      prompt: prompt, uncertaintyPolicy: uncertainty?.policy(),
      recordDuration: record_duration,
      reasoning: reasoning
    )
    step.failurePolicy = on_failure ?? .fail
    step.optional = optional ?? false
    step.decision = decision
    step.preservesContent = preserve_content ?? false
    step.documentID = id
    step.nodeDescription = description
    step.condition = try condition?.resolve()
    step.thenSteps = try then?.map { try $0.step(workflowID: workflowID) }
    step.elseSteps = try `else`?.map { try $0.step(workflowID: workflowID) }
    return step
  }

  private static func runtimeID(_ key: String, workflowID: UUID) -> UUID {
    if let uuid = UUID(uuidString: key) { return uuid }
    var bytes = Array(
      SHA256.hash(data: Data("\(workflowID.uuidString)/\(key)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

private struct DocumentOutput: Codable {
  var strategy: String?
  var actions: [DocumentAction]?

  init(_ output: WorkflowOutputPhase) {
    strategy = output.deliveryPolicy.strategy.tomlValue
    actions = output.actions.enumerated().map { DocumentAction($0.element, index: $0.offset) }
  }

  func phase() throws -> WorkflowOutputPhase {
    guard let strategy = DeliveryStrategy(tomlValue: strategy ?? "immediate") else {
      throw WorkflowDocumentError("output.strategy", "Unknown delivery strategy.")
    }
    return try WorkflowOutputPhase(
      actions: (actions ?? []).map { try $0.action() }, deliveryPolicy: .init(strategy: strategy))
  }
}

private struct DocumentAction: Codable {
  var id: String
  var kind: String
  var description: String?
  var optional: Bool?
  var collections: [UUID]?
  var buffer: String?
  var exclude_from_capture: Bool?
  var voice: String?
  var language: String?
  var shortcut: String?
  var path: String?
  var webhook_reference: String?
  var condition: DocumentCondition?

  init(_ action: OutputActionReference, index: Int) {
    id = action.documentID ?? "output-\(index + 1)"
    kind = action.id
    description = action.nodeDescription
    optional = action.optional ? true : nil
    let values = action.configuration
    collections = values.collections.isEmpty ? nil : values.collections
    buffer = values.buffer
    exclude_from_capture = values.excludeFromCapture ? nil : false
    voice = values.voice
    language = values.language
    shortcut = values.shortcutName
    path = values.markdownPath
    webhook_reference = values.webhookReference
    condition = action.condition.map(DocumentCondition.init)
  }
  func action() throws -> OutputActionReference {
    guard
      [
        RecordActionID.store, RecordActionID.systemClipboardCopy, RecordActionID.focusedApplicationInsert,
        SpeechOutputActionID.speak, ExternalOutputActionID.webhookPost, ExternalOutputActionID.shortcutsRun,
        ExternalOutputActionID.markdownAppend,
      ].contains(kind)
    else {
      throw WorkflowDocumentError("output.\(id).kind", "Unknown output kind.")
    }
    var values = WorkflowOutputParameters()
    if let collections {
      guard kind == RecordActionID.store, Set(collections).count == collections.count else {
        throw WorkflowDocumentError("output.\(id).collections", "Collections require a record.store action and unique IDs.")
      }
      values.collections = collections
    }
    if let buffer {
      guard kind == RecordActionID.store, buffer == "speech" else {
        throw WorkflowDocumentError("output.\(id).buffer", "Use the speech buffer on record.store.")
      }
      values.buffer = buffer
    }
    if let exclude_from_capture { values.excludeFromCapture = exclude_from_capture }
    if voice != nil || language != nil {
      guard kind == SpeechOutputActionID.speak else { throw WorkflowDocumentError("output.\(id)", "Voice and language belong to speech.speak.") }
    }
    if shortcut != nil && kind != ExternalOutputActionID.shortcutsRun { throw WorkflowDocumentError("output.\(id).shortcut", "Unexpected field.") }
    if path != nil && kind != ExternalOutputActionID.markdownAppend { throw WorkflowDocumentError("output.\(id).path", "Unexpected field.") }
    if webhook_reference != nil && kind != ExternalOutputActionID.webhookPost {
      throw WorkflowDocumentError("output.\(id).webhook_reference", "Unexpected field.")
    }
    values.voice = voice
    values.language = language
    values.shortcutName = shortcut
    values.markdownPath = path
    values.webhookReference = webhook_reference
    var action = OutputActionReference(id: kind, configuration: values)
    action.optional = optional ?? false
    action.documentID = id
    action.nodeDescription = description
    action.condition = try condition?.resolve()
    return action
  }
}

private struct DocumentCondition: Codable {
  var field: WorkflowCondition.Field?
  var op: WorkflowCondition.Operation?
  var value: String?
  var all: [DocumentCondition]?
  var any: [DocumentCondition]?
  // An array breaks recursive value storage; exactly one child is required.
  var not: [DocumentCondition]?

  init(_ condition: WorkflowCondition) {
    switch condition {
    case .comparison(let field, let operation, let value):
      self.field = field
      op = operation
      self.value = value
    case .all(let children): all = children.map(Self.init)
    case .any(let children): any = children.map(Self.init)
    case .not(let child): not = [Self(child)]
    }
  }

  func resolve() throws -> WorkflowCondition {
    let modes = [field != nil || op != nil || value != nil, all != nil, any != nil, not != nil]
      .filter { $0 }.count
    guard modes == 1 else {
      throw WorkflowDocumentError(
        "condition", "Choose exactly one comparison, all, any, or not.")
    }
    if let all { return try .all(all.map { try $0.resolve() }) }
    if let any { return try .any(any.map { try $0.resolve() }) }
    if let not {
      guard not.count == 1, let child = not.first else {
        throw WorkflowDocumentError("condition.not", "not requires exactly one condition.")
      }
      return try .not(child.resolve())
    }
    guard let field, let op else {
      throw WorkflowDocumentError("condition", "field and op are required.")
    }
    return .comparison(field: field, operation: op, value: value)
  }
}

/// Checks unknown keys before Codable can discard them. Values are never interpreted as code.
private indirect enum DocumentShape: Decodable {
  case tableValue([String: DocumentShape])
  case array([DocumentShape])
  case number(Int)
  case text(String)
  case scalar
  var table: [String: DocumentShape]? {
    if case .tableValue(let value) = self { value } else { nil }
  }
  var string: String? { if case .text(let value) = self { value } else { nil } }
  var integer: Int? { if case .number(let value) = self { value } else { nil } }

  init(from decoder: any Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: Key.self) {
      self = .tableValue(
        try Dictionary(
          uniqueKeysWithValues: keyed.allKeys.map {
            ($0.stringValue, try keyed.decode(Self.self, forKey: $0))
          }))
    } else if var array = try? decoder.unkeyedContainer() {
      var values: [Self] = []
      while !array.isAtEnd { values.append(try array.decode(Self.self)) }
      self = .array(values)
    } else {
      let value = try decoder.singleValueContainer()
      self = (try? value.decode(Int.self)).map(Self.number) ?? (try? value.decode(String.self)).map(Self.text) ?? .scalar
    }
  }

  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  func check(_ allowed: Set<String>, path: String) throws {
    guard let table else { return }
    if let unknown = table.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw WorkflowDocumentError(
        path.isEmpty ? unknown : "\(path).\(unknown)", "Unknown field.")
    }
  }

  func validateDocument() throws {
    try check(["schema_version", "id", "name", "description", "enabled", "trigger", "input", "ui", "setup", "process", "output"], path: "")
    try table?["trigger"]?.check(["kind", "gesture", "exclusive_group"], path: "trigger")
    try table?["input"]?.check(["kind"], path: "input")
    try table?["ui"]?.check(["symbol", "accent"], path: "ui")
    let setup = table?["setup"]
    try setup?.check(["speech", "vocabulary", "wake_word"], path: "setup")
    try setup?.table?["speech"]?.check(["language", "live_preview", "live_preview_placement", "streaming_profile"], path: "setup.speech")
    try setup?.table?["wake_word"]?.check(["phrases"], path: "setup.wake_word")
    if case .array(let bindings) = setup?.table?["vocabulary"] {
      for binding in bindings {
        try binding.check(["id", "collection", "uses", "when", "optional"], path: "setup.vocabulary")
        try binding.table?["when"]?.check(["app_bundle_id", "record_collection", "locale"], path: "setup.vocabulary.when")
      }
    }
    try table?["process"]?.validateSteps(path: "process")
    try table?["output"]?.check(["strategy", "actions"], path: "output")
    if case .array(let actions) = table?["output"]?.table?["actions"] {
      for (index, action) in actions.enumerated() {
        let path = "output.actions[\(index)]"
        try action.check(
          [
            "id", "kind", "description", "optional", "collections", "buffer", "exclude_from_capture", "voice", "language", "shortcut", "path",
            "webhook_reference", "condition",
          ], path: path)
        try action.table?["condition"]?.validateCondition(path: "\(path).condition")
      }
    }
  }
  func validateSteps(path: String) throws {
    guard case .array(let steps) = self else { return }
    for (index, step) in steps.enumerated() {
      let path = "\(path)[\(index)]"
      try step.check(
        [
          "id", "kind", "description", "prompt", "record_duration", "reasoning", "optional", "on_failure", "decision", "preserve_content", "uncertainty",
          "condition", "then",
          "else",
        ], path: path)
      let llm = ["llm-rewrite", "llm-answer"].contains(step.table?["kind"]?.string ?? "")
      if !llm && step.table?["optional"] != nil { throw WorkflowDocumentError("\(path).optional", "Only service-dependent LLM tasks accept optional.") }
      if llm != (step.table?["reasoning"] != nil) {
        throw WorkflowDocumentError("\(path).reasoning", llm ? "An explicit reasoning level is required." : "Only LLM tasks accept reasoning.")
      }
      if step.table?["decision"] != nil || step.table?["preserve_content"] != nil {
        guard step.table?["kind"]?.string == "llm-rewrite" else {
          throw WorkflowDocumentError(path, "Decision input and content preservation belong to llm-rewrite.")
        }
      }
      if step.table?["on_failure"] != nil && step.table?["kind"]?.string != "llm-rewrite" {
        throw WorkflowDocumentError("\(path).on_failure", "Failure policy belongs to rewrite tasks.")
      }
      try step.table?["decision"]?.check(["optional"], path: "\(path).decision")
      try step.table?["uncertainty"]?.check(["mode", "confidence_threshold", "timeout_seconds"], path: "\(path).uncertainty")
      try step.table?["condition"]?.validateCondition(path: "\(path).condition")
      try step.table?["then"]?.validateSteps(path: "\(path).then")
      try step.table?["else"]?.validateSteps(path: "\(path).else")
    }
  }

  func validateCondition(path: String) throws {
    try check(["field", "op", "value", "all", "any", "not"], path: path)
    for group in ["all", "any", "not"] {
      if case .array(let children) = table?[group] {
        for child in children { try child.validateCondition(path: "\(path).\(group)") }
      }
    }
  }
}
