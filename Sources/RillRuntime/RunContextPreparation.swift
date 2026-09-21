import Foundation
import RillCore

/// The recording owns these tasks; freezing is a synchronous read, never a task join.
public final class RunContextPreparation: @unchecked Sendable {
    public struct Frozen: Sendable, Equatable {
        public var request: ContextualCorrectionRequest
        public var receipt: CorrectionReferenceReceipt
    }

    private let lock = NSLock()
    private let authorization: ContextReferenceAuthorization
    private let audioLifetime: AudioCaptureLifetime
    private let saveLateSummary: @Sendable (ScreenReferenceSummary, ContextReferenceAuthorization) async -> Void
    private var image: CorrectionReferenceImage?
    private var screenSummary: ScreenReferenceSummary?
    private var memorySummary: CorrectionMemorySummary?
    private var receipt: CorrectionReferenceReceipt
    private var hasFrozen = false
    private var cancelled = false
    private var startAction: (@Sendable () -> Void)?
    private var historyWasSaved = false
    private var imageTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?

    private init(image: CorrectionReferenceImage?, receipt: CorrectionReferenceReceipt,
                 authorization: ContextReferenceAuthorization, audioLifetime: AudioCaptureLifetime,
                 saveLateSummary: @escaping @Sendable (ScreenReferenceSummary, ContextReferenceAuthorization) async -> Void) {
        self.image = image
        self.receipt = receipt
        self.authorization = ContextReferenceAuthorization(parent: authorization)
        self.audioLifetime = audioLifetime
        self.saveLateSummary = saveLateSummary
    }

    public static func skipped(authorization: ContextReferenceAuthorization, audioLifetime: AudioCaptureLifetime,
                               screenEnabled: Bool, memoryEnabled: Bool, status: CorrectionReferenceStatus) -> RunContextPreparation {
        RunContextPreparation(image: nil, receipt: .init(image: screenEnabled ? status : .disabled,
            imageSummary: screenEnabled ? status : .disabled, memorySummary: memoryEnabled ? status : .disabled),
            authorization: authorization, audioLifetime: audioLifetime, saveLateSummary: { _, _ in })
    }

    public static func prepare(
        focus: FocusSnapshot, screenEnabled: Bool, memoryEnabled: Bool, canSendImages: Bool = true,
        excludedApplications: Set<String>, capture: any ScreenContextCapturing,
        summarizer: any CorrectionContextSummarizing,
        memories: @escaping @Sendable () async throws -> [LongTermMemory],
        authorization: ContextReferenceAuthorization, audioLifetime: AudioCaptureLifetime,
        captureTimeout: Duration = .milliseconds(250), summaryTimeout: Duration = .seconds(10),
        saveLateSummary: @escaping @Sendable (ScreenReferenceSummary, ContextReferenceAuthorization) async -> Void = { _, _ in }
    ) async throws -> RunContextPreparation {
        try Task.checkCancellation()
        guard authorization.isValid, audioLifetime.isActive else { throw CancellationError() }
        var image: CorrectionReferenceImage?
        var receipt = CorrectionReferenceReceipt()
        if screenEnabled && canSendImages {
            do {
                image = try await BoundedOperation.run(timeout: captureTimeout) {
                    guard authorization.isValid, audioLifetime.isActive else { throw CancellationError() }
                    return try await capture.capture(focus: focus, excludingApplications: excludedApplications)
                }
                receipt.image = .ready
            } catch is CancellationError { throw CancellationError() }
            catch is OperationDeadlineError { receipt.image = .timedOut }
            catch { receipt.image = .unavailable }
            receipt.imageSummary = image == nil ? .unavailable : .pending
        }
        if screenEnabled && !canSendImages { receipt.image = .unavailable; receipt.imageSummary = .unavailable }
        guard authorization.isValid, audioLifetime.isActive else { throw CancellationError() }
        receipt.memorySummary = memoryEnabled ? .pending : .disabled
        let preparation = RunContextPreparation(
            image: image, receipt: receipt, authorization: authorization,
            audioLifetime: audioLifetime, saveLateSummary: saveLateSummary
        )
        let capturedImage = image
        preparation.startAction = { [weak preparation] in
            preparation?.start(image: capturedImage, memoryEnabled: memoryEnabled,
                               summarizer: summarizer, memories: memories, timeout: summaryTimeout)
        }
        return preparation
    }

    var preparedReceipt: CorrectionReferenceReceipt { lock.withLock { receipt } }

    public var isFinished: Bool {
        lock.withLock { cancelled || (hasFrozen && imageTask == nil && memoryTask == nil) }
    }

    public func recordingStarted() {
        let action = lock.withLock {
            defer { startAction = nil }
            return isValid ? startAction : nil
        }
        action?()
    }

    private func start(image: CorrectionReferenceImage?, memoryEnabled: Bool,
                       summarizer: any CorrectionContextSummarizing,
                       memories: @escaping @Sendable () async throws -> [LongTermMemory], timeout: Duration) {
        lock.withLock {
            guard isValid, !hasFrozen else { return }
            if let image {
                imageTask = Task { [weak self] in
                    do {
                        let summary = try await BoundedOperation.run(timeout: timeout) {
                            try await summarizer.summarizeImage(image)
                        }
                        guard summary.isValid else { throw ContextCorrectionError.invalidReference }
                        await self?.imageFinished(summary: summary, status: .ready)
                    } catch {
                        await self?.imageFinished(summary: nil, status: Self.status(for: error))
                    }
                }
            }
            if memoryEnabled {
                memoryTask = Task { [weak self] in
                    do {
                        let summary: CorrectionMemorySummary? = try await BoundedOperation.run(timeout: timeout) {
                            let selected = Array(try await memories().prefix(5))
                            guard !selected.isEmpty else { return nil }
                            return try await summarizer.summarizeMemories(selected)
                        }
                        self?.memoryFinished(summary: summary, status: summary == nil ? .unavailable : .ready)
                    } catch {
                        self?.memoryFinished(summary: nil, status: Self.status(for: error))
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        guard !cancelled, authorization.isValid else { return false }
        if case .revoked = audioLifetime.state { return false }
        return true
    }

    public func freeze(transcript: String) throws -> Frozen {
        try lock.withLock {
            guard isValid else { throw CancellationError() }
            guard !hasFrozen else { throw ContextCorrectionError.invalidReference }
            startAction = nil
            memoryTask?.cancel()
            memoryTask = nil
            let value = Frozen(
                request: ContextualCorrectionRequest(
                    transcript: transcript, referenceImage: image, imageSummary: screenSummary,
                    memorySummary: memorySummary, authorization: authorization
                ),
                receipt: receipt
            )
            // Keep only the receipt here; the caller owns the frozen request and its image.
            hasFrozen = true
            image = nil
            memorySummary = nil
            return value
        }
    }

    public func cancel() {
        authorization.revoke()
        lock.withLock {
            cancelled = true
            startAction = nil
            imageTask?.cancel()
            memoryTask?.cancel()
            imageTask = nil
            memoryTask = nil
            image = nil
            screenSummary = nil
            memorySummary = nil
            hasFrozen = true
        }
    }

    public var historyUpdate: CorrectionHistoryUpdate {
        CorrectionHistoryUpdate { [self] in
            let summary = lock.withLock {
                historyWasSaved = true
                return isValid ? screenSummary : nil
            }
            if let summary { await saveLateSummary(summary, authorization) }
        }
    }

    private func imageFinished(summary: ScreenReferenceSummary?, status: CorrectionReferenceStatus) async {
        let shouldSave = lock.withLock {
            guard isValid else { return false }
            screenSummary = summary
            receipt.screenSummary = summary
            receipt.imageSummary = status
            imageTask = nil
            return historyWasSaved && summary != nil
        }
        if shouldSave, let summary { await saveLateSummary(summary, authorization) }
    }

    private func memoryFinished(summary: CorrectionMemorySummary?, status: CorrectionReferenceStatus) {
        lock.withLock {
            guard isValid, !hasFrozen else { return }
            memorySummary = summary
            receipt.memorySummary = status
            receipt.memoryIDs = summary?.memoryIDs ?? []
            memoryTask = nil
        }
    }

    private static func status(for error: Error) -> CorrectionReferenceStatus {
        if error is CancellationError { return .cancelled }
        return error is OperationDeadlineError ? .timedOut : .failed
    }
}
