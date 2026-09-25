import Foundation
import XCTest
@testable import RillCore
@testable import RillPlatform
@testable import RillRuntime

private struct RecordingTestContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private func makeRecordingTestPrivacyGate() -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: {
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        },
        cloudConfirmationProvider: { _, _, _ in true },
        destinationClassifier: { _ in .classified([.localSpeech]) }
    )
}

private func makeRecordingCloudTestPrivacyGate() -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: {
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        },
        cloudConfirmationProvider: { _, _, _ in true },
        destinationClassifier: { _ in .classified([.cloudSpeech]) }
    )
}

private actor RecordingRequestProbe {
    private var request: RecognitionRequest?

    func record(_ request: RecognitionRequest) {
        self.request = request
    }

    func snapshot() -> RecognitionRequest? {
        request
    }
}

private struct RecordingRecognizer: SpeechRecognizer {
    let id = "recording.recognizer"
    let capabilities = SpeechRecognizerCapabilities(supportedHintKinds: [.keyterm])
    let probe: RecordingRequestProbe

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.record(request)
        return RecognitionResult(rawText: "recorded", bestText: "recorded")
    }
}

private actor RecordingOptionsProbe {
    private var callCountValue = 0

    func resolve(_ options: SpeechRecognitionRequestOptions) -> SpeechRecognitionRequestOptions {
        callCountValue += 1
        return options
    }

    func callCount() -> Int {
        callCountValue
    }
}

private enum RecordingPreflightTestError: Error, LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? { "Recognition service is unavailable." }
}

private actor RecordingRunOrderingProbe {
    private var preflightCount = 0
    private var contextCount = 0
    private var confirmationCount = 0
    private var optionsCount = 0

    func rejectPreflight() throws {
        preflightCount += 1
        throw RecordingPreflightTestError.unavailable
    }

    func readContext() -> ContextSnapshot {
        contextCount += 1
        return .empty
    }

    func confirmCloudRun() -> Bool {
        confirmationCount += 1
        return true
    }

    func resolveOptions() -> SpeechRecognitionRequestOptions {
        optionsCount += 1
        return .empty
    }

    func snapshot() -> (preflight: Int, context: Int, confirmation: Int, options: Int) {
        (preflightCount, contextCount, confirmationCount, optionsCount)
    }
}

private actor RecordingFocusIdentityProbe {
    private var currentFocus: FocusPrivacyIdentitySample
    private var privacyContextCallCount = 0
    private var selectedTextCaptureCallCount = 0
    private var lastExpectedFocus: FocusPrivacyIdentitySample?

    init(_ currentFocus: FocusPrivacyIdentitySample) {
        self.currentFocus = currentFocus
    }

    func sample() -> FocusPrivacyIdentitySample {
        currentFocus
    }

    func update(_ focus: FocusPrivacyIdentitySample) {
        currentFocus = focus
    }

    func capturePrivacyContext() -> ContextSnapshot {
        privacyContextCallCount += 1
        return ContextSnapshot(
            focus: currentFocus.focus,
            clipboard: ContextSnapshot.empty.clipboard
        )
    }

    func captureAuthorizedContext(
        applying decision: PrivacyPolicyDecision,
        ifFocusMatches expectedFocus: FocusPrivacyIdentitySample
    ) -> ContextSnapshot? {
        guard currentFocus.hasSamePrivacyIdentity(as: expectedFocus) else {
            return nil
        }
        selectedTextCaptureCallCount += 1
        lastExpectedFocus = expectedFocus
        var focus = currentFocus.focus
        focus.selectedText = "press-target-selection"
        return ContextSnapshot(
            focus: focus,
            clipboard: ContextSnapshot.empty.clipboard
        ).applying(decision)
    }

    func snapshot() -> (
        privacyContext: Int,
        selectedTextCapture: Int,
        lastExpectedFocus: FocusPrivacyIdentitySample?
    ) {
        (privacyContextCallCount, selectedTextCaptureCallCount, lastExpectedFocus)
    }
}

private func makeRecordingFocusIdentitySample(
    applicationName: String = "Notes",
    bundleIdentifier: String = "com.apple.Notes",
    processIdentifier: Int32 = 41,
    secureInput: Bool = false,
    activationRevision: UInt64
) -> FocusPrivacyIdentitySample {
    FocusPrivacyIdentitySample(
        focus: FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            focusedRole: nil,
            selectedText: "",
            secureInput: secureInput
        ),
        applicationActivationRevision: activationRevision
    )
}

private actor RecordingActionProbe {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor BlockingRecognitionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        if isSignaled {
            isSignaled = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation {
            continuation.resume()
        } else {
            isSignaled = true
        }
        continuation = nil
    }
}

private actor RecordingCancellationGate {
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendUntilReleased() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor RecordingQueueTransferGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendAfterTransfer() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct RecordingAction: OutputAction {
    let id = "recording.action"
    let probe: RecordingActionProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        await probe.record(text)
        return .copiedToClipboard
    }
}

private struct BlockingRecordingRecognizer: SpeechRecognizer {
    let id = "recording.blocking-recognizer"
    let probe: RecordingRequestProbe
    let gate: BlockingRecognitionGate

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.record(request)
        await gate.wait()
        return RecognitionResult(rawText: "recorded", bestText: "recorded")
    }
}

private actor MockAudioCaptureService: AudioCaptureService {
    private(set) var startRequest: AudioCaptureRequest?
    private(set) var startCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    private let audio: CapturedAudio
    private let cancellationGate: RecordingCancellationGate?

    init(
        audio: CapturedAudio,
        cancellationGate: RecordingCancellationGate? = nil
    ) {
        self.audio = audio
        self.cancellationGate = cancellationGate
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        startCallCount += 1
        startRequest = request
    }

    func finishCapture() async throws -> CapturedAudio {
        finishCallCount += 1
        return audio
    }

    func cancelCapture() async {
        cancelCallCount += 1
        await cancellationGate?.suspendUntilReleased()
        startRequest = nil
    }

    func cancelCapture(runID: UUID) async {
        guard startRequest?.runID == runID else { return }
        cancelCallCount += 1
        await cancellationGate?.suspendUntilReleased()
        startRequest = nil
    }

    func snapshot() -> AudioCaptureRequest? {
        startRequest
    }

    func startCalls() -> Int {
        startCallCount
    }

    func lifecycleCounts() -> (finish: Int, cancel: Int) {
        (finishCallCount, cancelCallCount)
    }
}

private actor RecordingLiveContextStore {
    private var context: ContextSnapshot
    private var applicationActivationRevision: UInt64 = 0

    init(_ context: ContextSnapshot) {
        self.context = context
    }

    func read() -> ContextSnapshot { context }

    func focusIdentitySample() -> FocusPrivacyIdentitySample {
        FocusPrivacyIdentitySample(
            focus: context.focus,
            applicationActivationRevision: applicationActivationRevision
        )
    }

    func replace(_ context: ContextSnapshot) {
        let previous = self.context.focus
        let next = context.focus
        if previous.applicationName != next.applicationName
            || previous.bundleIdentifier != next.bundleIdentifier
            || previous.processIdentifier != next.processIdentifier
            || previous.secureInput != next.secureInput
        {
            applicationActivationRevision &+= 1
        }
        self.context = context
    }
}

private actor ControlledAudioCaptureService: AudioCaptureService {
    private(set) var startRequest: AudioCaptureRequest?
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    private let audio: CapturedAudio
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(audio: CapturedAudio) {
        self.audio = audio
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        startRequest = request
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finishCapture() async throws -> CapturedAudio {
        finishCallCount += 1
        return audio
    }

    func cancelCapture() async {
        cancelCallCount += 1
        startRequest = nil
        startContinuation?.resume()
        startContinuation = nil
    }

    func allowStartToFinish() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func snapshot() -> AudioCaptureRequest? {
        startRequest
    }
}

private actor BlockingFinishAudioCaptureService: AudioCaptureService {
    private let audio: CapturedAudio
    private var activeRunID: UUID?
    private var startRequest: AudioCaptureRequest?
    private var finishEntered = false
    private var finishReleased = false
    private var finishEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelEntered = false
    private var cancelEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0

    init(audio: CapturedAudio) {
        self.audio = audio
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        startCallCount += 1
        activeRunID = request.runID
        startRequest = request
    }

    func finishCapture() async throws -> CapturedAudio {
        let deferredCapture = try await finishCaptureDeferred()
        return try await deferredCapture.value()
    }

    func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
        guard let finishingRunID = activeRunID else {
            throw CancellationError()
        }
        finishCallCount += 1
        finishEntered = true
        let entryWaiters = finishEntryWaiters
        finishEntryWaiters.removeAll()
        for waiter in entryWaiters {
            waiter.resume()
        }
        if !finishReleased {
            await withCheckedContinuation { continuation in
                finishReleaseWaiters.append(continuation)
            }
        }
        if activeRunID == finishingRunID {
            activeRunID = nil
        }
        return .resolved(audio)
    }

    func cancelCapture() async {
        guard activeRunID != nil else { return }
        cancelCallCount += 1
        activeRunID = nil
        signalCancelEntered()
    }

    func cancelCapture(runID: UUID) async {
        guard activeRunID == runID else { return }
        cancelCallCount += 1
        activeRunID = nil
        signalCancelEntered()
    }

    func waitUntilFinishEntered() async {
        guard !finishEntered else { return }
        await withCheckedContinuation { continuation in
            finishEntryWaiters.append(continuation)
        }
    }

    func releaseFinish() {
        finishReleased = true
        let waiters = finishReleaseWaiters
        finishReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilCancelEntered() async {
        guard !cancelEntered else { return }
        await withCheckedContinuation { continuation in
            cancelEntryWaiters.append(continuation)
        }
    }

    private func signalCancelEntered() {
        cancelEntered = true
        let waiters = cancelEntryWaiters
        cancelEntryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func lifecycleCounts() -> (start: Int, finish: Int, cancel: Int) {
        (startCallCount, finishCallCount, cancelCallCount)
    }

    func snapshot() -> AudioCaptureRequest? {
        startRequest
    }
}

private actor LifetimeRevokingReadyAudioCaptureService: AudioCaptureService {
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0

    func startCapture(_ request: AudioCaptureRequest) async throws {
        startCallCount += 1
        _ = request.audioLifetime?.revoke(.serviceFailure)
    }

    func finishCapture() async throws -> CapturedAudio {
        throw CancellationError()
    }

    func cancelCapture() async {
        cancelCallCount += 1
    }

    func cancelCapture(runID: UUID) async {
        cancelCallCount += 1
    }

    func counts() -> (start: Int, cancel: Int) {
        (startCallCount, cancelCallCount)
    }
}

private func makeCapturedAudioProcessingQueue(
    sessionCoordinator: SessionCoordinator,
    eventBus: EventBus,
    diagnostics: DiagnosticsRecorder? = nil
) -> CapturedAudioProcessingQueue {
    CapturedAudioProcessingQueue(
        sessionCoordinator: sessionCoordinator,
        eventBus: eventBus,
        diagnostics: diagnostics
    )
}

private func collectRecordingEvents(
    from stream: AsyncStream<RillEvent>,
    untilDiagnosticNamed marker: String
) async -> [RillEvent] {
    var events: [RillEvent] = []
    for await event in stream {
        if case .diagnostic(let diagnostic) = event,
           diagnostic.event == marker {
            break
        }
        events.append(event)
    }
    return events
}

private func publishRecordingEventMarker(
    named marker: String,
    on eventBus: EventBus
) async {
    await eventBus.publish(
        .diagnostic(
            DiagnosticEvent(
                subsystem: .platform,
                level: .debug,
                event: marker,
                message: "Recording test event marker."
            )
        )
    )
}

private func recordingRunFailures(in events: [RillEvent]) -> [RillEvent] {
    events.filter { event in
        if case .runFailed = event { return true }
        return false
    }
}

private actor RecordingWorkflowProviderGate {
    private let workflow: WorkflowDefinition
    private var callCount = 0
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(workflow: WorkflowDefinition) {
        self.workflow = workflow
    }

    func load() async -> [WorkflowDefinition] {
        callCount += 1
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return [workflow]
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func calls() -> Int {
        callCount
    }
}

private actor RecordingShutdownCompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func snapshot() -> Bool {
        isComplete
    }
}

private struct StreamHotkeyPreparationFixture {
    let manager: RecordingSessionManager
    let hotkeyTap: HotkeyEventTap
    let audioCaptureService: MockAudioCaptureService
    let workflowProvider: RecordingWorkflowProviderGate
    let diagnostics: DiagnosticsRecorder
    let eventBus: EventBus
    let queue: CapturedAudioProcessingQueue
}

private struct StreamHotkeyFinishingFixture {
    let manager: RecordingSessionManager
    let hotkeyTap: HotkeyEventTap
    let audioCaptureService: BlockingFinishAudioCaptureService
    let diagnostics: DiagnosticsRecorder
    let eventBus: EventBus
    let queue: CapturedAudioProcessingQueue
}

private struct RecordingFocusTargetFixture {
    let manager: RecordingSessionManager
    let audioCaptureService: MockAudioCaptureService
    let focusProbe: RecordingFocusIdentityProbe
    let eventBus: EventBus
    let queue: CapturedAudioProcessingQueue
}

private func makeRecordingFocusTargetFixture(
    initialFocus: FocusPrivacyIdentitySample,
    privacyRunGate: PrivacyRunGate = makeRecordingTestPrivacyGate(),
    runPreflight: @escaping RecognitionRunPreflight = { _ in }
) throws -> RecordingFocusTargetFixture {
    let eventBus = EventBus()
    let workflow = WorkflowDefinition(
        name: "Focus-bound recording",
        trigger: .hotkey,
        pipeline: PipelineDeclaration(recognizerID: "recording.recognizer", outputActions: []),
        ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )
    let audio = try CapturedAudio(
        durationSeconds: 1,
        format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
        inlineData: Data([1])
    )
    let audioCaptureService = MockAudioCaptureService(audio: audio)
    let coordinator = SessionCoordinator(

        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: OutputActionRegistry(actions: []),
        candidateResolver: CandidateResolver(eventBus: eventBus),
        eventBus: eventBus
    )
    let queue = makeCapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus
    )
    let focusProbe = RecordingFocusIdentityProbe(initialFocus)
    let manager = RecordingSessionManager(
        audioCaptureService: audioCaptureService,
        hotkeyTap: HotkeyEventTap(),
        capturedAudioProcessingQueue: queue,
        eventBus: eventBus,
        privacyRunGate: privacyRunGate,
        workflowProvider: { [workflow] },
        privacyContextProvider: { await focusProbe.capturePrivacyContext() },
        focusIdentitySampleProvider: { await focusProbe.sample() },
        targetBoundAuthorizedContextProvider: { decision, expectedFocus in
            await focusProbe.captureAuthorizedContext(
                applying: decision,
                ifFocusMatches: expectedFocus
            )
        },
        runPreflight: runPreflight,
        liveAuthorizationMonitorInterval: .milliseconds(5),
        pushToTalkGestureStateProvider: { _ in false }
    )
    return RecordingFocusTargetFixture(
        manager: manager,
        audioCaptureService: audioCaptureService,
        focusProbe: focusProbe,
        eventBus: eventBus,
        queue: queue
    )
}

private func makeStreamHotkeyFinishingFixture(
    longRecordingModeEnabled: Bool
) throws -> StreamHotkeyFinishingFixture {
    let eventBus = EventBus()
    let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
    let workflow = WorkflowDefinition(
        name: "Stream Hotkey Finishing",
        trigger: .hotkey,
        pipeline: PipelineDeclaration(recognizerID: "recording.recognizer", outputActions: []),
        ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )
    let audio = try CapturedAudio(
        durationSeconds: 1,
        format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
        inlineData: Data([1])
    )
    let audioCaptureService = BlockingFinishAudioCaptureService(audio: audio)
    let coordinator = SessionCoordinator(

        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: OutputActionRegistry(actions: []),
        candidateResolver: CandidateResolver(eventBus: eventBus),
        eventBus: eventBus
    )
    let queue = makeCapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus,
        diagnostics: diagnostics
    )
    let hotkeyTap = HotkeyEventTap()
    let manager = RecordingSessionManager(
        audioCaptureService: audioCaptureService,
        hotkeyTap: hotkeyTap,
        capturedAudioProcessingQueue: queue,
        eventBus: eventBus,
        diagnostics: diagnostics,
        privacyRunGate: makeRecordingTestPrivacyGate(),
        workflowProvider: { [workflow] },
        longRecordingModeProvider: { longRecordingModeEnabled },
        pushToTalkGestureStateProvider: { _ in false }
    )
    return StreamHotkeyFinishingFixture(
        manager: manager,
        hotkeyTap: hotkeyTap,
        audioCaptureService: audioCaptureService,
        diagnostics: diagnostics,
        eventBus: eventBus,
        queue: queue
    )
}

private func makeStreamHotkeyPreparationFixture(
    longRecordingModeEnabled: Bool,
    cancellationGate: RecordingCancellationGate? = nil,
    pushToTalkGestureStateProvider: @escaping @Sendable (
        HotkeyEventTap.PushToTalkGesture
    ) -> Bool = { _ in false }
) throws -> StreamHotkeyPreparationFixture {
    let eventBus = EventBus()
    let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
    let workflow = WorkflowDefinition(
        name: "Stream Hotkey Preparation",
        trigger: .hotkey,
        pipeline: PipelineDeclaration(recognizerID: "recording.recognizer", outputActions: []),
        ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
    )
    let audio = try CapturedAudio(
        durationSeconds: 1,
        format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
        inlineData: Data([1])
    )
    let audioCaptureService = MockAudioCaptureService(
        audio: audio,
        cancellationGate: cancellationGate
    )
    let workflowProvider = RecordingWorkflowProviderGate(workflow: workflow)
    let coordinator = SessionCoordinator(

        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: OutputActionRegistry(actions: []),
        candidateResolver: CandidateResolver(eventBus: eventBus),
        eventBus: eventBus
    )
    let queue = makeCapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus,
        diagnostics: diagnostics
    )
    let hotkeyTap = HotkeyEventTap()
    let manager = RecordingSessionManager(
        audioCaptureService: audioCaptureService,
        hotkeyTap: hotkeyTap,
        capturedAudioProcessingQueue: queue,
        eventBus: eventBus,
        diagnostics: diagnostics,
        privacyRunGate: makeRecordingTestPrivacyGate(),
        workflowProvider: { await workflowProvider.load() },
        longRecordingModeProvider: { longRecordingModeEnabled },
        pushToTalkGestureStateProvider: pushToTalkGestureStateProvider
    )
    return StreamHotkeyPreparationFixture(
        manager: manager,
        hotkeyTap: hotkeyTap,
        audioCaptureService: audioCaptureService,
        workflowProvider: workflowProvider,
        diagnostics: diagnostics,
        eventBus: eventBus,
        queue: queue
    )
}

final class RecordingSessionManagerTests: XCTestCase {
    func testWarmFnStartupDoesNotPublishSeparatePreparingSurface() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Warm Fn Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
        )
        let audioCaptureService = MockAudioCaptureService(
            audio: try CapturedAudio(
                durationSeconds: 1,
                format: AudioFormat(
                    sampleRateHz: 16_000,
                    channelCount: 1,
                    encoding: .pcm16
                ),
                inlineData: Data([1])
            )
        )
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] },
            pushToTalkGestureStateProvider: { _ in false }
        )
        let marker = "recording.warm-start-presentation.\(UUID().uuidString)"
        let stream = await eventBus.stream()
        let collector = Task {
            await collectRecordingEvents(from: stream, untilDiagnosticNamed: marker)
        }

        await manager.beginPushToTalk()
        try? await Task.sleep(for: .milliseconds(350))
        await publishRecordingEventMarker(named: marker, on: eventBus)
        let events = await collector.value

        XCTAssertFalse(events.contains { event in
            guard case .liveSubtitleUpdated(let snapshot) = event else { return false }
            return snapshot.phase == .preparing
        })

        await manager.cancelCurrentRecording()
        await manager.stopForApplicationShutdown()
        await queue.shutdown()
    }

    func testHoldToTalkHasSafetyLimitButNoSilenceEndpoint() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(
            longRecordingModeEnabled: false
        )
        await fixture.workflowProvider.release()

        await fixture.manager.beginPushToTalk()

        let request = await fixture.audioCaptureService.snapshot()
        XCTAssertEqual(request?.maxDurationSeconds, 300)
        XCTAssertNil(
            request?.endpointControl,
            "Physical release remains authoritative for hold-to-talk."
        )

        await fixture.manager.cancelCurrentRecording()
        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testApplicationShutdownRejectsLateAndNewRecordingStarts() async throws {
        let eventBus = EventBus()
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let audioCaptureService = MockAudioCaptureService(
            audio: try CapturedAudio(
                durationSeconds: 1,
                format: AudioFormat(
                    sampleRateHz: 16_000,
                    channelCount: 1,
                    encoding: .pcm16
                ),
                inlineData: Data([1])
            )
        )
        let workflow = WorkflowDefinition(
            name: "Shutdown Recording",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
        )
        let workflowProvider = RecordingWorkflowProviderGate(workflow: workflow)
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: {
                await workflowProvider.load()
            }
        )

        let lateStart = Task {
            await manager.beginPushToTalk()
        }
        await workflowProvider.waitUntilEntered()
        let shutdownCompletion = RecordingShutdownCompletionProbe()
        let shutdownTask = Task {
            await manager.stopForApplicationShutdown()
            await shutdownCompletion.markComplete()
        }
        await Task.yield()
        let shutdownCompletedWhileStartWasBlocked = await shutdownCompletion.snapshot()
        XCTAssertFalse(shutdownCompletedWhileStartWasBlocked)

        await workflowProvider.release()
        await shutdownTask.value
        await manager.start()
        let startedAfterShutdown = await manager.isStartedForTesting

        await lateStart.value
        await manager.beginPushToTalk()

        let state = await manager.currentState()
        let startCalls = await audioCaptureService.startCalls()
        let providerCalls = await workflowProvider.calls()
        XCTAssertFalse(startedAfterShutdown)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(providerCalls, 1)

        await queue.shutdown()
    }

    func testStreamReleaseCanCancelWhileWorkflowPreparationIsBlocked() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(longRecordingModeEnabled: false)
        await fixture.manager.start()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        await fixture.workflowProvider.waitUntilEntered()
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        try? await Task.sleep(for: .milliseconds(180))
        await fixture.workflowProvider.release()
        await fixture.manager.waitForStartOperationsToDrainForTesting()
        let startCalls = await fixture.audioCaptureService.startCalls()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testStreamReleaseRetargetsToExactRunWhenStartupFinishesBeforeDebounce() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(longRecordingModeEnabled: false)
        let releaseReceived = expectation(description: "Pending start received release")
        let events = await fixture.eventBus.stream()
        let observation = Task {
            for await event in events {
                if case .diagnostic(let diagnostic) = event,
                   diagnostic.event == "recording.hotkey.released" {
                    releaseReceived.fulfill()
                    return
                }
            }
        }
        defer { observation.cancel() }
        await fixture.manager.start()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        await fixture.workflowProvider.waitUntilEntered()
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        await fulfillment(of: [releaseReceived], timeout: 2)
        await fixture.workflowProvider.release()
        await fixture.manager.waitForStartOperationsToDrainForTesting()

        guard case .recording = await fixture.manager.currentState() else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail(
                "The exact run must start before its pending release debounce matures."
            )
        }
        let hasPendingStart = await fixture.manager.hasPendingStreamHotkeyStartForTesting
        XCTAssertFalse(hasPendingStart)

        await fixture.manager.waitForHotkeyLifecycleTasksToDrainForTesting()

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycle.finish, 1)
        XCTAssertEqual(lifecycle.cancel, 0)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testStreamSecondTogglePressCanCancelWhileWorkflowPreparationIsBlocked() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(longRecordingModeEnabled: true)
        await fixture.manager.start()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        await fixture.workflowProvider.waitUntilEntered()
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))

        // `testingEmit` only enqueues into the tap stream. Prove that the
        // second press updated the pending toggle intent before releasing the
        // blocked workflow provider; otherwise this test can accidentally
        // observe the equally valid committed-run cancellation path.
        let secondPressDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < secondPressDeadline {
            let pressCount = await fixture.diagnostics.snapshot().count {
                $0.event == "recording.hotkey.pressed"
            }
            if pressCount >= 2 { break }
            await Task.yield()
        }
        let consumedPressCount = await fixture.diagnostics.snapshot().count {
            $0.event == "recording.hotkey.pressed"
        }
        XCTAssertEqual(consumedPressCount, 2)

        await fixture.workflowProvider.release()
        await fixture.manager.waitForStartOperationsToDrainForTesting()
        let startCalls = await fixture.audioCaptureService.startCalls()
        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(lifecycle.cancel, 0)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testStreamFailedTapRecoveryCancelsHeldPendingStartWithoutFinalPhysicalRelease() async throws {
        let gestureState = GestureStateBox(isActive: true)
        let fixture = try makeStreamHotkeyPreparationFixture(
            longRecordingModeEnabled: false,
            pushToTalkGestureStateProvider: { _ in gestureState.currentValue }
        )
        await fixture.manager.start()

        guard case .swallow(let pressEvent?) = fixture.hotkeyTap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        ) else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected the physical Fn press to start push-to-talk.")
        }
        fixture.hotkeyTap.testingEmit(pressEvent)
        await fixture.workflowProvider.waitUntilEntered()
        guard let interruptionRelease = fixture.hotkeyTap.testingInterruptPushToTalk(
            preservingActiveTrigger: true
        ) else {
            await fixture.workflowProvider.release()
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected tap disablement to publish a recoverable release.")
        }
        fixture.hotkeyTap.testingEmit(interruptionRelease)
        try? await Task.sleep(for: .milliseconds(180))

        let marker = "recording.pending-global-input-unavailable.\(UUID().uuidString)"
        let eventStream = await fixture.eventBus.stream()
        let eventCollector = Task {
            await collectRecordingEvents(
                from: eventStream,
                untilDiagnosticNamed: marker
            )
        }

        // The recoverable release is ignored while the physical Fn state still
        // appears held. Producer loss must bypass that debounce/state check,
        // because the dead tap cannot deliver the eventual physical key-up.
        let teardownEvent = fixture.hotkeyTap.testingResetRecognizersForEventTapTeardown()
        fixture.hotkeyTap.testingEmit(teardownEvent)
        for _ in 0..<200 {
            if await fixture.manager.hasPendingStreamHotkeyStartForTesting == false { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let pendingWasCleared = await fixture.manager.hasPendingStreamHotkeyStartForTesting == false
        XCTAssertTrue(pendingWasCleared)

        gestureState.setActive(false)
        await fixture.workflowProvider.release()
        await fixture.manager.waitForStartOperationsToDrainForTesting()

        let startCalls = await fixture.audioCaptureService.startCalls()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(finalState, .idle)
        await publishRecordingEventMarker(named: marker, on: fixture.eventBus)
        let events = await eventCollector.value
        XCTAssertTrue(
            recordingRunFailures(in: events).isEmpty,
            "A pending hotkey start without a run must not create a failure history event."
        )

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testStreamGlobalInputUnavailableCancelsActiveToggleWithoutGestureLatch() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(longRecordingModeEnabled: true)
        await fixture.manager.start()

        guard case .swallow(let pressEvent?) = fixture.hotkeyTap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        ) else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected the physical Fn press to start toggle recording.")
        }
        fixture.hotkeyTap.testingEmit(pressEvent)
        await fixture.workflowProvider.waitUntilEntered()
        await fixture.workflowProvider.release()
        await fixture.manager.waitForStartOperationsToDrainForTesting()
        guard case .recording = await fixture.manager.currentState() else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected the toggle recording to become active.")
        }

        // Toggle mode intentionally ignores the physical release, so producer
        // loss must remain gestureless and force the active capture to stop.
        guard case .swallow(let releaseEvent?) = fixture.hotkeyTap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: []
        ) else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected the physical Fn release to clear the recognizer latch.")
        }
        fixture.hotkeyTap.testingEmit(releaseEvent)
        let teardownEvent = fixture.hotkeyTap.testingResetRecognizersForEventTapTeardown()
        fixture.hotkeyTap.testingEmit(teardownEvent)
        for _ in 0..<200 {
            if await fixture.manager.currentState() == .idle { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        let lifecycleCounts = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycleCounts.cancel, 1)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testGlobalInputUnavailablePublishesOnceAfterRecordingCancellationCompletes() async throws {
        let cancellationGate = RecordingCancellationGate()
        let fixture = try makeStreamHotkeyPreparationFixture(
            longRecordingModeEnabled: false,
            cancellationGate: cancellationGate
        )
        await fixture.workflowProvider.release()
        await fixture.manager.beginPushToTalk()
        guard case .recording(let runID) = await fixture.manager.currentState() else {
            await cancellationGate.release()
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected an active recording before global input became unavailable.")
        }

        let beforeMarker = "recording.global-input-before-cancel.\(UUID().uuidString)"
        let beforeStream = await fixture.eventBus.stream()
        let beforeCollector = Task {
            await collectRecordingEvents(
                from: beforeStream,
                untilDiagnosticNamed: beforeMarker
            )
        }
        let interruptionTask = Task {
            await fixture.manager.processHotkeyEvent(.globalInputUnavailable)
        }
        await cancellationGate.waitUntilEntered()
        await fixture.manager.processHotkeyEvent(.globalInputUnavailable)
        await publishRecordingEventMarker(named: beforeMarker, on: fixture.eventBus)
        let eventsBeforeCancellationCompleted = await beforeCollector.value
        XCTAssertTrue(
            recordingRunFailures(in: eventsBeforeCancellationCompleted).isEmpty,
            "The user-visible failure must not precede capture cancellation completion."
        )

        let afterMarker = "recording.global-input-after-cancel.\(UUID().uuidString)"
        let afterStream = await fixture.eventBus.stream()
        let afterCollector = Task {
            await collectRecordingEvents(
                from: afterStream,
                untilDiagnosticNamed: afterMarker
            )
        }
        await cancellationGate.release()
        await interruptionTask.value
        await publishRecordingEventMarker(named: afterMarker, on: fixture.eventBus)
        let eventsAfterCancellationCompleted = await afterCollector.value
        let failures = recordingRunFailures(in: eventsAfterCancellationCompleted)
        XCTAssertEqual(failures.count, 1)
        if case .runFailed(
            let failedRunID,
            let workflow,
            let message
        )? = failures.first {
            XCTAssertEqual(failedRunID, runID)
            XCTAssertEqual(workflow?.fallbackName, "Stream Hotkey Preparation")
            XCTAssertEqual(message, HistoryFailureSanitizer.globalInputUnavailableMessage)
        } else {
            XCTFail("Expected one run-scoped global-input failure.")
        }

        let duplicateMarker = "recording.global-input-duplicate.\(UUID().uuidString)"
        let duplicateStream = await fixture.eventBus.stream()
        let duplicateCollector = Task {
            await collectRecordingEvents(
                from: duplicateStream,
                untilDiagnosticNamed: duplicateMarker
            )
        }
        await fixture.manager.processHotkeyEvent(.globalInputUnavailable)
        await publishRecordingEventMarker(named: duplicateMarker, on: fixture.eventBus)
        let duplicateEvents = await duplicateCollector.value
        XCTAssertTrue(
            recordingRunFailures(in: duplicateEvents).isEmpty,
            "Once the interrupted run is idle, repeated teardown signals must not duplicate its failure."
        )

        let lifecycleCounts = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycleCounts.cancel, 1)
        XCTAssertEqual(finalState, .idle)
        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testStreamGlobalInputCancellationConsumesBusyHotkeysWithoutRestarting() async throws {
        let cancellationGate = RecordingCancellationGate()
        let fixture = try makeStreamHotkeyPreparationFixture(
            longRecordingModeEnabled: true,
            cancellationGate: cancellationGate
        )
        await fixture.manager.start()
        await fixture.workflowProvider.release()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        for _ in 0..<500 {
            if case .recording = await fixture.manager.currentState() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard case .recording(let runID) = await fixture.manager.currentState() else {
            await cancellationGate.release()
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected an active toggle recording before producer loss.")
        }

        fixture.hotkeyTap.testingEmit(.globalInputUnavailable)
        await cancellationGate.waitUntilEntered()
        let busyState = await fixture.manager.currentState()
        XCTAssertEqual(busyState, .cancelling(runID))

        // These events arrive while the external capture cancellation is
        // suspended. The listener must consume them now, not replay the press
        // after the managed operation returns the state to idle.
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        for _ in 0..<500 {
            let pressCount = await fixture.diagnostics.snapshot().count {
                $0.event == "recording.hotkey.pressed"
            }
            if pressCount >= 2 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let consumedPressCount = await fixture.diagnostics.snapshot().count {
            $0.event == "recording.hotkey.pressed"
        }
        let providerCallsWhileCancelling = await fixture.workflowProvider.calls()
        XCTAssertEqual(consumedPressCount, 2)
        XCTAssertEqual(providerCallsWhileCancelling, 1)

        await cancellationGate.release()
        for _ in 0..<500 {
            if await fixture.manager.currentState() == .idle { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<50 { await Task.yield() }

        let startCalls = await fixture.audioCaptureService.startCalls()
        let providerCalls = await fixture.workflowProvider.calls()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testShutdownDrainsManagedGlobalInputCancellation() async throws {
        let cancellationGate = RecordingCancellationGate()
        let fixture = try makeStreamHotkeyPreparationFixture(
            longRecordingModeEnabled: false,
            cancellationGate: cancellationGate
        )
        await fixture.manager.start()
        await fixture.workflowProvider.release()
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        for _ in 0..<500 {
            if case .recording = await fixture.manager.currentState() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        fixture.hotkeyTap.testingEmit(.globalInputUnavailable)
        await cancellationGate.waitUntilEntered()
        let completion = RecordingShutdownCompletionProbe()
        let shutdownTask = Task {
            await fixture.manager.stopForApplicationShutdown()
            await completion.markComplete()
        }
        for _ in 0..<100 { await Task.yield() }
        let completedWhileBlocked = await completion.snapshot()
        XCTAssertFalse(completedWhileBlocked)

        await cancellationGate.release()
        await shutdownTask.value
        let completedAfterRelease = await completion.snapshot()
        let finalState = await fixture.manager.currentState()
        XCTAssertTrue(completedAfterRelease)
        XCTAssertEqual(finalState, .idle)
        await fixture.queue.shutdown()
    }

    func testGlobalInputUnavailablePublishesRunScopedFailureWhileCaptureIsPreparing() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Interrupted Preparing Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([1])
        )
        let audioCaptureService = ControlledAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] }
        )
        let preparingEventStream = await eventBus.stream()
        let preparingEvent = Task { () -> LiveSubtitleSnapshot? in
            for await event in preparingEventStream {
                if case .liveSubtitleUpdated(let snapshot) = event,
                   snapshot.phase == .preparing
                {
                    return snapshot
                }
            }
            return nil
        }
        let beginTask = Task {
            await manager.beginPushToTalk()
        }
        while await audioCaptureService.snapshot() == nil {
            await Task.yield()
        }
        guard case .preparing(let runID) = await manager.currentState() else {
            await audioCaptureService.allowStartToFinish()
            await beginTask.value
            await manager.stopForApplicationShutdown()
            await queue.shutdown()
            return XCTFail("Expected an assigned run to remain in capture preparation.")
        }
        let preparingSnapshot = await preparingEvent.value
        XCTAssertEqual(preparingSnapshot?.runID, runID)
        XCTAssertEqual(preparingSnapshot?.workflow?.fallbackName, workflow.name)
        XCTAssertEqual(preparingSnapshot?.providerID, "recording.recognizer")

        let marker = "recording.preparing-global-input-unavailable.\(UUID().uuidString)"
        let eventStream = await eventBus.stream()
        let eventCollector = Task {
            await collectRecordingEvents(
                from: eventStream,
                untilDiagnosticNamed: marker
            )
        }
        await manager.processHotkeyEvent(.globalInputUnavailable)
        await beginTask.value
        await publishRecordingEventMarker(named: marker, on: eventBus)
        let failures = recordingRunFailures(in: await eventCollector.value)

        XCTAssertEqual(failures.count, 1)
        if case .runFailed(
            let failedRunID,
            let failedWorkflow,
            let message
        )? = failures.first {
            XCTAssertEqual(failedRunID, runID)
            XCTAssertEqual(failedWorkflow?.fallbackName, workflow.name)
            XCTAssertEqual(message, HistoryFailureSanitizer.globalInputUnavailableMessage)
        } else {
            XCTFail("Expected one run-scoped preparation interruption failure.")
        }
        let finalState = await manager.currentState()
        XCTAssertEqual(finalState, .idle)

        await manager.stopForApplicationShutdown()
        await queue.shutdown()
    }

    func testGlobalInputUnavailableDoesNotPublishFailureWhileTranscribing() async throws {
        let fixture = try makeStreamHotkeyFinishingFixture(longRecordingModeEnabled: true)
        await fixture.manager.start()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        for _ in 0..<500 {
            if case .recording = await fixture.manager.currentState() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard case .recording = await fixture.manager.currentState() else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected an active recording before entering transcription.")
        }

        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        await fixture.audioCaptureService.waitUntilFinishEntered()
        guard case .transcribing = await fixture.manager.currentState() else {
            await fixture.audioCaptureService.releaseFinish()
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected capture finalization to claim the transcribing state.")
        }

        let marker = "recording.transcribing-global-input-unavailable.\(UUID().uuidString)"
        let eventStream = await fixture.eventBus.stream()
        let eventCollector = Task {
            await collectRecordingEvents(
                from: eventStream,
                untilDiagnosticNamed: marker
            )
        }
        await fixture.manager.processHotkeyEvent(.globalInputUnavailable)
        await publishRecordingEventMarker(named: marker, on: fixture.eventBus)
        let events = await eventCollector.value
        XCTAssertTrue(
            recordingRunFailures(in: events).isEmpty,
            "Loss of global input after capture stopped must not overwrite transcription outcome."
        )

        await fixture.audioCaptureService.releaseFinish()
        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testShutdownDrainsStreamOwnedPreparationTask() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(longRecordingModeEnabled: false)
        await fixture.manager.start()
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        await fixture.workflowProvider.waitUntilEntered()

        let completion = RecordingShutdownCompletionProbe()
        let shutdownTask = Task {
            await fixture.manager.stopForApplicationShutdown()
            await completion.markComplete()
        }
        for _ in 0..<100 { await Task.yield() }
        let completedWhileBlocked = await completion.snapshot()
        XCTAssertFalse(completedWhileBlocked)

        await fixture.workflowProvider.release()
        await shutdownTask.value
        let completedAfterRelease = await completion.snapshot()
        XCTAssertTrue(completedAfterRelease)
        await fixture.queue.shutdown()
    }

    func testStreamToggleStopRetryDuringBlockedFinishCannotRestartRecording() async throws {
        let fixture = try makeStreamHotkeyFinishingFixture(longRecordingModeEnabled: true)
        await fixture.manager.start()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        for _ in 0..<500 {
            if case .recording = await fixture.manager.currentState() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard case .recording = await fixture.manager.currentState() else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected the first toggle press to start recording.")
        }

        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        await fixture.audioCaptureService.waitUntilFinishEntered()
        guard case .transcribing = await fixture.manager.currentState() else {
            await fixture.audioCaptureService.releaseFinish()
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("The toggle stop must claim the busy state before finalization suspends.")
        }

        // A user may press again when stop feedback is slow. These events
        // arrived while the run was busy and must not be replayed as a fresh
        // toggle after finalization returns the manager to idle.
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        for _ in 0..<500 {
            let pressCount = await fixture.diagnostics.snapshot().count {
                $0.event == "recording.hotkey.pressed"
            }
            if pressCount >= 3 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let consumedPressCount = await fixture.diagnostics.snapshot().count {
            $0.event == "recording.hotkey.pressed"
        }
        let startCountWhileFinishing = await fixture.audioCaptureService.startCallCount
        XCTAssertEqual(consumedPressCount, 3)
        XCTAssertEqual(startCountWhileFinishing, 1)
        guard case .transcribing = await fixture.manager.currentState() else {
            await fixture.audioCaptureService.releaseFinish()
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("A stop retry must be consumed while the original finish remains busy.")
        }

        await fixture.audioCaptureService.releaseFinish()
        for _ in 0..<500 {
            if await fixture.manager.currentState() == .idle { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<50 { await Task.yield() }

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycle.start, 1)
        XCTAssertEqual(lifecycle.finish, 1)
        XCTAssertEqual(finalState, .idle)
        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testStreamHoldPressDuringBlockedFinishIsIgnoredAndShutdownDrainsFinishTask() async throws {
        let fixture = try makeStreamHotkeyFinishingFixture(longRecordingModeEnabled: false)
        await fixture.manager.start()

        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        for _ in 0..<500 {
            if case .recording = await fixture.manager.currentState() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard case .recording = await fixture.manager.currentState() else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Expected the hold press to start recording.")
        }

        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        await fixture.audioCaptureService.waitUntilFinishEntered()
        fixture.hotkeyTap.testingEmit(.pushToTalkPressed(.fnHold))
        fixture.hotkeyTap.testingEmit(.pushToTalkReleased(.fnHold))
        for _ in 0..<500 {
            let pressCount = await fixture.diagnostics.snapshot().count {
                $0.event == "recording.hotkey.pressed"
            }
            if pressCount >= 2 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let consumedPressCount = await fixture.diagnostics.snapshot().count {
            $0.event == "recording.hotkey.pressed"
        }
        let startCountWhileFinishing = await fixture.audioCaptureService.startCallCount
        XCTAssertEqual(consumedPressCount, 2)
        XCTAssertEqual(startCountWhileFinishing, 1)

        let shutdownCompletion = RecordingShutdownCompletionProbe()
        let shutdownTask = Task {
            await fixture.manager.stopForApplicationShutdown()
            await shutdownCompletion.markComplete()
        }
        await fixture.audioCaptureService.waitUntilCancelEntered()
        let completedWhileFinishWasBlocked = await shutdownCompletion.snapshot()
        XCTAssertFalse(
            completedWhileFinishWasBlocked,
            "Shutdown must retain and drain the managed finish task even after cancelling it."
        )

        await fixture.audioCaptureService.releaseFinish()
        await shutdownTask.value
        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycle.start, 1)
        XCTAssertEqual(lifecycle.finish, 1)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(finalState, .idle)
        await fixture.queue.shutdown()
    }

    func testReadyCaptureWithSynchronouslyRevokedLifetimeNeverPublishesRecordingOrCue() async throws {
        let eventBus = EventBus()
        let audioCaptureService = LifetimeRevokingReadyAudioCaptureService()
        let workflow = WorkflowDefinition(
            name: "Revoked Ready Capture",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(recognizerID: "recording.recognizer", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "red")
        )
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] },
            recordingCueAction: { _, _ in }
        )

        let marker = "recording.synchronously-revoked-ready.\(UUID().uuidString)"
        let eventStream = await eventBus.stream()
        let eventCollector = Task {
            await collectRecordingEvents(
                from: eventStream,
                untilDiagnosticNamed: marker
            )
        }
        await manager.beginPushToTalk()
        await publishRecordingEventMarker(named: marker, on: eventBus)
        let failures = recordingRunFailures(in: await eventCollector.value)

        let counts = await audioCaptureService.counts()
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.cancel, 1)
        let finalState = await manager.currentState()
        let cueCount = await manager.completedStartCueCountForTesting
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(cueCount, 0)
        XCTAssertEqual(failures.count, 1)
        if case .runFailed(_, _, let message)? = failures.first {
            XCTAssertEqual(message, HistoryFailureSanitizer.microphoneInputUnavailableMessage)
        } else {
            XCTFail("Expected one run-scoped microphone failure.")
        }
        await manager.stopForApplicationShutdown()
        await queue.shutdown()
    }

    func testPostStartCaptureServiceFailureCancelsExactHotkeyRun() async throws {
        let fixture = try makeStreamHotkeyPreparationFixture(
            longRecordingModeEnabled: false
        )
        await fixture.workflowProvider.release()
        await fixture.manager.beginPushToTalk()

        let capturedRequest = await fixture.audioCaptureService.snapshot()
        let request = try XCTUnwrap(capturedRequest)
        let lifetime = try XCTUnwrap(request.audioLifetime)
        XCTAssertTrue(lifetime.revoke(.serviceFailure))

        for _ in 0..<500 {
            if await fixture.manager.currentState() == .idle { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycle.finish, 0)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        let failureDiagnostics = await fixture.diagnostics.snapshot().filter {
            $0.event == "recording.capture-service-failed" && $0.runID == request.runID
        }
        XCTAssertEqual(failureDiagnostics.count, 1)
        await fixture.queue.shutdown()
    }

    func testCaptureServiceFailureWinsReleaseRaceAndCancelsExactFinishingRun() async throws {
        let fixture = try makeStreamHotkeyFinishingFixture(
            longRecordingModeEnabled: false
        )
        await fixture.manager.beginPushToTalk()
        let capturedRequest = await fixture.audioCaptureService.snapshot()
        let request = try XCTUnwrap(capturedRequest)
        let lifetime = try XCTUnwrap(request.audioLifetime)

        let finishingTask = Task {
            await fixture.manager.endPushToTalk()
        }
        await fixture.audioCaptureService.waitUntilFinishEntered()
        XCTAssertTrue(lifetime.revoke(.serviceFailure))
        await fixture.audioCaptureService.waitUntilCancelEntered()
        await fixture.audioCaptureService.releaseFinish()
        await finishingTask.value

        for _ in 0..<500 {
            if await fixture.manager.currentState() == .idle { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        let finalState = await fixture.manager.currentState()
        XCTAssertEqual(lifecycle.start, 1)
        XCTAssertEqual(lifecycle.finish, 1)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(finalState, .idle)

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testPushToTalkCloudTextWorkflowStopsWhenFocusBecomesSensitive() async throws {
        let fixture = try makeLiveRevocationFixture()

        await fixture.manager.beginPushToTalk()
        let request = await fixture.audioCaptureService.snapshot()
        XCTAssertNotNil(request?.audioLifetime)

        await fixture.contexts.replace(
            makeRecordingLiveContext(bundleIdentifier: "com.1password.1password")
        )
        await waitForLiveRevocation(manager: fixture.manager)

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        XCTAssertEqual(lifecycle.finish, 0)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(request?.audioLifetime?.state, .revoked(.authorizationInvalidated))
    }

    func testToggleCloudTextWorkflowStopsWhenFocusBecomesSensitive() async throws {
        let fixture = try makeLiveRevocationFixture()

        await fixture.manager.toggleLongRecording()
        let request = await fixture.audioCaptureService.snapshot()
        XCTAssertNotNil(request?.audioLifetime)

        await fixture.contexts.replace(
            makeRecordingLiveContext(bundleIdentifier: "com.apple.Passwords")
        )
        await waitForLiveRevocation(manager: fixture.manager)

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        XCTAssertEqual(lifecycle.finish, 0)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(request?.audioLifetime?.state, .revoked(.authorizationInvalidated))
    }

    func testOldFinishResumingAfterQueueTransferCannotResetNewRecording() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Queue Transfer Recording",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "blue")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/dev/null")
        )
        let captureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let transferGate = RecordingQueueTransferGate()
        let queue = CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            rejectedCapturedAudioRemoval: { capturedAudio in
                _ = try capturedAudio.removeManagedTemporaryFile()
            },
            rejectedCleanupInitialRetryDelay: .milliseconds(1),
            rejectedCleanupMaximumRetryDelay: .milliseconds(4),
            rejectedCleanupSleep: { delay in
                try await Task.sleep(for: delay)
            },
            ownershipTransferObserver: { _ in
                await transferGate.suspendAfterTransfer()
            }
        )
        let manager = RecordingSessionManager(
            audioCaptureService: captureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] }
        )

        await manager.beginPushToTalk()
        let firstCapture = await captureService.snapshot()
        let firstRunID = try XCTUnwrap(firstCapture?.runID)
        let firstLifetime = try XCTUnwrap(firstCapture?.audioLifetime)
        let finishTask = Task {
            await manager.endPushToTalk()
        }
        await transferGate.waitUntilEntered()

        let cancellationTask = Task {
            await manager.cancelCurrentRecording(runID: firstRunID)
        }
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var cancellationWasAccepted = false
        while ContinuousClock.now < cancellationDeadline {
            if firstLifetime.state == .revoked(.captureCancelled),
               await manager.currentState() == .cancelling(firstRunID) {
                cancellationWasAccepted = true
                break
            }
            await Task.yield()
        }
        guard cancellationWasAccepted else {
            await transferGate.release()
            await cancellationTask.value
            await finishTask.value
            await queue.shutdown()
            XCTFail("The first recording cancellation was not accepted before the deadline.")
            return
        }

        // A new run must not start while queue-owned cancellation is still
        // draining. The old operation retains the busy claim until teardown
        // has actually completed.
        await manager.beginPushToTalk()
        let captureWhileCancelling = await captureService.snapshot()
        let stateWhileCancelling = await manager.currentState()
        XCTAssertNil(captureWhileCancelling)
        XCTAssertEqual(stateWhileCancelling, .cancelling(firstRunID))

        await transferGate.release()
        await cancellationTask.value
        await finishTask.value

        let stateAfterCancellation = await manager.currentState()
        XCTAssertEqual(stateAfterCancellation, .idle)
        await manager.beginPushToTalk()
        let secondCapture = await captureService.snapshot()
        let secondRunID = try XCTUnwrap(secondCapture?.runID)
        XCTAssertNotEqual(firstRunID, secondRunID)

        let finalCapture = await captureService.snapshot()
        let finalState = await manager.currentState()
        XCTAssertEqual(finalCapture?.runID, secondRunID)
        XCTAssertEqual(finalState, .recording(secondRunID))
        XCTAssertEqual(firstLifetime.state, .revoked(.captureCancelled))

        await manager.cancelCurrentRecording(runID: secondRunID)
        await queue.shutdown()
    }

    func testLegacyClipboardHotkeyWorkflowIsRejectedBeforePreflightPrivacyContextOptionsOrCapture() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Legacy Clipboard Automation",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "remote.speech",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: ["eventType": "groupItemCreated"]
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/unused-legacy-workflow.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let ordering = RecordingRunOrderingProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                _ = await ordering.readContext()
                return .defaults
            },
            cloudConfirmationProvider: { _, _, _ in
                await ordering.confirmCloudRun()
            }
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus
            ),
            eventBus: eventBus,
            privacyRunGate: gate,
            workflowProvider: { [workflow] },
            contextProvider: { await ordering.readContext() },
            privacyContextProvider: { await ordering.readContext() },
            authorizedContextProvider: { _ in await ordering.readContext() },
            recognitionOptionsProvider: { _, _ in await ordering.resolveOptions() },
            runPreflight: { _ in try await ordering.rejectPreflight() }
        )
        let stream = await eventBus.stream()
        let failureCollector = Task { () -> RillEvent? in
            for await event in stream {
                if case .runFailed = event { return event }
            }
            return nil
        }
        await Task.yield()

        await manager.beginPushToTalk()

        let counts = await ordering.snapshot()
        let startCallCount = await audioCaptureService.startCalls()
        let state = await manager.currentState()
        let failure = await failureCollector.value
        XCTAssertEqual(counts.preflight, 0)
        XCTAssertEqual(counts.context, 0)
        XCTAssertEqual(counts.confirmation, 0)
        XCTAssertEqual(counts.options, 0)
        XCTAssertEqual(startCallCount, 0)
        XCTAssertEqual(state, .idle)
        if case .runFailed(_, _, let message)? = failure {
            XCTAssertEqual(
                message,
                SessionCoordinator.SessionError.unsupportedWorkflow(
                    .legacyClipboardAutomationUnsupported
                ).localizedDescription
            )
        } else {
            XCTFail("Expected runFailed event.")
        }
    }

    func testHotkeyPreflightFailurePrecedesPrivacyContextOptionsAndCapture() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Unavailable Cloud Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(recognizerID: "remote.speech", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "cloud", accentColorName: "blue")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/unused-preflight-failure.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let ordering = RecordingRunOrderingProbe()
        let gate = PrivacyRunGate(
            settingsProvider: { .defaults },
            cloudConfirmationProvider: { _, _, _ in
                await ordering.confirmCloudRun()
            }
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus
            ),
            eventBus: eventBus,
            privacyRunGate: gate,
            workflowProvider: { [workflow] },
            contextProvider: { await ordering.readContext() },
            privacyContextProvider: { await ordering.readContext() },
            authorizedContextProvider: { _ in await ordering.readContext() },
            recognitionOptionsProvider: { _, _ in await ordering.resolveOptions() },
            runPreflight: { _ in try await ordering.rejectPreflight() }
        )
        let stream = await eventBus.stream()
        let failureCollector = Task { () -> RillEvent? in
            for await event in stream {
                if case .runFailed = event { return event }
            }
            return nil
        }
        await Task.yield()

        await manager.beginPushToTalk()

        let counts = await ordering.snapshot()
        let startCallCount = await audioCaptureService.startCalls()
        let state = await manager.currentState()
        let failure = await failureCollector.value
        XCTAssertEqual(counts.preflight, 1)
        XCTAssertEqual(counts.context, 0)
        XCTAssertEqual(counts.confirmation, 0)
        XCTAssertEqual(counts.options, 0)
        XCTAssertEqual(startCallCount, 0)
        XCTAssertEqual(state, .idle)
        if case .runFailed(_, _, let message)? = failure {
            XCTAssertEqual(message, RecordingPreflightTestError.unavailable.localizedDescription)
        } else {
            XCTFail("Expected runFailed event.")
        }
    }

    func testHotkeyFocusRevisionChangeDuringPreflightFailsBeforeSelectedTextOrCapture() async throws {
        let initialFocus = makeRecordingFocusIdentitySample(activationRevision: 7)
        let preflightGate = RecordingCancellationGate()
        let fixture = try makeRecordingFocusTargetFixture(
            initialFocus: initialFocus,
            runPreflight: { _ in
                await preflightGate.suspendUntilReleased()
            }
        )
        let stream = await fixture.eventBus.stream()
        let failureCollector = Task { () -> RillEvent? in
            for await event in stream {
                if case .runFailed = event { return event }
            }
            return nil
        }
        await Task.yield()

        let startTask = Task {
            await fixture.manager.beginPushToTalk()
        }
        await preflightGate.waitUntilEntered()
        await fixture.focusProbe.update(
            makeRecordingFocusIdentitySample(activationRevision: 8)
        )
        await preflightGate.release()
        await startTask.value

        let focusCounts = await fixture.focusProbe.snapshot()
        let startCallCount = await fixture.audioCaptureService.startCalls()
        let state = await fixture.manager.currentState()
        let failure = await failureCollector.value
        XCTAssertEqual(focusCounts.privacyContext, 0)
        XCTAssertEqual(focusCounts.selectedTextCapture, 0)
        XCTAssertNil(focusCounts.lastExpectedFocus)
        XCTAssertEqual(startCallCount, 0)
        XCTAssertEqual(state, .idle)
        if case .runFailed(_, _, let message)? = failure {
            XCTAssertEqual(
                message,
                PrivacyRunGate.GateError.contextChangedDuringAuthorization.localizedDescription
            )
        } else {
            XCTFail("Expected target-focus drift to publish runFailed.")
        }

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testHotkeyStableFocusBindsAuthorizedSelectedTextCaptureToPressTarget() async throws {
        let initialFocus = makeRecordingFocusIdentitySample(activationRevision: 11)
        let fixture = try makeRecordingFocusTargetFixture(initialFocus: initialFocus)

        await fixture.manager.beginPushToTalk()

        let request = await fixture.audioCaptureService.snapshot()
        let focusCounts = await fixture.focusProbe.snapshot()
        let state = await fixture.manager.currentState()
        XCTAssertNotNil(request)
        XCTAssertGreaterThan(focusCounts.privacyContext, 0)
        XCTAssertEqual(focusCounts.selectedTextCapture, 1)
        XCTAssertTrue(
            focusCounts.lastExpectedFocus?.hasSamePrivacyIdentity(as: initialFocus) == true
        )
        guard case .recording(let runID) = state else {
            await fixture.manager.stopForApplicationShutdown()
            await fixture.queue.shutdown()
            return XCTFail("Stable target focus should allow recording to start.")
        }
        XCTAssertEqual(request?.runID, runID)

        await fixture.manager.cancelCurrentRecording(runID: runID)
        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testLiveCloudCaptureStopsWhenPrivacyFocusIdentityDrifts() async throws {
        let initialFocus = makeRecordingFocusIdentitySample(activationRevision: 12)
        let fixture = try makeRecordingFocusTargetFixture(
            initialFocus: initialFocus,
            privacyRunGate: makeRecordingCloudTestPrivacyGate()
        )

        await fixture.manager.beginPushToTalk()
        let request = await fixture.audioCaptureService.snapshot()
        XCTAssertNotNil(request?.audioLifetime)

        await fixture.focusProbe.update(
            makeRecordingFocusIdentitySample(
                applicationName: "Passwords",
                bundleIdentifier: "com.apple.Passwords",
                processIdentifier: 99,
                secureInput: true,
                activationRevision: 13
            )
        )
        await waitForLiveRevocation(manager: fixture.manager)

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        XCTAssertEqual(lifecycle.finish, 0)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(
            request?.audioLifetime?.state,
            .revoked(.authorizationInvalidated)
        )

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testLiveCloudCaptureStopsWhenSecureInputAppearsInSameApplication() async throws {
        let initialFocus = makeRecordingFocusIdentitySample(activationRevision: 14)
        let fixture = try makeRecordingFocusTargetFixture(
            initialFocus: initialFocus,
            privacyRunGate: makeRecordingCloudTestPrivacyGate()
        )

        await fixture.manager.beginPushToTalk()
        let request = await fixture.audioCaptureService.snapshot()
        XCTAssertNotNil(request?.audioLifetime)

        await fixture.focusProbe.update(
            makeRecordingFocusIdentitySample(
                secureInput: true,
                activationRevision: 14
            )
        )
        await waitForLiveRevocation(manager: fixture.manager)

        let lifecycle = await fixture.audioCaptureService.lifecycleCounts()
        XCTAssertEqual(lifecycle.finish, 0)
        XCTAssertEqual(lifecycle.cancel, 1)
        XCTAssertEqual(
            request?.audioLifetime?.state,
            .revoked(.authorizationInvalidated)
        )

        await fixture.manager.stopForApplicationShutdown()
        await fixture.queue.shutdown()
    }

    func testCloudPrivacyBlockPreventsAudioCaptureFromStarting() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let workflow = WorkflowDefinition(
            name: "Blocked Cloud Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(recognizerID: "remote.speech", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "lock", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/unused-privacy-block.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let privacyRunGate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [
                        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
                    ]
                )
            },
            cloudConfirmationProvider: { _, _, _ in true }
        )
        let optionsProbe = RecordingOptionsProbe()
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: privacyRunGate,
            workflowProvider: { [workflow] },
            contextProvider: {
                ContextSnapshot(
                    focus: FocusSnapshot(
                        applicationName: "Vault",
                        bundleIdentifier: "com.example.vault",
                        processIdentifier: nil,
                        focusedRole: nil,
                        selectedText: "",
                        secureInput: false
                    ),
                    clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 1)
                )
            },
            recognitionOptionsProvider: { _, _ in
                await optionsProbe.resolve(
                    SpeechRecognitionRequestOptions(
                        hints: RecognitionHints(keyterms: ["must-not-be-resolved"])
                    )
                )
            }
        )

        await manager.beginPushToTalk()

        let captureRequest = await audioCaptureService.snapshot()
        let state = await manager.currentState()
        var events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .platform))
        for _ in 0..<100 where !events.contains(where: { $0.event == "recording.failure" }) {
            await Task.yield()
            events = await diagnostics.snapshot(matching: DiagnosticQuery(subsystem: .platform))
        }
        XCTAssertNil(captureRequest)
        XCTAssertEqual(state, RecordingSessionManager.State.idle)
        XCTAssertTrue(events.contains { $0.event == "recording.failure" })
        let optionsCallCount = await optionsProbe.callCount()
        XCTAssertEqual(optionsCallCount, 0)
    }

    func testPushToTalkReturnsToIdleBeforeBackgroundRunCompletes() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let requestProbe = RecordingRequestProbe()
        let actionProbe = RecordingActionProbe()
        let gate = BlockingRecognitionGate()
        let workflow = WorkflowDefinition(
            name: "Queued Push to Talk Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.blocking-recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.5,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-queued-recording.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [BlockingRecordingRecognizer(probe: requestProbe, gate: gate)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: actionProbe)]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] }
        )

        await manager.beginPushToTalk()
        await manager.endPushToTalk()

        let currentState = await manager.currentState()
        let actionValuesBeforeResume = await actionProbe.snapshot()

        XCTAssertEqual(currentState, RecordingSessionManager.State.idle)
        XCTAssertEqual(actionValuesBeforeResume, [])

        await gate.resume()
        var actionValuesAfterResume: [String] = []
        for _ in 0..<20 {
            actionValuesAfterResume = await actionProbe.snapshot()
            if actionValuesAfterResume == ["recorded"] {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(actionValuesAfterResume, ["recorded"])
    }

    func testPushToTalkRunsHotkeyWorkflowWithCapturedAudio() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let requestProbe = RecordingRequestProbe()
        let actionProbe = RecordingActionProbe()
        let vocabularyMigration = VocabularyLegacyMigrator.migrate([
            VocabularyRule(kind: .hotword, pattern: "Rill", replacement: ""),
            VocabularyRule(kind: .hotword, pattern: "multi word", replacement: ""),
        ])
        var workflow = WorkflowDefinition(
            name: "Push to Talk Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        workflow.plan.setup.vocabularyBindings = vocabularyMigration.bindings
        let configuredWorkflow = workflow
        let audio = try CapturedAudio(
            durationSeconds: 1.5,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-recording.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let expectedOptions = SpeechRecognitionRequestOptions(
            language: "zh-CN",
            hints: RecognitionHints(keyterms: ["Rill", "multi word"])
        )
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: requestProbe)]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: actionProbe)]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics,
            vocabularyCollectionProvider: { vocabularyMigration.collections }
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [configuredWorkflow] },
            recognitionOptionsProvider: { _, _ in expectedOptions }
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> [RillEvent] in
            var events: [RillEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event {
                    break
                }
            }
            return events
        }
        await Task.yield()

        await manager.beginPushToTalk()
        let captureRequest = await audioCaptureService.snapshot()

        await manager.endPushToTalk()
        let events = await collector.value
        let recognitionRequest = await requestProbe.snapshot()
        let actionValues = await actionProbe.snapshot()
        let currentState = await manager.currentState()

        XCTAssertEqual(captureRequest?.workflow.id, configuredWorkflow.id)
        XCTAssertEqual(captureRequest?.triggerEvent?.metadata["gesture"], HotkeyEventTap.PushToTalkGesture.fnHold.rawValue)
        XCTAssertEqual(captureRequest?.metadata["gesture"], HotkeyEventTap.PushToTalkGesture.fnHold.rawValue)
        XCTAssertEqual(captureRequest?.options, expectedOptions)
        XCTAssertEqual(captureRequest?.liveSubtitleNetworkUsage, .unknown)
        XCTAssertEqual(recognitionRequest?.capturedAudio, audio)
        XCTAssertEqual(recognitionRequest?.options, expectedOptions)
        XCTAssertEqual(recognitionRequest?.priority, .interactive)
        XCTAssertEqual(actionValues, ["recorded"])
        XCTAssertEqual(currentState, RecordingSessionManager.State.idle)
        XCTAssertTrue(events.contains { event in
            if case .runCompleted(let summary) = event {
                return summary.workflow.fallbackName == configuredWorkflow.name
            }
            return false
        })
    }

    func testPushToTalkIgnoresNonHotkeyWorkflow() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Manual Workflow",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-manual.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus
            ),
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] }
        )

        await manager.beginPushToTalk()
        let currentState = await manager.currentState()
        let captureRequest = await audioCaptureService.snapshot()

        XCTAssertEqual(currentState, RecordingSessionManager.State.idle)
        XCTAssertNil(captureRequest)
    }

    func testPushToTalkPublishesFailureWhenHotkeyWorkflowsConflict() async throws {
        let eventBus = EventBus()
        let workflowA = WorkflowDefinition(
            name: "Hotkey A",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let workflowB = WorkflowDefinition(
            name: "Hotkey B",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "orange")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-hotkey-conflict.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus
            ),
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflowA, workflowB] }
        )

        let stream = await eventBus.stream()
        let collector = Task { () -> RillEvent? in
            for await event in stream {
                if case .runFailed = event {
                    return event
                }
            }
            return nil
        }
        await Task.yield()

        await manager.beginPushToTalk()
        let currentState = await manager.currentState()
        let captureRequest = await audioCaptureService.snapshot()
        let failureEvent = await collector.value

        XCTAssertEqual(currentState, RecordingSessionManager.State.idle)
        XCTAssertNil(captureRequest)
        XCTAssertNotNil(failureEvent)
        if case .runFailed(_, _, let message)? = failureEvent {
            XCTAssertTrue(message.contains("Hotkey A"))
            XCTAssertTrue(message.contains("Hotkey B"))
        } else {
            XCTFail("Expected runFailed event")
        }
    }

    func testPushToTalkCanPreserveLegacyGestureMetadata() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let requestProbe = RecordingRequestProbe()
        let workflow = WorkflowDefinition(
            name: "Legacy Push to Talk Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-legacy-recording.caf")
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: requestProbe)]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: RecordingActionProbe())]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] }
        )

        let stream = await eventBus.stream()
        let completionCollector = Task {
            for await event in stream {
                if case .runCompleted = event {
                    return
                }
            }
        }

        await manager.beginPushToTalk(
            triggeredBy: HotkeyEventTap.PushToTalkGesture.controlOptionShiftSpace
        )
        await manager.endPushToTalk(
            triggeredBy: HotkeyEventTap.PushToTalkGesture.controlOptionShiftSpace
        )
        _ = await completionCollector.result

        let captureRequest = await audioCaptureService.snapshot()
        let recognitionRequest = await requestProbe.snapshot()
        XCTAssertEqual(recognitionRequest?.priority, .interactive)

        XCTAssertEqual(captureRequest?.triggerEvent?.metadata["gesture"], HotkeyEventTap.PushToTalkGesture.controlOptionShiftSpace.rawValue)
    }

    func testPushToTalkReleaseDuringPreparationFinishesAfterStartupCompletes() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let requestProbe = RecordingRequestProbe()
        let actionProbe = RecordingActionProbe()
        let workflow = WorkflowDefinition(
            name: "Preparing Push to Talk Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-preparing-recording.caf")
        )
        let audioCaptureService = ControlledAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: requestProbe)]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: actionProbe)]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] },
            pushToTalkGestureStateProvider: { _ in false }
        )
        let eventStream = await eventBus.stream()
        let completionCollector = Task {
            for await event in eventStream {
                if case .runCompleted = event { return }
            }
        }

        let beginTask = Task {
            await manager.beginPushToTalk()
        }

        while await audioCaptureService.snapshot() == nil {
            await Task.yield()
        }

        let stateDuringPreparation = await manager.currentState()
        await manager.endPushToTalk()
        await audioCaptureService.allowStartToFinish()
        await manager.waitForHotkeyLifecycleTasksToDrainForTesting()
        _ = await beginTask.result
        _ = await completionCollector.result

        let recognitionRequest = await requestProbe.snapshot()
        let actionValues = await actionProbe.snapshot()
        let finishCallCount = await audioCaptureService.finishCallCount
        let cancelCallCount = await audioCaptureService.cancelCallCount
        let currentState = await manager.currentState()

        if case .preparing = stateDuringPreparation {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected preparing state while startCapture was still blocked.")
        }
        XCTAssertEqual(cancelCallCount, 0)
        XCTAssertEqual(finishCallCount, 1)
        XCTAssertNotNil(recognitionRequest)
        XCTAssertEqual(actionValues, ["recorded"])
        XCTAssertEqual(currentState, RecordingSessionManager.State.idle)
    }

    func testHotkeyEventReleaseDuringPreparationFinishesAfterStartupCompletes() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let workflow = WorkflowDefinition(
            name: "Preparing Hotkey Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-hotkey-preparing-recording.caf")
        )
        let audioCaptureService = ControlledAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: RecordingRequestProbe())]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: RecordingActionProbe())]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] },
            pushToTalkGestureStateProvider: { _ in false }
        )

        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkPressed(.fnHold)
        )

        while await audioCaptureService.snapshot() == nil {
            await Task.yield()
        }

        let stateDuringPreparation = await manager.currentState()
        if case .preparing = stateDuringPreparation {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected preparing state while startCapture was still blocked by the hotkey event path.")
        }

        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkReleased(.fnHold)
        )
        await audioCaptureService.allowStartToFinish()
        await manager.waitForHotkeyLifecycleTasksToDrainForTesting()

        let cancelCallCount = await audioCaptureService.cancelCallCount
        let finishCallCount = await audioCaptureService.finishCallCount
        let currentState = await manager.currentState()

        XCTAssertEqual(cancelCallCount, 0)
        XCTAssertEqual(finishCallCount, 1)
        XCTAssertEqual(currentState, RecordingSessionManager.State.idle)
    }

    func testHotkeyEventRepeatedPressDuringPreparationCancelsDeferredRelease() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let workflow = WorkflowDefinition(
            name: "Deferred Release Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-deferred-release-recording.caf")
        )
        let audioCaptureService = ControlledAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: RecordingRequestProbe())]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: RecordingActionProbe())]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] }
        )

        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkPressed(.fnHold)
        )

        while await audioCaptureService.snapshot() == nil {
            await Task.yield()
        }

        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkReleased(.fnHold)
        )
        try? await Task.sleep(for: .milliseconds(40))
        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkPressed(.fnHold)
        )
        await audioCaptureService.allowStartToFinish()
        await manager.waitForHotkeyLifecycleTasksToDrainForTesting()

        let cancelCallCount = await audioCaptureService.cancelCallCount
        let currentState = await manager.currentState()

        XCTAssertEqual(cancelCallCount, 0)
        if case .recording = currentState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected recording state after the deferred release was cancelled by a repeated press.")
        }
    }

    func testTapInterruptionWhilePreparingStillDeliversFinalPhysicalRelease() async throws {
        let eventBus = EventBus()
        let workflow = WorkflowDefinition(
            name: "Interrupted Preparing Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(recognizerID: "recording.recognizer", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([1])
        )
        let audioCaptureService = ControlledAudioCaptureService(audio: audio)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let hotkeyTap = HotkeyEventTap()
        let gestureState = GestureStateBox(isActive: true)
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: hotkeyTap,
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] },
            pushToTalkGestureStateProvider: { _ in gestureState.currentValue }
        )

        let pressOutput = hotkeyTap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )
        guard case .swallow(let pressEvent?) = pressOutput else {
            return XCTFail("Expected the physical Fn press to start push-to-talk.")
        }
        await manager.processHotkeyEvent(pressEvent)
        while await audioCaptureService.snapshot() == nil { await Task.yield() }

        let interruptionRelease = hotkeyTap.testingInterruptPushToTalk(
            preservingActiveTrigger: true
        )
        await manager.processHotkeyEvent(try XCTUnwrap(interruptionRelease))
        try? await Task.sleep(for: .milliseconds(180))
        await audioCaptureService.allowStartToFinish()
        await manager.waitForHotkeyLifecycleTasksToDrainForTesting()
        guard case .recording = await manager.currentState() else {
            await manager.stopForApplicationShutdown()
            await queue.shutdown()
            return XCTFail("A held gesture should keep the prepared capture active.")
        }

        gestureState.setActive(false)
        let physicalReleaseOutput = hotkeyTap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: []
        )
        guard case .swallow(let physicalReleaseEvent?) = physicalReleaseOutput else {
            await manager.stopForApplicationShutdown()
            await queue.shutdown()
            return XCTFail("Expected the final physical Fn release after tap recovery.")
        }
        await manager.processHotkeyEvent(physicalReleaseEvent)

        let finishCallCount = await audioCaptureService.finishCallCount
        let finalState = await manager.currentState()
        XCTAssertEqual(finishCallCount, 1)
        XCTAssertEqual(finalState, .idle)
        await manager.stopForApplicationShutdown()
        await queue.shutdown()
    }

    func testDeferredReleaseIgnoresTransientFnUpWhenGestureStillActive() async throws {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let workflow = WorkflowDefinition(
            name: "Fn Jitter Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "recording.recognizer",
                outputActions: [OutputActionReference(id: "recording.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1.0,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: URL(fileURLWithPath: "/tmp/rill-fn-jitter-recording.caf")
        )
        let audioCaptureService = ControlledAudioCaptureService(audio: audio)
        let gestureState = GestureStateBox(isActive: true)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: [RecordingRecognizer(probe: RecordingRequestProbe())]),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RecordingAction(probe: RecordingActionProbe())]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: makeRecordingTestPrivacyGate(),
            workflowProvider: { [workflow] },
            pushToTalkGestureStateProvider: { _ in
                gestureState.currentValue
            }
        )

        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkPressed(.fnHold)
        )

        while await audioCaptureService.snapshot() == nil {
            await Task.yield()
        }

        await manager.processHotkeyEvent(
            HotkeyEventTap.Event.pushToTalkReleased(.fnHold)
        )
        await audioCaptureService.allowStartToFinish()
        await manager.waitForHotkeyLifecycleTasksToDrainForTesting()

        let cancelCallCount = await audioCaptureService.cancelCallCount
        let currentState = await manager.currentState()

        XCTAssertEqual(cancelCallCount, 0)
        if case .recording = currentState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected recording state when deferred release was ignored because Fn still appeared active.")
        }
    }

    private struct LiveRevocationFixture {
        let manager: RecordingSessionManager
        let audioCaptureService: MockAudioCaptureService
        let contexts: RecordingLiveContextStore
    }

    private func makeLiveRevocationFixture() throws -> LiveRevocationFixture {
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let workflow = WorkflowDefinition(
            name: "Revocable Cloud Text Workflow",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [
                    PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")
                ],
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
        )
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data()
        )
        let audioCaptureService = MockAudioCaptureService(audio: audio)
        let contexts = RecordingLiveContextStore(makeRecordingLiveContext())
        let manager = RecordingSessionManager(
            audioCaptureService: audioCaptureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: makeCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            ),
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: PrivacyRunGate(
                settingsProvider: { .defaults },
                cloudConfirmationProvider: { _, _, _ in true }
            ),
            workflowProvider: { [workflow] },
            privacyContextProvider: { await contexts.read() },
            authorizedContextProvider: { _ in await contexts.read() },
            focusIdentitySampleProvider: {
                await contexts.focusIdentitySample()
            },
            liveAuthorizationMonitorInterval: .milliseconds(5)
        )
        return LiveRevocationFixture(
            manager: manager,
            audioCaptureService: audioCaptureService,
            contexts: contexts
        )
    }

    private func waitForLiveRevocation(manager: RecordingSessionManager) async {
        for _ in 0..<100 {
            if await manager.currentState() == .idle { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The recording manager did not stop after privacy revocation.")
    }
}

private final class GestureStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }

    var currentValue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    func setActive(_ isActive: Bool) {
        lock.lock()
        self.isActive = isActive
        lock.unlock()
    }
}

private func makeRecordingLiveContext(
    bundleIdentifier: String = "com.apple.Notes"
) -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Recording Live Test",
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 45,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        ),
        clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
    )
}
