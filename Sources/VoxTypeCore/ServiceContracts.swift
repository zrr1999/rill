import Foundation

public struct RecognitionRequest: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var contextSnapshot: ContextSnapshot
    public var triggerEvent: WorkflowTriggerEvent?
    public var capturedAudio: CapturedAudio?

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        triggerEvent: WorkflowTriggerEvent? = nil,
        capturedAudio: CapturedAudio? = nil
    ) {
        self.runID = runID
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.triggerEvent = triggerEvent
        self.capturedAudio = capturedAudio
    }
}

public struct TransformContext: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var contextSnapshot: ContextSnapshot
    public var recognitionResult: RecognitionResult

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionResult: RecognitionResult
    ) {
        self.runID = runID
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.recognitionResult = recognitionResult
    }
}

public protocol SpeechRecognizer: Sendable {
    var id: String { get }
    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult
}

public protocol AudioCaptureService: Sendable {
    func startCapture(_ request: AudioCaptureRequest) async throws
    func finishCapture() async throws -> CapturedAudio
    func cancelCapture() async
}

public protocol ContextProvider: Sendable {
    func captureContext() async -> ContextSnapshot
}

public protocol TriggerSource: Sendable {
    var id: String { get }
    var binding: TriggerBinding { get }
    func stream() -> AsyncStream<WorkflowTriggerEvent>
}

public protocol TextTransformer: Sendable {
    var id: String { get }
    var supportedKinds: [PostProcessStepKind] { get }
    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String
}

public protocol OutputAction: Sendable {
    var id: String { get }
    func execute(text: String, context: ActionContext) async throws -> ActionResult
}

public protocol DeliveryStackSink: Sendable {
    func push(_ item: DeliveryItem) async
    func replace(_ item: DeliveryItem, replacing itemID: UUID) async
    func popNext() async -> DeliveryItem?
    func snapshot() async -> DeliveryStackSnapshot
}

public protocol ClipboardCaptureSink: Sendable {
    func captureWorkflowClipboardCopy(
        text: String,
        workflowID: UUID,
        workflow: WorkflowPresentation,
        context: ClipboardRouteContext,
        alternatives: [String],
        captureTags: [ClipboardCaptureTag],
        replacing sourceItemID: UUID?
    ) async
}

public protocol WorkflowCatalog: Sendable {
    func manifest() -> WorkflowManifest
}

public protocol WorkflowManifestLoader: Sendable {
    func loadManifest() throws -> WorkflowManifest
}

public protocol HistoryRepository: Sendable {
    func save(_ record: HistoryRecord) async throws
    func records(matching query: HistoryQuery) async throws -> [HistoryRecord]
}

public protocol DiagnosticRepository: Sendable {
    func save(_ event: DiagnosticEvent) async throws
    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent]
}

public protocol SettingsStore: Sendable {
    func string(forKey key: AppSettingKey) async throws -> String?
    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String]
    func setString(_ value: String, forKey key: AppSettingKey) async throws
    func removeValue(forKey key: AppSettingKey) async throws
}

public extension SettingsStore {
    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        var values: [AppSettingKey: String] = [:]

        for key in keys {
            if let value = try await string(forKey: key) {
                values[key] = value
            }
        }

        return values
    }
}

public protocol ExportMetadataRepository: Sendable {
    func save(_ export: ExportMetadata) async throws
    func exports(limit: Int?) async throws -> [ExportMetadata]
}
