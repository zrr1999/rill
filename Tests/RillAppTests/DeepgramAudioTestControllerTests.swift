import Foundation
import XCTest
@testable import RillApp
@testable import RillCore
@testable import RillRuntime

private enum DeepgramAudioTestFailure: Error {
    case invalidConfiguration
}

private actor DeepgramAudioTestProbe {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor DeepgramAudioTestCompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func completed() -> Bool {
        isComplete
    }
}

private actor DeepgramTestManagedAudioRemovalProbe {
    private enum ProbeError: Error { case transient }
    private var attempts = 0

    func remove(_ fileURL: URL) throws {
        attempts += 1
        if attempts == 1 { throw ProbeError.transient }
        try FileManager.default.removeItem(at: fileURL)
    }

    func count() -> Int { attempts }
}

private actor DeepgramAudioTestGate {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor DeepgramRecognitionCancellationProbe {
    private var didStart = false
    private var didObserveCancellation = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func recognize() async throws -> RecognitionResult {
        didStart = true
        let pending = startContinuations
        startContinuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }

        do {
            try await Task.sleep(for: .seconds(30))
            return RecognitionResult(rawText: "late", bestText: "late")
        } catch is CancellationError {
            didObserveCancellation = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func observedCancellation() -> Bool {
        didObserveCancellation
    }
}

private actor DeepgramPrivacyEnvironment {
    private var context: ContextSnapshot
    private var settings: PrivacyPolicySettings
    private var confirmationCount = 0

    init(context: ContextSnapshot, settings: PrivacyPolicySettings) {
        self.context = context
        self.settings = settings
    }

    func currentContext() -> ContextSnapshot {
        context
    }

    func currentSettings() -> PrivacyPolicySettings {
        settings
    }

    func updateContext(_ context: ContextSnapshot) {
        self.context = context
    }

    func updateSettings(_ settings: PrivacyPolicySettings) {
        self.settings = settings
    }

    func confirm() -> Bool {
        confirmationCount += 1
        return true
    }

    func confirmations() -> Int {
        confirmationCount
    }
}

private actor DeepgramAudioTestCaptureService: AudioCaptureService {
    private let probe: DeepgramAudioTestProbe
    private let capturedAudio: CapturedAudio
    private var startRequests: [AudioCaptureRequest] = []
    private var finishCount = 0
    private var cancelCount = 0
    private var cancelWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        probe: DeepgramAudioTestProbe,
        capturedAudio: CapturedAudio? = nil
    ) throws {
        self.probe = probe
        if let capturedAudio {
            self.capturedAudio = capturedAudio
        } else {
            self.capturedAudio = try CapturedAudio(
                durationSeconds: 0.2,
                format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
                inlineData: Data([0, 1, 2, 3])
            )
        }
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        startRequests.append(request)
        await probe.record("audio-capture")
    }

    func finishCapture() async throws -> CapturedAudio {
        finishCount += 1
        await probe.record("audio-finish")
        return capturedAudio
    }

    func cancelCapture() async {
        cancelCount += 1
        let ready = cancelWaiters.filter { cancelCount >= $0.count }
        cancelWaiters.removeAll { cancelCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitUntilCancelled(count: Int = 1) async {
        guard cancelCount < count else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append((count, continuation))
        }
    }

    func snapshot() -> (
        startRequests: [AudioCaptureRequest],
        finishCount: Int,
        cancelCount: Int
    ) {
        (startRequests, finishCount, cancelCount)
    }
}

final class DeepgramAudioTestControllerTests: XCTestCase {
    func testBlockedDiagnosticsDoNotDelayReadyOrCompletionAndShutdownDrainsFIFO() async throws {
        let repository = BlockingControllerDiagnosticRepository(
            blockedEvent: "provider.deepgram.test.recording.started"
        )
        let diagnostics = DiagnosticsRecorder(repository: repository)
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            diagnostics: diagnostics,
            configurationPreflight: { _ in },
            privacyPreflight: { _ in },
            privacyAuthorization: { _ in },
            recognize: { _, _ in
                RecognitionResult(rawText: "ready", bestText: "ready")
            }
        )
        let settings = DeepgramSettings(apiKey: "test-key")
        let startCompletion = DeepgramAudioTestCompletionProbe()
        let startTask = Task {
            try await controller.startTest(settings: settings)
            await startCompletion.markComplete()
        }

        await repository.waitUntilBlockedSaveEntered()
        for _ in 0..<100 {
            if await startCompletion.completed() { break }
            await Task.yield()
        }
        let didStartReturnWhileDiagnosticWasBlocked = await startCompletion.completed()
        let captureWhileDiagnosticWasBlocked = await capture.snapshot()
        XCTAssertTrue(
            didStartReturnWhileDiagnosticWasBlocked,
            "The settings-page recording state must not wait for durable diagnostics."
        )
        XCTAssertEqual(captureWhileDiagnosticWasBlocked.startRequests.count, 1)

        let finishCompletion = DeepgramAudioTestCompletionProbe()
        let finishTask = Task {
            let result = try await controller.finishTest(settings: settings)
            await finishCompletion.markComplete()
            return result
        }
        for _ in 0..<100 {
            if await finishCompletion.completed() { break }
            await Task.yield()
        }
        let didFinishReturnWhileDiagnosticWasBlocked = await finishCompletion.completed()
        XCTAssertTrue(
            didFinishReturnWhileDiagnosticWasBlocked,
            "A later diagnostic must queue behind the blocked start record without delaying completion."
        )

        let shutdownCompletion = DeepgramAudioTestCompletionProbe()
        let shutdownTask = Task {
            await controller.shutdown()
            await shutdownCompletion.markComplete()
        }
        await capture.waitUntilCancelled(count: 1)
        for _ in 0..<100 {
            await Task.yield()
        }
        let didShutdownBeforeDiagnosticWasReleased = await shutdownCompletion.completed()
        XCTAssertFalse(
            didShutdownBeforeDiagnosticWasReleased,
            "Shutdown must drain all accepted controller diagnostics in FIFO order."
        )

        await repository.releaseBlockedSave()
        try await startTask.value
        let result = try await finishTask.value
        await shutdownTask.value

        XCTAssertEqual(result.bestText, "ready")
        let savedEvents = await repository.savedEventNames()
        XCTAssertEqual(
            savedEvents,
            [
                "provider.deepgram.test.recording.started",
                "provider.deepgram.test.completed",
            ]
        )
    }

    func testCompletedTestRetriesManagedTemporaryAudioRemoval() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-deepgram-test-cleanup-\(UUID().uuidString).wav")
        try Data([0x01, 0x02]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 0.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(
            probe: probe,
            capturedAudio: capturedAudio
        )
        let removalProbe = DeepgramTestManagedAudioRemovalProbe()
        let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
            removal: { try await removalProbe.remove($0) },
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(1),
            sleep: { _ in }
        )
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in },
            privacyPreflight: { _ in },
            privacyAuthorization: { _ in },
            recognize: { _, _ in RecognitionResult(rawText: "ok", bestText: "ok") },
            cleanupOwner: cleanupOwner
        )
        let settings = DeepgramSettings(apiKey: "test-key")

        try await controller.startTest(settings: settings)
        _ = try await controller.finishTest(settings: settings)

        let attempts = await removalProbe.count()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testConfigurationPreflightFailurePrecedesPrivacyAndAudioCapture() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in
                await probe.record("configuration")
                throw DeepgramAudioTestFailure.invalidConfiguration
            },
            privacyPreflight: { _ in
                await probe.record("privacy-preview")
            },
            privacyAuthorization: { _ in
                await probe.record("privacy-authorization")
            },
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "", bestText: "")
            }
        )

        do {
            try await controller.startTest(settings: DeepgramSettings(apiKey: ""))
            XCTFail("Expected the existing Deepgram configuration preflight to fail")
        } catch {
            // The validator exposes a typed, fixed configuration failure.
        }

        let calls = await capture.snapshot()
        let events = await probe.snapshot()
        XCTAssertEqual(events, ["configuration"])
        XCTAssertTrue(calls.startRequests.isEmpty)
        XCTAssertEqual(calls.finishCount, 0)
        XCTAssertEqual(calls.cancelCount, 0)
    }

    func testPrivacyRejectionPrecedesAudioCaptureAndRecognition() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in
                await probe.record("configuration")
            },
            privacyPreflight: { _ in
                await probe.record("privacy-preview")
                throw PrivacyRunGate.GateError.cloudProcessingBlocked
            },
            privacyAuthorization: { _ in
                await probe.record("privacy-authorization")
            },
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "", bestText: "")
            }
        )

        do {
            try await controller.startTest(settings: DeepgramSettings(apiKey: "test-key"))
            XCTFail("Expected privacy policy to reject the diagnostic recording")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let calls = await capture.snapshot()
        let events = await probe.snapshot()
        XCTAssertEqual(events, ["configuration", "privacy-preview"])
        XCTAssertTrue(calls.startRequests.isEmpty)
        XCTAssertEqual(calls.finishCount, 0)
        XCTAssertEqual(calls.cancelCount, 0)

        do {
            _ = try await controller.finishTest(settings: DeepgramSettings(apiKey: "test-key"))
            XCTFail("A rejected test must not become recordable")
        } catch let error as DeepgramAudioTestController.TestError {
            XCTAssertEqual(error, .notRecording)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let finalEvents = await probe.snapshot()
        XCTAssertEqual(finalEvents, ["configuration", "privacy-preview"])
    }

    func testAuthorizedTestUsesFixedMinimalWorkflowAndExpectedOrdering() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let expected = RecognitionResult(rawText: "hello", bestText: "hello")
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in
                await probe.record("configuration")
            },
            privacyPreflight: { workflow in
                await probe.record("privacy-preview")
                XCTAssertEqual(workflow, DeepgramAudioTestController.diagnosticWorkflow)
                XCTAssertTrue(workflow.metadata.isEmpty)
            },
            privacyAuthorization: { workflow in
                await probe.record("privacy-authorization")
                XCTAssertEqual(workflow, DeepgramAudioTestController.diagnosticWorkflow)
                XCTAssertTrue(workflow.metadata.isEmpty)
            },
            recognize: { _, request in
                await probe.record("recognize")
                XCTAssertEqual(request.workflow, DeepgramAudioTestController.diagnosticWorkflow)
                XCTAssertEqual(request.contextSnapshot, .empty)
                return expected
            }
        )
        let settings = DeepgramSettings(
            apiKey: "test-key",
            baseURL: "https://api.deepgram.com",
            model: "nova-3",
            language: "en-US"
        )

        try await controller.startTest(settings: settings)
        var events = await probe.snapshot()
        XCTAssertEqual(events, ["configuration", "privacy-preview", "audio-capture"])
        let started = await capture.snapshot()
        let request = try XCTUnwrap(started.startRequests.first)
        XCTAssertEqual(started.startRequests.count, 1)
        XCTAssertEqual(request.workflow, DeepgramAudioTestController.diagnosticWorkflow)
        XCTAssertTrue(request.workflow.metadata.isEmpty)
        XCTAssertEqual(request.workflow.pipeline.recognizerID, "deepgram.prerecorded")
        XCTAssertTrue(request.workflow.pipeline.outputActions.isEmpty)

        let result = try await controller.finishTest(settings: settings)
        events = await probe.snapshot()
        XCTAssertEqual(
            events,
            [
                "configuration",
                "privacy-preview",
                "audio-capture",
                "audio-finish",
                "privacy-authorization",
                "recognize",
            ]
        )
        XCTAssertEqual(result, expected)
    }

    func testConfigurationCannotChangeBetweenAuthorizationAndRecognition() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in
                await probe.record("configuration")
            },
            privacyPreflight: { _ in
                await probe.record("privacy-preview")
            },
            privacyAuthorization: { _ in
                await probe.record("privacy-authorization")
            },
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "", bestText: "")
            }
        )
        let authorizedSettings = DeepgramSettings(apiKey: "first-key")
        try await controller.startTest(settings: authorizedSettings)

        do {
            _ = try await controller.finishTest(
                settings: DeepgramSettings(apiKey: "second-key")
            )
            XCTFail("Expected changed settings to invalidate the diagnostic authorization")
        } catch let error as DeepgramAudioTestController.TestError {
            XCTAssertEqual(error, .configurationChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let calls = await capture.snapshot()
        let events = await probe.snapshot()
        XCTAssertEqual(events, ["configuration", "privacy-preview", "audio-capture"])
        XCTAssertEqual(calls.startRequests.count, 1)
        XCTAssertEqual(calls.finishCount, 0)
        XCTAssertEqual(calls.cancelCount, 1)
    }

    func testSensitiveFocusChangeDuringRecordingBlocksRecognition() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let environment = DeepgramPrivacyEnvironment(
            context: makeDeepgramPrivacyContext(),
            settings: PrivacyPolicySettings(
                sensitiveAppRules: [
                    SensitiveAppRule(
                        bundleIdentifier: "com.example.vault",
                        applicationName: "Vault"
                    )
                ],
                cloudConfirmationRequired: false
            )
        )
        let gate = makeDeepgramPrivacyGate(environment: environment)
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in },
            privacyPreflight: AppBootstrap.makeDeepgramDiagnosticPrivacyPreflight(
                privacyRunGate: gate,
                privacyContextProvider: { await environment.currentContext() }
            ),
            privacyAuthorization: AppBootstrap.makeDeepgramDiagnosticPrivacyAuthorization(
                privacyRunGate: gate,
                privacyContextProvider: { await environment.currentContext() }
            ),
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "", bestText: "")
            }
        )
        let settings = DeepgramSettings(apiKey: "test-key")

        try await controller.startTest(settings: settings)
        await environment.updateContext(
            makeDeepgramPrivacyContext(
                applicationName: "Vault",
                bundleIdentifier: "com.example.vault"
            )
        )

        do {
            _ = try await controller.finishTest(settings: settings)
            XCTFail("Expected the current sensitive application to block cloud recognition")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await probe.snapshot()
        let calls = await capture.snapshot()
        let confirmationCount = await environment.confirmations()
        XCTAssertEqual(events, ["audio-capture", "audio-finish"])
        XCTAssertEqual(calls.finishCount, 1)
        XCTAssertEqual(confirmationCount, 0)
    }

    func testPrivacySettingsTighteningDuringRecordingBlocksAndCleansCapturedAudio() async throws {
        let probe = DeepgramAudioTestProbe()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-deepgram-privacy-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 0.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let capture = try DeepgramAudioTestCaptureService(
            probe: probe,
            capturedAudio: capturedAudio
        )
        let environment = DeepgramPrivacyEnvironment(
            context: makeDeepgramPrivacyContext(),
            settings: PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: true
            )
        )
        let gate = makeDeepgramPrivacyGate(environment: environment)
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in },
            privacyPreflight: AppBootstrap.makeDeepgramDiagnosticPrivacyPreflight(
                privacyRunGate: gate,
                privacyContextProvider: { await environment.currentContext() }
            ),
            privacyAuthorization: AppBootstrap.makeDeepgramDiagnosticPrivacyAuthorization(
                privacyRunGate: gate,
                privacyContextProvider: { await environment.currentContext() }
            ),
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "", bestText: "")
            }
        )
        let settings = DeepgramSettings(apiKey: "test-key")

        try await controller.startTest(settings: settings)
        var confirmationCount = await environment.confirmations()
        XCTAssertEqual(confirmationCount, 0)
        await environment.updateSettings(
            PrivacyPolicySettings(
                sensitiveAppRules: [
                    SensitiveAppRule(
                        bundleIdentifier: "com.apple.Notes",
                        applicationName: "Notes"
                    )
                ],
                cloudConfirmationRequired: true
            )
        )

        do {
            _ = try await controller.finishTest(settings: settings)
            XCTFail("Expected stricter settings to block cloud recognition")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await probe.snapshot()
        confirmationCount = await environment.confirmations()
        XCTAssertEqual(events, ["audio-capture", "audio-finish"])
        XCTAssertEqual(confirmationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFinishingBlocksReentrantStartAndCancelPreventsRecognition() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let authorizationGate = DeepgramAudioTestGate()
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in },
            privacyPreflight: { _ in },
            privacyAuthorization: { _ in
                await probe.record("privacy-authorization")
                await authorizationGate.hold()
            },
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "", bestText: "")
            }
        )
        let settings = DeepgramSettings(apiKey: "test-key")
        try await controller.startTest(settings: settings)

        let finishTask = Task {
            try await controller.finishTest(settings: settings)
        }
        await authorizationGate.waitUntilStarted()

        do {
            try await controller.startTest(settings: settings)
            XCTFail("A new recording must not start while the previous run is finishing")
        } catch let error as DeepgramAudioTestController.TestError {
            XCTAssertEqual(error, .alreadyRecording)
        }
        do {
            _ = try await controller.finishTest(settings: settings)
            XCTFail("A second finish must not join the in-flight finish")
        } catch let error as DeepgramAudioTestController.TestError {
            XCTAssertEqual(error, .notRecording)
        }

        let cancelTask = Task {
            await controller.cancelTest()
        }
        await capture.waitUntilCancelled()
        do {
            try await controller.startTest(settings: settings)
            XCTFail("Cancellation must keep the run closed until finish settles")
        } catch let error as DeepgramAudioTestController.TestError {
            XCTAssertEqual(error, .alreadyRecording)
        }
        await authorizationGate.release()
        await cancelTask.value

        try await controller.startTest(settings: settings)
        do {
            _ = try await finishTask.value
            XCTFail("A stale cancelled finish must not produce a recognition result")
        } catch is CancellationError {
            // Expected: cancellation won the final authorization race.
        }

        let events = await probe.snapshot()
        XCTAssertEqual(
            events,
            ["audio-capture", "audio-finish", "privacy-authorization", "audio-capture"]
        )
        await controller.cancelTest()
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.startRequests.count, 2)
        XCTAssertEqual(calls.cancelCount, 2)
    }

    func testShutdownWaitsForSuspendedAuthorizationAndDeletesTransferredAudio() async throws {
        let probe = DeepgramAudioTestProbe()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-deepgram-shutdown-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 0.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let capture = try DeepgramAudioTestCaptureService(
            probe: probe,
            capturedAudio: capturedAudio
        )
        let authorizationGate = DeepgramAudioTestGate()
        let completion = DeepgramAudioTestCompletionProbe()
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in },
            privacyPreflight: { _ in },
            privacyAuthorization: { _ in
                await authorizationGate.hold()
            },
            recognize: { _, _ in
                await probe.record("recognize")
                return RecognitionResult(rawText: "late", bestText: "late")
            }
        )
        let settings = DeepgramSettings(apiKey: "test-key")
        try await controller.startTest(settings: settings)

        let finishTask = Task {
            try await controller.finishTest(settings: settings)
        }
        await authorizationGate.waitUntilStarted()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let shutdownTask = Task {
            await controller.shutdown()
            await completion.markComplete()
        }
        await capture.waitUntilCancelled()

        let completedBeforeAuthorizationExited = await completion.completed()
        XCTAssertFalse(completedBeforeAuthorizationExited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await authorizationGate.release()
        await shutdownTask.value

        let didComplete = await completion.completed()
        XCTAssertTrue(didComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        do {
            _ = try await finishTask.value
            XCTFail("Shutdown must prevent the suspended authorization from publishing a result")
        } catch is CancellationError {
            // Expected: shutdown owns and cancels the full finishing operation.
        }

        let events = await probe.snapshot()
        XCTAssertEqual(events, ["audio-capture", "audio-finish"])
    }

    func testShutdownSealsControllerBeforeSuspendedPreflightResumes() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let preflightGate = DeepgramAudioTestGate()
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in
                await preflightGate.hold()
            },
            privacyPreflight: { _ in },
            privacyAuthorization: { _ in },
            recognize: { _, _ in RecognitionResult(rawText: "ok", bestText: "ok") }
        )
        let settings = DeepgramSettings(apiKey: "test-key")
        let startTask = Task {
            try await controller.startTest(settings: settings)
        }
        await preflightGate.waitUntilStarted()

        await controller.shutdown()

        do {
            try await controller.startTest(settings: settings)
            XCTFail("Shutdown must permanently reject later Deepgram test starts.")
        } catch let error as DeepgramAudioTestController.TestError {
            XCTAssertEqual(error, .shuttingDown)
        } catch {
            XCTFail("Unexpected post-shutdown error: \(error)")
        }

        await preflightGate.release()
        do {
            try await startTask.value
            XCTFail("A preflight released after shutdown must not start capture.")
        } catch is CancellationError {
            // Expected: shutdown invalidated the preparing test before release.
        }

        let calls = await capture.snapshot()
        XCTAssertTrue(calls.startRequests.isEmpty)
    }

    func testCancelAwaitsBlockingRecognitionTaskAndCannotPublishItsResult() async throws {
        let probe = DeepgramAudioTestProbe()
        let capture = try DeepgramAudioTestCaptureService(probe: probe)
        let recognitionProbe = DeepgramRecognitionCancellationProbe()
        let controller = DeepgramAudioTestController(
            audioCaptureService: capture,
            configurationPreflight: { _ in },
            privacyPreflight: { _ in },
            privacyAuthorization: { _ in },
            recognize: { _, _ in
                try await recognitionProbe.recognize()
            }
        )
        let settings = DeepgramSettings(apiKey: "test-key")
        try await controller.startTest(settings: settings)

        let finishTask = Task {
            try await controller.finishTest(settings: settings)
        }
        await recognitionProbe.waitUntilStarted()

        await controller.cancelTest()

        let observedCancellation = await recognitionProbe.observedCancellation()
        XCTAssertTrue(observedCancellation)
        do {
            _ = try await finishTask.value
            XCTFail("A cancelled recognition task must not publish its late result")
        } catch is CancellationError {
            // Expected: controller cancellation propagated into recognition.
        }

        try await controller.startTest(settings: settings)
        await controller.cancelTest()
    }
}

private func makeDeepgramPrivacyGate(
    environment: DeepgramPrivacyEnvironment
) -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: { await environment.currentSettings() },
        cloudConfirmationProvider: { _, _, _ in await environment.confirm() }
    )
}

private func makeDeepgramPrivacyContext(
    applicationName: String = "Notes",
    bundleIdentifier: String = "com.apple.Notes",
    secureInput: Bool = false,
    changeCount: Int = 1
) -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 42,
            focusedRole: nil,
            selectedText: "",
            secureInput: secureInput
        ),
        clipboard: ClipboardSnapshot(plainText: "", changeCount: changeCount)
    )
}
