import AVFoundation
import Foundation
import XCTest
@testable import RillCore
@testable import RillPlatform

private final class FakeAVAudioRecorder: AVAudioRecorderControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL
    private let prepareSucceeds: Bool
    private let recordSucceeds: Bool
    private var recordedTime: TimeInterval
    private var recording = false
    private var stopCount = 0

    let settings: [String: Any]

    init(
        outputURL: URL,
        settings: [String: Any],
        initialCurrentTime: TimeInterval,
        prepareSucceeds: Bool,
        recordSucceeds: Bool
    ) {
        self.outputURL = outputURL
        self.settings = settings
        recordedTime = initialCurrentTime
        self.prepareSucceeds = prepareSucceeds
        self.recordSucceeds = recordSucceeds
    }

    var currentTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return recordedTime
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    func prepareToRecord() -> Bool {
        prepareSucceeds
    }

    func record() -> Bool {
        lock.lock()
        recording = recordSucceeds
        lock.unlock()
        if recordSucceeds {
            try? Data([0x52, 0x49, 0x46, 0x46]).write(to: outputURL)
        }
        return recordSucceeds
    }

    func stop() {
        lock.lock()
        recording = false
        stopCount += 1
        lock.unlock()
    }

    func setCurrentTime(_ currentTime: TimeInterval) {
        lock.lock()
        recordedTime = currentTime
        lock.unlock()
    }

    func snapshot() -> (isRecording: Bool, stopCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (recording, stopCount)
    }
}

private final class FakeAVAudioRecorderFactory: @unchecked Sendable {
    struct Plan: Sendable {
        let initialCurrentTime: TimeInterval
        let prepareSucceeds: Bool
        let recordSucceeds: Bool

        init(
            initialCurrentTime: TimeInterval,
            prepareSucceeds: Bool = true,
            recordSucceeds: Bool = true
        ) {
            self.initialCurrentTime = initialCurrentTime
            self.prepareSucceeds = prepareSucceeds
            self.recordSucceeds = recordSucceeds
        }
    }

    private let lock = NSLock()
    private var plans: [Plan]
    private var recorders: [FakeAVAudioRecorder] = []

    init(plans: [Plan]) {
        self.plans = plans
    }

    func make(
        outputURL: URL,
        settings: [String: Any]
    ) throws -> any AVAudioRecorderControlling {
        lock.lock()
        defer { lock.unlock() }
        precondition(!plans.isEmpty, "A recorder plan is required for every factory call.")
        let plan = plans.removeFirst()
        let recorder = FakeAVAudioRecorder(
            outputURL: outputURL,
            settings: settings,
            initialCurrentTime: plan.initialCurrentTime,
            prepareSucceeds: plan.prepareSucceeds,
            recordSucceeds: plan.recordSucceeds
        )
        recorders.append(recorder)
        return recorder
    }

    func recorder(at index: Int) -> FakeAVAudioRecorder? {
        lock.lock()
        defer { lock.unlock() }
        guard recorders.indices.contains(index) else { return nil }
        return recorders[index]
    }

    var recorderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorders.count
    }
}

private actor BlockingAVAudioRemoval {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func remove(_ url: URL) async throws {
        hasStarted = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

private actor ManualAVAudioReadinessSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func sleep(_: Duration) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancel(waiterID)
            }
        }
    }

    func waiterCount() -> Int {
        waiters.count
    }

    func resumeAll() {
        let waiters = self.waiters.values
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }
}

private actor AVAudioStartCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

final class AVAudioCaptureServiceReadinessTests: XCTestCase {
    func testStartCaptureWaitsForNonzeroRecordedTime() async throws {
        let factory = FakeAVAudioRecorderFactory(
            plans: [.init(initialCurrentTime: 0)]
        )
        let pollSleeper = ManualAVAudioReadinessSleeper()
        let completionProbe = AVAudioStartCompletionProbe()
        let service = AVAudioCaptureService(
            startupTimeout: .seconds(30),
            readinessPollSleep: { duration in
                try await pollSleeper.sleep(duration)
            },
            recorderFactory: factory.make
        )
        let request = makeRequest()

        let startTask = Task {
            try await service.startCapture(request)
            await completionProbe.markCompleted()
        }

        try await waitUntil {
            guard factory.recorder(at: 0) != nil else { return false }
            return await pollSleeper.waiterCount() == 1
        }
        let completedBeforeFirstFrame = await completionProbe.isCompleted()
        XCTAssertFalse(completedBeforeFirstFrame)

        let recorder = try XCTUnwrap(factory.recorder(at: 0))
        recorder.setCurrentTime(0.01)
        await pollSleeper.resumeAll()

        try await startTask.value
        let completedAfterFirstFrame = await completionProbe.isCompleted()
        XCTAssertTrue(completedAfterFirstFrame)
        XCTAssertTrue(recorder.snapshot().isRecording)
        await service.cancelCapture()
    }

    func testConcurrentStartCannotOverwriteCaptureWhileStaleArtifactCleanupSuspends() async throws {
        let removal = BlockingAVAudioRemoval()
        let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
            removal: { url in
                try await removal.remove(url)
            }
        )
        let factory = FakeAVAudioRecorderFactory(
            plans: [.init(initialCurrentTime: 0.02)]
        )
        let service = AVAudioCaptureService(
            cleanupOwner: cleanupOwner,
            recorderFactory: factory.make
        )
        let staleRequest = makeRequest()
        let staleURL = temporaryRecordingURL(for: staleRequest.runID)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: staleURL)
        defer { try? FileManager.default.removeItem(at: staleURL) }

        let staleStart = Task {
            try await service.startCapture(staleRequest)
        }
        await removal.waitUntilStarted()

        let replacementRequest = makeRequest()
        try await service.startCapture(replacementRequest)
        let replacementRecorder = try XCTUnwrap(factory.recorder(at: 0))
        XCTAssertTrue(replacementRecorder.snapshot().isRecording)

        await removal.release()
        do {
            try await staleStart.value
            XCTFail("The suspended older start must not overwrite the replacement capture.")
        } catch let error as AVAudioCaptureService.CaptureError {
            XCTAssertEqual(error, .alreadyCapturing)
        } catch {
            XCTFail("Unexpected stale-start error: \(error)")
        }

        XCTAssertEqual(factory.recorderCount, 1)
        XCTAssertTrue(replacementRecorder.snapshot().isRecording)
        let capturedAudio = try await service.finishCapture()
        XCTAssertEqual(capturedAudio.metadata["runID"], replacementRequest.runID.uuidString)
        _ = try capturedAudio.removeManagedTemporaryFile()
    }

    func testStartupTimeoutStopsRecorderAndRemovesOwnedFile() async throws {
        let factory = FakeAVAudioRecorderFactory(
            plans: [.init(initialCurrentTime: 0)]
        )
        let service = AVAudioCaptureService(
            startupTimeout: .milliseconds(1),
            timeoutSleep: { _ in },
            readinessPollSleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            },
            recorderFactory: factory.make
        )
        let request = makeRequest()
        let expectedURL = temporaryRecordingURL(for: request.runID)
        defer { try? FileManager.default.removeItem(at: expectedURL) }

        do {
            try await service.startCapture(request)
            XCTFail("Capture must not become ready while recorded time remains zero.")
        } catch let error as AVAudioCaptureService.CaptureError {
            XCTAssertEqual(error, .startTimedOut)
        } catch {
            XCTFail("Unexpected startup timeout error: \(error)")
        }

        let recorder = try XCTUnwrap(factory.recorder(at: 0))
        XCTAssertFalse(recorder.snapshot().isRecording)
        XCTAssertEqual(recorder.snapshot().stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    func testCancelledPendingStartCannotAffectReplacementCapture() async throws {
        let factory = FakeAVAudioRecorderFactory(
            plans: [
                .init(initialCurrentTime: 0),
                .init(initialCurrentTime: 0.02),
            ]
        )
        let pollSleeper = ManualAVAudioReadinessSleeper()
        let service = AVAudioCaptureService(
            startupTimeout: .seconds(30),
            readinessPollSleep: { duration in
                try await pollSleeper.sleep(duration)
            },
            recorderFactory: factory.make
        )
        let firstRequest = makeRequest()
        let firstURL = temporaryRecordingURL(for: firstRequest.runID)
        defer { try? FileManager.default.removeItem(at: firstURL) }

        let firstStartTask = Task {
            try await service.startCapture(firstRequest)
        }
        try await waitUntil {
            guard factory.recorder(at: 0) != nil else { return false }
            return await pollSleeper.waiterCount() == 1
        }

        firstStartTask.cancel()
        do {
            try await firstStartTask.value
            XCTFail("A cancelled pending start must not report readiness.")
        } catch is CancellationError {
            // Expected.
        }

        let firstRecorder = try XCTUnwrap(factory.recorder(at: 0))
        XCTAssertEqual(firstRecorder.snapshot().stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))

        let replacementRequest = makeRequest()
        try await service.startCapture(replacementRequest)
        let replacementRecorder = try XCTUnwrap(factory.recorder(at: 1))
        XCTAssertTrue(replacementRecorder.snapshot().isRecording)
        XCTAssertEqual(replacementRecorder.snapshot().stopCount, 0)

        let capturedAudio = try await service.finishCapture()
        XCTAssertEqual(capturedAudio.metadata["runID"], replacementRequest.runID.uuidString)
        XCTAssertEqual(capturedAudio.durationSeconds, 0.02, accuracy: 0.000_1)
        _ = try capturedAudio.removeManagedTemporaryFile()
    }

    func testShutdownCancelsAndDrainsPendingReadiness() async throws {
        let factory = FakeAVAudioRecorderFactory(
            plans: [.init(initialCurrentTime: 0)]
        )
        let pollSleeper = ManualAVAudioReadinessSleeper()
        let service = AVAudioCaptureService(
            startupTimeout: .seconds(30),
            readinessPollSleep: { duration in
                try await pollSleeper.sleep(duration)
            },
            recorderFactory: factory.make
        )
        let request = makeRequest()
        let outputURL = temporaryRecordingURL(for: request.runID)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let startTask = Task {
            try await service.startCapture(request)
        }
        try await waitUntil {
            guard factory.recorder(at: 0) != nil else { return false }
            return await pollSleeper.waiterCount() == 1
        }

        await service.shutdown()
        do {
            try await startTask.value
            XCTFail("Shutdown must cancel a capture that has not become ready.")
        } catch is CancellationError {
            // Expected.
        }

        let recorder = try XCTUnwrap(factory.recorder(at: 0))
        XCTAssertEqual(recorder.snapshot().stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        do {
            try await service.startCapture(makeRequest())
            XCTFail("Shutdown must permanently reject later starts.")
        } catch let error as AVAudioCaptureService.CaptureError {
            XCTAssertEqual(error, .shuttingDown)
        } catch {
            XCTFail("Unexpected post-shutdown error: \(error)")
        }
    }

    private func makeRequest(runID: UUID = UUID()) -> AudioCaptureRequest {
        AudioCaptureRequest(
            runID: runID,
            workflow: WorkflowDefinition(
                name: "AVAudio readiness",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "sherpa-onnx.local",
                    outputActions: []
                ),
                ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
            )
        )
    }

    private func temporaryRecordingURL(for runID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-\(runID.uuidString)")
            .appendingPathExtension("wav")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out while waiting for the asynchronous test precondition.")
    }
}
