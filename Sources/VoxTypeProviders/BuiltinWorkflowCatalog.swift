import Foundation
import VoxTypeCore

private func staticUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid UUID string: \(string)")
    }
    return uuid
}

public struct BuiltinWorkflowCatalog: WorkflowCatalog {
    public init() {}

    public func manifest() -> WorkflowManifest {
        WorkflowManifest(
            schemaVersion: 1,
            workflows: [
                WorkflowDefinition(
                    id: Self.directDemoWorkflowID,
                    name: "Capture Selection",
                    titleKey: .directDemoClipboard,
                    pipeline: PipelineDeclaration(
                        recognizerID: "context.selection",
                        postProcessSteps: [PostProcessStep(kind: .normalizeWhitespace)],
                        outputActions: [OutputActionReference(id: "stack.push")],
                        uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                        deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
                    ),
                    ui: WorkflowUIConfig(symbolName: "doc.on.doc", accentColorName: "blue"),
                    metadata: [
                        "catalog": "builtin.demo",
                        "capture.source": "selection-or-clipboard",
                    ]
                ),
                WorkflowDefinition(
                    id: Self.rewriteDemoWorkflowID,
                    name: "Polish Draft",
                    titleKey: .rewriteDemoStack,
                    pipeline: PipelineDeclaration(
                        recognizerID: "whisperkit.local",
                        postProcessSteps: [
                            PostProcessStep(kind: .normalizeWhitespace),
                            PostProcessStep(kind: .llmRewrite, prompt: "Rewrite for a polished final message"),
                        ],
                        outputActions: [OutputActionReference(id: "stack.push")],
                        uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                        deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
                    ),
                    ui: WorkflowUIConfig(symbolName: "wand.and.rays", accentColorName: "purple"),
                    metadata: [
                        "catalog": "builtin.demo",
                        "preview.mode": "progressive",
                    ]
                ),
                WorkflowDefinition(
                    id: Self.pushToTalkDemoWorkflowID,
                    name: "Fn Dictation",
                    titleKey: .pushToTalkCapture,
                    trigger: .hotkey,
                    pipeline: PipelineDeclaration(
                        recognizerID: "whisperkit.local",
                        outputActions: [OutputActionReference(id: "stack.push")],
                        uncertaintyPolicy: UncertaintyPolicy(mode: .off, confidenceThreshold: 0.0, timeoutSeconds: 0),
                        deliveryPolicy: DeliveryPolicy(strategy: .stackFirst)
                    ),
                    ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red"),
                    metadata: [
                        "catalog": "builtin.demo",
                        "trigger.gesture": "fn",
                        "delivery.mode": "streaming-intent",
                    ]
                ),
            ],
            metadata: [
                "source": "builtin.demo",
                "format": "static",
            ]
        )
    }
}

private extension BuiltinWorkflowCatalog {
    static let ambiguousDemoWorkflowID = staticUUID("B6E19A88-F9FB-4AB3-8444-CDBF7E215A88")
    static let directDemoWorkflowID = staticUUID("B7E19A88-F9FB-4AB3-8444-CDBF7E215A88")
    static let rewriteDemoWorkflowID = staticUUID("B8E19A88-F9FB-4AB3-8444-CDBF7E215A88")
    static let pushToTalkDemoWorkflowID = staticUUID("B9E19A88-F9FB-4AB3-8444-CDBF7E215A88")
    static let whisperKitWorkflowID = staticUUID("BAE19A88-F9FB-4AB3-8444-CDBF7E215A88")
    static let deepgramWorkflowID = staticUUID("BBE19A88-F9FB-4AB3-8444-CDBF7E215A88")
}
