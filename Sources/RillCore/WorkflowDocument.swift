import Foundation

/// The complete editable configuration. File and visual editors share this value.
public struct WorkflowDocument: Sendable, Equatable {
    public static let schemaVersion = 2
    public var workflow: WorkflowDefinition
    public var isEnabled: Bool

    public init(workflow: WorkflowDefinition, isEnabled: Bool = false) {
        self.workflow = workflow
        self.isEnabled = isEnabled
    }
}

public enum WorkflowInputKind: String, Codable, Sendable, CaseIterable {
    case audio, text, record
}

public struct WorkflowDocumentError: Error, LocalizedError, Sendable, Equatable {
    public var path: String
    public var message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var errorDescription: String? { path.isEmpty ? message : "\(path): \(message)" }
}

/// Conditions only inspect the context already authorized for this run.
public indirect enum WorkflowCondition: Codable, Sendable, Equatable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case text
        case appBundleID = "context.app_bundle_id"
        case selectedText = "context.selected_text"
        case clipboardText = "context.clipboard_text"
    }

    public enum Operation: String, Codable, Sendable, CaseIterable {
        case equals, contains, exists
    }

    case comparison(field: Field, operation: Operation, value: String?)
    case all([WorkflowCondition])
    case any([WorkflowCondition])
    case not(WorkflowCondition)

    public func evaluate(text: String, context: ContextSnapshot) throws -> Bool {
        switch self {
        case .all(let conditions):
            for condition in conditions where try !condition.evaluate(text: text, context: context)
            { return false }
            return true
        case .any(let conditions):
            for condition in conditions where try condition.evaluate(text: text, context: context) {
                return true
            }
            return false
        case .not(let condition):
            return try !condition.evaluate(text: text, context: context)
        case .comparison(let field, let operation, let expected):
            let actual: String?
            switch field {
            case .text: actual = text
            case .appBundleID: actual = context.focus.bundleIdentifier
            case .selectedText:
                actual = context.focus.selectedText.isEmpty ? nil : context.focus.selectedText
            case .clipboardText:
                actual = context.clipboard.plainText.isEmpty ? nil : context.clipboard.plainText
            }
            if operation == .exists { return actual != nil }
            guard let actual else {
                throw WorkflowDocumentError(
                    "condition",
                    "The required context is unavailable. Use exists to check it first.")
            }
            guard let expected else {
                throw WorkflowDocumentError("condition.value", "A comparison value is required.")
            }
            switch operation {
            case .equals: return actual == expected
            case .contains: return actual.contains(expected)
            case .exists: return true
            }
        }
    }

    public func validate(depth: Int = 0) throws {
        guard depth < 16 else {
            throw WorkflowDocumentError("condition", "Conditions exceed the nesting limit of 16.")
        }
        switch self {
        case .all(let children), .any(let children):
            guard !children.isEmpty, children.count <= 64 else {
                throw WorkflowDocumentError(
                    "condition", "A condition group requires between 1 and 64 conditions.")
            }
            for child in children { try child.validate(depth: depth + 1) }
        case .not(let child): try child.validate(depth: depth + 1)
        case .comparison(_, let operation, let value):
            guard (operation == .exists) == (value == nil) else {
                throw WorkflowDocumentError(
                    "condition.value",
                    "exists takes no value; equals and contains require a string.")
            }
        }
    }
}

extension WorkflowProcessPhase {
    public var allSteps: [WorkflowProcessStep] {
        func collect(_ steps: [WorkflowProcessStep]) -> [WorkflowProcessStep] {
            steps.flatMap { [$0] + collect($0.thenSteps ?? []) + collect($0.elseSteps ?? []) }
        }
        return collect(steps)
    }
}

extension WorkflowDefinition {
    public var inputKind: WorkflowInputKind {
        declaredInputKind ?? (plan.setup.speechRoute == nil ? .text : .audio)
    }
}
