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
        guard let version = shape.table?["schema_version"]?.integer else {
            throw WorkflowDocumentError("schema_version", "An integer schema version is required.")
        }
        let document: WorkflowDocument
        switch version {
        case 1:
            try shape.validateDocument(legacy: true)
            let legacy = try decoder.decode(WorkflowTOMLDocument.self, from: source)
            document = try WorkflowDocument(workflow: legacy.workflow(), isEnabled: legacy.enabled)
        case 2:
            try shape.validateDocument()
            document = try decoder.decode(DocumentV2.self, from: source).document()
        default:
            throw WorkflowDocumentError(
                "schema_version",
                "Unsupported workflow version \(version). This file has not been changed.")
        }
        try validate(document)
        return document
    }

    public func encode(_ document: WorkflowDocument, validating: Bool = true) throws -> String {
        if validating { try validate(document) }
        let encoder = TOMLEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encodeToString(DocumentV2(document))
    }

    public func validate(_ document: WorkflowDocument) throws {
        try XDGWorkflowFileStore.validate(document.workflow)
        let workflow = document.workflow
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

private struct DocumentV2: Codable {
    var schema_version = 2
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
    var options: [String: String]?
    var metadata: [String: String]?

    init(_ document: WorkflowDocument) {
        let workflow = document.workflow
        id = workflow.id
        name = workflow.name
        description = workflow.documentDescription
        enabled = document.isEnabled
        trigger = DocumentTrigger(
            kind: workflow.trigger.tomlValue,
            gesture: workflow.metadata[WorkflowMetadataKey.triggerGesture])
        input = DocumentInput(kind: workflow.inputKind)
        ui = WorkflowTOMLUI(config: workflow.ui)
        setup = WorkflowTOMLSetup(phase: workflow.plan.setup, metadata: workflow.metadata)
        process = workflow.plan.process.steps.map(DocumentStep.init)
        output = DocumentOutput(workflow.plan.output)
        let descriptive = workflow.metadata.filter {
            $0.key.hasPrefix("user.") || $0.key == "workflow.origin"
        }
        metadata = descriptive.isEmpty ? nil : descriptive
        var remaining = workflow.metadata.filter { descriptive[$0.key] == nil }
        remaining.removeValue(forKey: WorkflowMetadataKey.triggerGesture)
        for key in [
            WorkflowMetadataKey.livePreviewEnabled, WorkflowMetadataKey.livePreviewPlacement,
            WorkflowMetadataKey.streamingProfile,
        ] where setup?.speech != nil {
            remaining.removeValue(forKey: key)
        }
        options = remaining.isEmpty ? nil : remaining
    }

    func document() throws -> WorkflowDocument {
        guard let binding = TriggerBinding(tomlValue: trigger.kind) else {
            throw WorkflowDocumentError("trigger.kind", "Unknown trigger kind.")
        }
        var runtimeMetadata = options ?? [:]
        for (key, value) in metadata ?? [:] {
            guard key.hasPrefix("user.") || key == "workflow.origin" else {
                throw WorkflowDocumentError(
                    "metadata.\(key)",
                    "Descriptive metadata keys must start with user.; runtime options belong in options."
                )
            }
            runtimeMetadata[key] = value
        }
        if let gesture = trigger.gesture {
            runtimeMetadata[WorkflowMetadataKey.triggerGesture] = gesture
        }
        try setup?.speech?.applyMetadata(to: &runtimeMetadata)
        var workflow = try WorkflowDefinition(
            id: id, name: name, trigger: binding,
            plan: WorkflowPlan(
                setup: setup?.phase() ?? WorkflowSetupPhase(),
                process: WorkflowProcessPhase(
                    steps: (process ?? []).map { try $0.step(workflowID: id) }),
                output: output.phase()
            ),
            ui: ui?.config ?? WorkflowUIConfig(symbolName: "sparkles", accentColorName: "blue"),
            metadata: runtimeMetadata
        )
        workflow.documentDescription = description
        workflow.declaredInputKind = input.kind
        return WorkflowDocument(workflow: workflow, isEnabled: enabled ?? false)
    }
}

private struct DocumentTrigger: Codable {
    var kind: String
    var gesture: String?
}
private struct DocumentInput: Codable { var kind: WorkflowInputKind }

private struct DocumentStep: Codable {
    var id: String
    var kind: String
    var description: String?
    var prompt: String?
    var record_duration: Bool?
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
            recordDuration: record_duration
        )
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
    var actions: [DocumentAction]

    init(_ output: WorkflowOutputPhase) {
        strategy = output.deliveryPolicy.strategy.tomlValue
        actions = output.actions.enumerated().map { DocumentAction($0.element, index: $0.offset) }
    }

    func phase() throws -> WorkflowOutputPhase {
        guard let strategy = DeliveryStrategy(tomlValue: strategy ?? "immediate") else {
            throw WorkflowDocumentError("output.strategy", "Unknown delivery strategy.")
        }
        return try WorkflowOutputPhase(
            actions: actions.map { try $0.action() }, deliveryPolicy: .init(strategy: strategy))
    }
}

private struct DocumentAction: Codable {
    var id: String
    var kind: String
    var description: String?
    var config: [String: String]?
    var condition: DocumentCondition?

    init(_ action: OutputActionReference, index: Int) {
        id = action.documentID ?? "output-\(index + 1)"
        kind = action.id
        description = action.nodeDescription
        config = action.configuration.isEmpty ? nil : action.configuration
        condition = action.condition.map(DocumentCondition.init)
    }

    func action() throws -> OutputActionReference {
        var action = OutputActionReference(id: kind, configuration: config ?? [:])
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
    case scalar
    var table: [String: DocumentShape]? {
        if case .tableValue(let value) = self { value } else { nil }
    }
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
            self = (try? value.decode(Int.self)).map(Self.number) ?? .scalar
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

    func validateDocument(legacy: Bool = false) throws {
        try check(
            legacy
                ? [
                    "schema_version", "id", "name", "enabled", "trigger", "ui", "setup", "process",
                    "output", "metadata",
                ]
                : [
                    "schema_version", "id", "name", "description", "enabled", "trigger", "input",
                    "ui", "setup", "process", "output", "options", "metadata",
                ], path: "")
        if !legacy { try table?["trigger"]?.check(["kind", "gesture"], path: "trigger") }
        try table?["input"]?.check(["kind"], path: "input")
        try table?["ui"]?.check(["symbol", "accent"], path: "ui")
        let setup = table?["setup"]
        try setup?.check(["speech", "vocabulary", "wake_word"], path: "setup")
        try setup?.table?["speech"]?.check(
            [
                "selection", "recognizer", "language", "local_model", "provider_model",
                "live_preview", "live_preview_placement", "streaming_profile",
            ], path: "setup.speech")
        try setup?.table?["wake_word"]?.check(["phrases"], path: "setup.wake_word")
        if case .array(let bindings) = setup?.table?["vocabulary"] {
            for binding in bindings {
                try binding.check(["id", "collection", "uses", "when"], path: "setup.vocabulary")
                try binding.table?["when"]?.check(
                    ["app_bundle_id", "clipboard_group", "locale"], path: "setup.vocabulary.when")
            }
        }
        try table?["process"]?.validateSteps(path: "process", legacy: legacy)
        try table?["output"]?.check(["strategy", "actions"], path: "output")
        if case .array(let actions) = table?["output"]?.table?["actions"] {
            for (index, action) in actions.enumerated() {
                let path = "output.actions[\(index)]"
                try action.check(
                    legacy
                        ? ["id", "config"] : ["id", "kind", "description", "config", "condition"],
                    path: path)
                try action.table?["condition"]?.validateCondition(path: "\(path).condition")
            }
        }
    }

    func validateSteps(path: String, legacy: Bool = false) throws {
        guard case .array(let steps) = self else { return }
        for (index, step) in steps.enumerated() {
            let path = "\(path)[\(index)]"
            try step.check(
                legacy
                    ? ["id", "kind", "prompt", "uncertainty"]
                    : [
                        "id", "kind", "description", "prompt", "uncertainty", "condition", "then",
                        "else", "record_duration",
                    ], path: path)
            try step.table?["uncertainty"]?.check(
                ["mode", "confidence_threshold", "timeout_seconds"], path: "\(path).uncertainty")
            try step.table?["condition"]?.validateCondition(path: "\(path).condition")
            for branch in ["then", "else"] {
                try step.table?[branch]?.validateSteps(path: "\(path).\(branch)")
            }
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
