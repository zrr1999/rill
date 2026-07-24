import RillCore

public enum WorkflowExecutionSurface: Sendable, Equatable {
    case interactiveCapture
    case clipboardItemReplay
    case clipboardGroupEvent
}

public enum WorkflowExecutionSurfaceDecision: Sendable, Equatable {
    case supported
    case wrongSurface
    case invalidConfiguration
}

public enum WorkflowExecutionPolicyIssue: String, Codable, Sendable, Equatable {
    case legacyClipboardAutomationUnsupported
    case invalidEventType
    case plannedCapabilityUnavailable
}

public enum WorkflowExecutionPolicy {
    private static let legacyClipboardEventTypes: Set<String> = [
        "groupItemCreated",
        "groupItemEdited",
        "groupItemRemoved",
    ]
    private static let supportedInteractiveEventTypes: Set<String> = [
        TriggerBinding.hotkey.rawValue,
        TriggerBinding.manual.rawValue,
        TriggerBinding.menuBar.rawValue,
        TriggerBinding.wakeWord.rawValue,
    ]

    public static func issue(
        for workflow: WorkflowDefinition
    ) -> WorkflowExecutionPolicyIssue? {
        guard workflow.availability == .active else {
            return .plannedCapabilityUnavailable
        }
        switch decision(for: workflow, on: .interactiveCapture) {
        case .supported:
            return nil
        case .wrongSurface:
            return .legacyClipboardAutomationUnsupported
        case .invalidConfiguration:
            return .invalidEventType
        }
    }

    public static func supports(_ workflow: WorkflowDefinition) -> Bool {
        issue(for: workflow) == nil
    }

    public static func decision(
        for workflow: WorkflowDefinition,
        on surface: WorkflowExecutionSurface
    ) -> WorkflowExecutionSurfaceDecision {
        guard workflow.availability == .active else { return .invalidConfiguration }
        guard let eventType = workflow.metadata[WorkflowMetadataKey.legacyEventType] else {
            return surface == .clipboardGroupEvent ? .wrongSurface : .supported
        }

        if legacyClipboardEventTypes.contains(eventType) {
            guard surface == .clipboardGroupEvent else { return .wrongSurface }
            do {
                guard try workflow.parseClipboardGroupAutomationConfiguration() != nil else {
                    return .invalidConfiguration
                }
                return .supported
            } catch {
                return .invalidConfiguration
            }
        }

        guard supportedInteractiveEventTypes.contains(eventType) else {
            return .invalidConfiguration
        }
        return surface == .clipboardGroupEvent ? .wrongSurface : .supported
    }
}
