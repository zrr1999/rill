import Foundation

public enum RecognitionPriority: String, Sendable, Equatable {
    case interactive, foregroundFinal, wakeCandidate
}

public struct RecognitionRequest: Sendable, Equatable {
    public let runID: UUID
    public let selectedText: String
    public let clipboardText: String
    public let clipboardExcluded: Bool
    public let priority: RecognitionPriority
    public var capturedAudio: CapturedAudio?
    public let options: SpeechRecognitionRequestOptions

    public init(
        runID: UUID,
        contextSnapshot: ContextSnapshot,
        priority: RecognitionPriority = .foregroundFinal,
        capturedAudio: CapturedAudio? = nil,
        options: SpeechRecognitionRequestOptions = .empty
    ) {
        self.runID = runID
        self.selectedText = contextSnapshot.focus.selectedText
        self.clipboardText = contextSnapshot.clipboard.plainText
        self.clipboardExcluded = contextSnapshot.clipboard.excludesWorkflowCapture
        self.priority = priority
        self.capturedAudio = capturedAudio
        self.options = options
    }
}

public struct TransformContext: Sendable, Equatable {
    public var runID: UUID
    public var workflow: WorkflowDefinition
    public var contextSnapshot: ContextSnapshot
    public var recognitionResult: RecognitionResult
    public var correctionRequest: ContextualCorrectionRequest?

    public init(
        runID: UUID,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionResult: RecognitionResult,
        correctionRequest: ContextualCorrectionRequest? = nil
    ) {
        self.runID = runID
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.recognitionResult = recognitionResult
        self.correctionRequest = correctionRequest
    }
}

/// One user-visible message that was actually sent to a language model.
///
/// The trace surface is intentionally closed: credentials, request headers,
/// endpoint URLs, captured application context, and arbitrary provider
/// metadata cannot be represented here.
public struct LanguageModelTraceMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable, Equatable {
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Token counts reported by the API. Missing counts are unknown, not zero.
public struct LanguageModelTokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

/// Reviewable provenance for one completed language-model request.
///
/// This value is retained only inside the encrypted, privacy-gated history
/// payload. Its fixed fields deliberately exclude API keys, authorization
/// headers, provider endpoints, tool state, and unrelated foreground context.
public struct LanguageModelTrace: Codable, Sendable, Equatable {
    public var providerID: String
    public var modelID: String
    public var systemPrompt: String
    public var workflowPrompt: String
    public var messages: [LanguageModelTraceMessage]
    public var responseText: String
    public var tokenUsage: LanguageModelTokenUsage?

    public init(
        providerID: String,
        modelID: String,
        systemPrompt: String,
        workflowPrompt: String,
        messages: [LanguageModelTraceMessage],
        responseText: String,
        tokenUsage: LanguageModelTokenUsage? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.workflowPrompt = workflowPrompt
        self.messages = messages
        self.responseText = responseText
        self.tokenUsage = tokenUsage
    }
}

public struct TracedTextTransformation: Sendable, Equatable {
    public var text: String
    public var trace: LanguageModelTrace

    public init(text: String, trace: LanguageModelTrace) {
        self.text = text
        self.trace = trace
    }
}

public protocol SpeechRecognizer: Sendable {
    var id: String { get }
    var capabilities: SpeechRecognizerCapabilities { get }

    /// Implementations should respond to cooperative cancellation. Any provider
    /// that enters non-cancellable native work must first materialize the
    /// captured payload so late work does not depend on a removable audio file.
    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult
}

/// Validates recognizer-specific run prerequisites before privacy-sensitive
/// context is read or audio capture begins.
public typealias RecognitionRunPreflight = @Sendable (WorkflowDefinition) async throws -> Void

public extension SpeechRecognizer {
    var capabilities: SpeechRecognizerCapabilities { .none }
}

public struct DeferredCapturedAudio: Sendable {
    private let task: Task<CapturedAudio, Error>

    public init(task: Task<CapturedAudio, Error>) {
        self.task = task
    }

    public static func resolved(_ capturedAudio: CapturedAudio) -> DeferredCapturedAudio {
        DeferredCapturedAudio(task: Task { capturedAudio })
    }

    public func value() async throws -> CapturedAudio {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels capture finalization. The capture implementation remains
    /// responsible for removing any partial artifact when cancellation throws.
    public func cancel() {
        task.cancel()
    }

}

public protocol AudioCaptureService: Sendable {
    /// Starts a capture whose temporary artifacts remain owned by the service until completion.
    func startCapture(_ request: AudioCaptureRequest) async throws

    /// Finishes capture and transfers any returned managed temporary file to the caller.
    /// Implementations must remove service-owned artifacts before throwing.
    func finishCapture() async throws -> CapturedAudio

    /// Stops input before returning a deferred result under the same ownership
    /// contract as `finishCapture()`. Once this method returns, no new audio
    /// chunk may be captured or transmitted for that run.
    func finishCaptureDeferred() async throws -> DeferredCapturedAudio

    /// Cancels capture and removes all artifacts that have not already been transferred.
    func cancelCapture() async

    /// Cancels only the matching run. A stale cancellation must not affect a newer capture.
    func cancelCapture(runID: UUID) async

    /// Removes a product-owned finite duration limit from the matching active
    /// capture. Returns false when the run is stale or the provider cannot
    /// safely continue without its current limit.
    func removeMaximumDurationLimit(runID: UUID) async -> Bool

    /// Stops capture and drains service-owned managed temporary audio cleanup.
    func shutdown() async
}

public extension AudioCaptureService {
    func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
        let capturedAudio = try await finishCapture()
        return .resolved(capturedAudio)
    }

    /// Compatibility behavior for services that can only host one capture.
    /// Run-aware services should override this method to reject stale cancellation.
    func cancelCapture(runID: UUID) async {
        await cancelCapture()
    }

    func removeMaximumDurationLimit(runID _: UUID) async -> Bool {
        false
    }

    func shutdown() async {
        await cancelCapture()
    }
}

public protocol ContextProvider: Sendable {
    func captureContext() async -> ContextSnapshot
}

public protocol TriggerSource: Sendable {
    var id: String { get }
    var binding: TriggerBinding { get }
    func stream() -> AsyncStream<WorkflowTriggerEvent>
}

public protocol SpeechSynthesizer: Sendable {
    var id: String { get }
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> SpeechAsset
    func releaseResources() async
}

public extension SpeechSynthesizer {
    func releaseResources() async {}
}

public protocol SpeechPlaybackService: Sendable {
    func play(_ asset: SpeechAsset, runID: UUID) async throws
    func stop(runID: UUID) async
    func shutdown() async
}

public protocol TextTransformer: Sendable {
    var id: String { get }
    var supportedKinds: [PostProcessStepKind] { get }
    func transform(text: String, step: PostProcessStep, context: TransformContext) async throws -> String
}

/// A transformer that can return the exact, credential-free request trace
/// alongside its output. Orchestration checks this capability only for LLM
/// steps; ordinary text transformers keep the minimal `TextTransformer` API.
public protocol TracedTextTransformer: TextTransformer {
    func transformWithTrace(
        text: String,
        step: PostProcessStep,
        context: TransformContext
    ) async throws -> TracedTextTransformation
}

/// Allows a transformer to declare that a failed speech-text rewrite may
/// safely fall back to the already recognized text. This is intentionally an
/// error-owned decision so orchestration never guesses that an arbitrary
/// transformer failure is recoverable.
public protocol SpeechTextFallbackEligibleError: Error {
    var allowsSpeechTextFallback: Bool { get }
}

public protocol WorkflowCatalog: Sendable {
    func manifest() -> WorkflowManifest
}

public protocol WorkflowManifestLoader: Sendable {
    func loadManifest() throws -> WorkflowManifest
}

public protocol RunHistoryGenerationSource: Sendable {
    /// Captures the current durable generation at the linearization point where
    /// an asynchronous write intent begins.
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration
}

public protocol HistoryRepository: RunHistoryGenerationSource {
    func save(_ record: WorkflowResultRecord) async throws
    func save(
        _ record: WorkflowResultRecord,
        generation: RunHistoryWriteGeneration
    ) async throws
    func records(matching query: HistoryQuery) async throws -> [WorkflowResultRecord]
}

public protocol HistoryMaintaining: RunHistoryGenerationSource {
    /// Deletes records strictly older than `cutoff` and returns the number removed.
    func deleteRecords(olderThan cutoff: Date) async throws -> Int
    /// Replays one logical clear transition. Rows from older generations are
    /// deleted; a legacy timestamp preserves post-intent schema-4 rows once.
    func deleteRecords(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int
    /// Deletes every history record and returns the number removed.
    func deleteAllRecords() async throws -> Int
}

public enum HistoryRepositoryError: Error, Sendable, Equatable {
    /// The write intent belongs to a logical generation the user already cleared.
    case writeObsoletedByClearBarrier
    /// Reusing a record coordinate with different indexed identity, ordering,
    /// scope, or privacy membership fails closed. Body/correction revisions at
    /// a stable coordinate remain supported.
    case conflictingHistoryRecord(recordID: UUID)
}

public enum WorkflowRunReceiptRepositoryError: Error, Sendable, Equatable {
    case conflictingTerminalReceipt(runID: UUID)
    /// The immutable terminal's write intent belongs to an already-cleared generation.
    case writeObsoletedByClearBarrier(runID: UUID)
}

/// Durable storage for immutable, content-free terminal run receipts.
public protocol WorkflowRunReceiptRepository: RunHistoryGenerationSource {
    /// Inserts a terminal receipt. Re-inserting the same value is idempotent;
    /// a different terminal value for the same run ID must fail closed.
    func insertTerminal(_ receipt: WorkflowRunReceipt) async throws
    func insertTerminal(
        _ receipt: WorkflowRunReceipt,
        generation: RunHistoryWriteGeneration
    ) async throws
    func receipts(matching query: WorkflowRunReceiptQuery) async throws -> [WorkflowRunReceipt]
}

public protocol WorkflowRunReceiptMaintaining: RunHistoryGenerationSource {
    /// Deletes receipts strictly older than `cutoff` and returns the number removed.
    func deleteReceipts(olderThan cutoff: Date) async throws -> Int
    func deleteReceipts(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int
    /// Deletes every receipt and returns the number removed.
    func deleteAllReceipts() async throws -> Int
}

public protocol DiagnosticHistoryMaintaining: RunHistoryGenerationSource {
    /// Deletes events strictly older than `cutoff` and returns the number removed.
    func deleteEvents(olderThan cutoff: Date) async throws -> Int
    func deleteEvents(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int
    /// Deletes every diagnostic event and returns the number removed.
    func deleteAllEvents() async throws -> Int
}

public protocol DiagnosticRepository: RunHistoryGenerationSource {
    func save(_ event: DiagnosticEvent) async throws
    func save(
        _ event: DiagnosticEvent,
        generation: RunHistoryWriteGeneration
    ) async throws
    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent]
}

public enum DiagnosticRepositoryError: Error, Sendable, Equatable {
    /// The event's write intent belongs to an already-cleared generation.
    case writeObsoletedByClearBarrier
}

/// A settings read that separates intact values from rows whose protected
/// payload could not be opened. The result deliberately carries no backend
/// error detail so callers cannot surface stored payloads or provider errors.
public struct SettingsStoreReadSnapshot: Sendable, Equatable {
    public let values: [AppSettingKey: String]
    public let unavailableKeys: Set<AppSettingKey>

    public init(
        values: [AppSettingKey: String],
        unavailableKeys: Set<AppSettingKey> = []
    ) {
        self.values = values
        self.unavailableKeys = unavailableKeys
    }

    public static let empty = SettingsStoreReadSnapshot(values: [:])
}

public protocol SettingsStore: Sendable {
    func string(forKey key: AppSettingKey) async throws -> String?
    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String]
    /// Reads a startup snapshot while isolating individual unreadable payloads
    /// when the backend can distinguish them. Structural storage failures throw.
    func settingsSnapshot(forKeys keys: [AppSettingKey]) async throws -> SettingsStoreReadSnapshot
    func setString(_ value: String, forKey key: AppSettingKey) async throws
    /// Commits every value as one snapshot. Either all values become visible or none do.
    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws
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

    func settingsSnapshot(forKeys keys: [AppSettingKey]) async throws -> SettingsStoreReadSnapshot {
        SettingsStoreReadSnapshot(values: try await strings(forKeys: keys))
    }
}

/// A storage backend that can physically purge logically deleted sensitive data
/// left in database pages and write-ahead logs.
public protocol StorageResiduePurging: Sendable {
    func purgeSensitiveStorageResidue() async throws
}

/// A settings backend that supports physical cleanup after sensitive replacement.
public protocol SensitiveSettingsStore: SettingsStore, StorageResiduePurging {}

public protocol ExportMetadataRepository: Sendable {
    func save(_ export: ExportMetadata) async throws
    func exports(limit: Int?) async throws -> [ExportMetadata]
}
