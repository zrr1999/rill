import VoxTypeCore
import VoxTypePlatform

public struct ClipboardCopyAction: OutputAction {
    public let id = "clipboard.copy"
    private let pasteboard: PasteboardController
    private let clipboardCapture: (any ClipboardCaptureSink)?

    public init(
        pasteboard: PasteboardController,
        clipboardCapture: (any ClipboardCaptureSink)? = nil
    ) {
        self.pasteboard = pasteboard
        self.clipboardCapture = clipboardCapture
    }

    public func execute(text: String, context: ActionContext) async throws -> ActionResult {
        let captureTags: [ClipboardCaptureTag] = context.workflow.excludesOutputFromWorkflowCapture
            ? [.excludeFromWorkflowCapture]
            : []
        _ = await pasteboard.writePlainText(text, captureTags: captureTags)
        let alternatives = context.recognitionResult.candidateSets.flatMap { set in
            set.candidates.map(\.text)
        }
        await clipboardCapture?.captureWorkflowClipboardCopy(
            text: text,
            workflowID: context.workflow.id,
            workflow: context.workflow.presentation,
            context: ClipboardRouteContext(
                applicationName: context.contextSnapshot.focus.applicationName,
                bundleIdentifier: context.contextSnapshot.focus.bundleIdentifier
            ),
            alternatives: alternatives,
            captureTags: captureTags,
            replacing: context.sourceClipboardItemID
        )
        return .copiedToClipboard
    }
}

public struct InjectTextAction: OutputAction {
    public let id = "inject.text"
    private let engine: TextInjectionEngine

    public init(engine: TextInjectionEngine) {
        self.engine = engine
    }

    public func execute(text: String, context: ActionContext) async throws -> ActionResult {
        try await engine.inject(text)
        return .injected
    }
}

public struct PushToStackAction: OutputAction {
    public let id = "stack.push"
    private let stack: any DeliveryStackSink

    public init(stack: any DeliveryStackSink) {
        self.stack = stack
    }

    public func execute(text: String, context: ActionContext) async throws -> ActionResult {
        let alternatives = context.recognitionResult.candidateSets.flatMap { set in
            set.candidates.map(\.text)
        }
        let item = DeliveryItem(
            workflowID: context.workflow.id,
            workflow: context.workflow.presentation,
            text: text,
            alternatives: alternatives,
            sourceApplicationName: context.contextSnapshot.focus.applicationName,
            sourceBundleIdentifier: context.contextSnapshot.focus.bundleIdentifier,
            captureTags: context.workflow.excludesOutputFromWorkflowCapture
                ? [.excludeFromWorkflowCapture]
                : []
        )
        if let sourceClipboardItemID = context.sourceClipboardItemID {
            await stack.replace(item, replacing: sourceClipboardItemID)
        } else {
            await stack.push(item)
        }
        return .pushedToStack
    }
}
