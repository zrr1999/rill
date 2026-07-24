import AVFoundation
import Foundation
import RillCore

protocol AVAudioRecorderControlling: AnyObject {
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    var settings: [String: Any] { get }

    @discardableResult
    func prepareToRecord() -> Bool

    @discardableResult
    func record() -> Bool

    func stop()
}

extension AVAudioRecorder: AVAudioRecorderControlling {}

public actor AVAudioCaptureService: AudioCaptureService {
    public enum CaptureError: Error, LocalizedError, Equatable {
        case alreadyCapturing
        case notCapturing
        case recorderInitializationFailed
        case startFailed
        case startTimedOut
        case invalidEndpointControl
        case shuttingDown

        public var errorDescription: String? {
            switch self {
            case .alreadyCapturing:
                return "An audio capture is already in progress."
            case .notCapturing:
                return "No audio capture is currently active."
            case .recorderInitializationFailed:
                return "The audio recorder could not be initialized."
            case .startFailed:
                return "The audio recorder could not start recording."
            case .startTimedOut:
                return "The audio recorder did not begin receiving audio in time."
            case .invalidEndpointControl:
                return "The audio endpoint control does not match the capture run."
            case .shuttingDown:
                return "Audio capture is shutting down."
            }
        }
    }

    private enum Lifecycle: Sendable, Equatable {
        case accepting
        case shuttingDown
        case terminated
    }

    typealias RecorderFactory = (URL, [String: Any]) throws -> any AVAudioRecorderControlling
    typealias ReadinessSleep = @Sendable (Duration) async throws -> Void

    private static let defaultStartupTimeout: Duration = .seconds(3)
    private static let defaultReadinessPollInterval: Duration = .milliseconds(5)

    private var recorder: (any AVAudioRecorderControlling)?
    private var activeRequest: AudioCaptureRequest?
    private var outputURL: URL?
    private var activeCaptureGeneration: UInt64?
    private var readyCaptureGeneration: UInt64?
    private var activeReadinessGate: AVAudioCaptureReadinessGate?
    private var activeReadinessTask: Task<Void, Never>?
    private var nextCaptureGeneration: UInt64 = 0
    private let cleanupOwner: ManagedTemporaryAudioCleanupOwner
    private let recorderFactory: RecorderFactory
    private let startupTimeout: Duration
    private let readinessPollInterval: Duration
    private let timeoutSleep: ReadinessSleep
    private let readinessPollSleep: ReadinessSleep
    private var lifecycle: Lifecycle = .accepting
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner()
    ) {
        self.cleanupOwner = cleanupOwner
        recorderFactory = { outputURL, settings in
            try AVAudioRecorder(url: outputURL, settings: settings)
        }
        startupTimeout = Self.defaultStartupTimeout
        readinessPollInterval = Self.defaultReadinessPollInterval
        timeoutSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
        readinessPollSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    }

    init(
        cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner(),
        startupTimeout: Duration = AVAudioCaptureService.defaultStartupTimeout,
        readinessPollInterval: Duration = AVAudioCaptureService.defaultReadinessPollInterval,
        timeoutSleep: @escaping ReadinessSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        readinessPollSleep: @escaping ReadinessSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        recorderFactory: @escaping RecorderFactory
    ) {
        self.cleanupOwner = cleanupOwner
        self.recorderFactory = recorderFactory
        self.startupTimeout = startupTimeout
        self.readinessPollInterval = readinessPollInterval
        self.timeoutSleep = timeoutSleep
        self.readinessPollSleep = readinessPollSleep
    }

    public func startCapture(_ request: AudioCaptureRequest) async throws {
        var didStart = false
        defer {
            if !didStart {
                request.endpointControl?.finish()
            }
        }
        try Task.checkCancellation()
        try requireAcceptingStarts()
        if let endpointControl = request.endpointControl,
           endpointControl.runID != request.runID {
            throw CaptureError.invalidEndpointControl
        }
        guard recorder == nil else {
            throw CaptureError.alreadyCapturing
        }

        let format = request.preferredFormat ?? AudioFormat(
            sampleRateHz: 16_000,
            channelCount: 1,
            encoding: .pcm16
        )
        let outputURL = Self.makeTemporaryRecordingURL(for: request.runID)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            await removeServiceOwnedFile(outputURL, runID: request.runID)
        }
        try Task.checkCancellation()
        try requireAcceptingStarts()
        // Removing a stale artifact crosses the cleanup actor and therefore
        // permits this actor to accept another start. Revalidate the capture
        // slot after that final suspension so the older request can never
        // create a recorder and overwrite the newer capture's state.
        guard recorder == nil else {
            throw CaptureError.alreadyCapturing
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRateHz,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder: any AVAudioRecorderControlling
        do {
            recorder = try recorderFactory(outputURL, settings)
        } catch {
            await removeServiceOwnedFile(outputURL, runID: request.runID)
            throw CaptureError.recorderInitializationFailed
        }

        guard recorder.prepareToRecord() else {
            recorder.stop()
            await removeServiceOwnedFile(outputURL, runID: request.runID)
            throw CaptureError.recorderInitializationFailed
        }
        guard recorder.record() else {
            recorder.stop()
            await removeServiceOwnedFile(outputURL, runID: request.runID)
            throw CaptureError.startFailed
        }

        nextCaptureGeneration &+= 1
        let generation = nextCaptureGeneration
        let readinessGate = AVAudioCaptureReadinessGate()

        self.recorder = recorder
        activeRequest = request
        self.outputURL = outputURL
        activeCaptureGeneration = generation
        readyCaptureGeneration = nil
        activeReadinessGate = readinessGate
        let readinessTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorReadiness(
                generation: generation,
                gate: readinessGate
            )
        }
        activeReadinessTask = readinessTask

        do {
            try await readinessGate.wait(
                timeout: startupTimeout,
                sleep: timeoutSleep
            )
            try Task.checkCancellation()
            guard activeCaptureGeneration == generation,
                  activeRequest?.runID == request.runID,
                  self.recorder?.isRecording == true,
                  (self.recorder?.currentTime ?? 0) > 0 else {
                throw CancellationError()
            }

            activeReadinessGate = nil
            activeReadinessTask = nil
            await readinessTask.value

            try Task.checkCancellation()
            guard activeCaptureGeneration == generation,
                  activeRequest?.runID == request.runID,
                  self.recorder?.isRecording == true,
                  (self.recorder?.currentTime ?? 0) > 0 else {
                throw CancellationError()
            }
            readyCaptureGeneration = generation
            didStart = true
        } catch is CancellationError {
            await abandonCapture(generation: generation)
            throw CancellationError()
        } catch let failure as AVAudioCaptureReadinessGate.Failure {
            await abandonCapture(generation: generation)
            switch failure {
            case .recorderStopped:
                throw CaptureError.startFailed
            case .timedOut:
                throw CaptureError.startTimedOut
            }
        }
    }

    public func finishCapture() async throws -> CapturedAudio {
        guard let recorder,
              let activeRequest,
              let outputURL,
              let activeCaptureGeneration,
              readyCaptureGeneration == activeCaptureGeneration else {
            throw CaptureError.notCapturing
        }

        recorder.stop()
        let durationSeconds = recorder.currentTime
        let format = activeRequest.preferredFormat ?? AudioFormat(
            sampleRateHz: recorder.settings[AVSampleRateKey] as? Double ?? 16_000,
            channelCount: recorder.settings[AVNumberOfChannelsKey] as? Int ?? 1,
            encoding: .pcm16
        )
        let metadata = activeRequest.metadata.merging(
            ["runID": activeRequest.runID.uuidString],
            uniquingKeysWith: { _, new in new }
        )

        do {
            let capturedAudio = try CapturedAudio(
                durationSeconds: durationSeconds,
                format: format,
                fileURL: outputURL,
                fileOwnership: .managedTemporary,
                metadata: metadata
            )
            self.recorder = nil
            self.activeRequest = nil
            self.outputURL = nil
            self.activeCaptureGeneration = nil
            readyCaptureGeneration = nil
            activeRequest.endpointControl?.finish()
            return capturedAudio
        } catch {
            await transferServiceOwnedFile(outputURL, runID: activeRequest.runID)
            self.recorder = nil
            self.activeRequest = nil
            self.outputURL = nil
            self.activeCaptureGeneration = nil
            readyCaptureGeneration = nil
            activeRequest.endpointControl?.finish()
            await cleanupOwner.drain(runID: activeRequest.runID)
            throw error
        }
    }

    public func cancelCapture() async {
        guard let activeCaptureGeneration else { return }
        await abandonCapture(generation: activeCaptureGeneration)
    }

    public func cancelCapture(runID: UUID) async {
        guard activeRequest?.runID == runID else { return }
        await cancelCapture()
    }

    public func shutdown() async {
        switch lifecycle {
        case .accepting:
            lifecycle = .shuttingDown
        case .shuttingDown:
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        case .terminated:
            return
        }

        await cancelCapture()
        await cleanupOwner.drain()
        lifecycle = .terminated
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func removeServiceOwnedFile(_ fileURL: URL, runID: UUID) async {
        await transferServiceOwnedFile(fileURL, runID: runID)
        await cleanupOwner.drain(runID: runID)
    }

    private func transferServiceOwnedFile(_ fileURL: URL, runID: UUID) async {
        _ = await cleanupOwner.transfer(fileURL: fileURL, runID: runID)
    }

    private func requireAcceptingStarts() throws {
        guard lifecycle == .accepting else {
            throw CaptureError.shuttingDown
        }
    }

    private func monitorReadiness(
        generation: UInt64,
        gate: AVAudioCaptureReadinessGate
    ) async {
        while !Task.isCancelled {
            guard lifecycle == .accepting,
                  activeCaptureGeneration == generation,
                  let recorder else {
                await gate.cancel()
                return
            }
            guard recorder.isRecording else {
                await gate.signalRecorderStopped()
                return
            }
            if recorder.currentTime > 0 {
                await gate.signalReady()
                return
            }

            do {
                try await readinessPollSleep(readinessPollInterval)
            } catch {
                await gate.cancel()
                return
            }
        }
        await gate.cancel()
    }

    private func abandonCapture(generation: UInt64) async {
        guard activeCaptureGeneration == generation else { return }

        let recorder = self.recorder
        let endpointControl = activeRequest?.endpointControl
        let runID = activeRequest?.runID
        let outputURL = self.outputURL
        let readinessGate = activeReadinessGate
        let readinessTask = activeReadinessTask

        self.recorder = nil
        activeRequest = nil
        self.outputURL = nil
        activeCaptureGeneration = nil
        readyCaptureGeneration = nil
        activeReadinessGate = nil
        activeReadinessTask = nil
        endpointControl?.finish()

        recorder?.stop()
        await readinessGate?.cancel()
        readinessTask?.cancel()
        await readinessTask?.value

        if let outputURL, let runID {
            await transferServiceOwnedFile(outputURL, runID: runID)
            await cleanupOwner.drain(runID: runID)
        }
    }

    private static func makeTemporaryRecordingURL(for runID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-\(runID.uuidString)")
            .appendingPathExtension("wav")
    }
}

actor AVAudioCaptureReadinessGate {
    enum Failure: Error, Equatable, Sendable {
        case recorderStopped
        case timedOut
    }

    private enum Resolution: Sendable {
        case ready
        case failed(Failure)
        case cancelled
    }

    private var resolution: Resolution?
    private var waiters: [CheckedContinuation<Resolution, Never>] = []

    func wait(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        let timeoutTask = Task { [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            await self?.resolve(.failed(.timedOut))
        }

        let resolution = await withTaskCancellationHandler {
            await nextResolution()
        } onCancel: {
            Task { [weak self] in
                await self?.resolve(.cancelled)
            }
        }
        timeoutTask.cancel()
        await timeoutTask.value
        try Task.checkCancellation()

        switch resolution {
        case .ready:
            return
        case .failed(let failure):
            throw failure
        case .cancelled:
            throw CancellationError()
        }
    }

    func signalReady() {
        resolve(.ready)
    }

    func signalRecorderStopped() {
        resolve(.failed(.recorderStopped))
    }

    func cancel() {
        resolve(.cancelled)
    }

    private func nextResolution() async -> Resolution {
        if let resolution {
            return resolution
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resolve(_ resolution: Resolution) {
        guard self.resolution == nil else { return }
        self.resolution = resolution
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
    }
}
