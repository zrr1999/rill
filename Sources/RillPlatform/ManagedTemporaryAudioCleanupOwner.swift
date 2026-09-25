import Foundation
import RillCore

/// A process-lifetime ownership boundary for plaintext audio files that Rill must remove.
///
/// Producers transfer a managed temporary URL here before clearing their own reference. Cleanup
/// then continues independently of caller cancellation, and application shutdown can drain every
/// accepted file instead of relying on a later startup janitor.
public actor ManagedTemporaryAudioCleanupOwner: ManagedTemporaryAudioCleaning {
    public struct Diagnostic: Sendable, Equatable {
        public enum Outcome: String, Sendable, Equatable {
            case retryPending = "retry-pending"
            case completedAfterRetry = "completed-after-retry"
        }

        public let runID: UUID
        public let outcome: Outcome

        public init(runID: UUID, outcome: Outcome) {
            self.runID = runID
            self.outcome = outcome
        }

        public var event: String {
            switch outcome {
            case .retryPending:
                "managed-audio.cleanup-retry-pending"
            case .completedAfterRetry:
                "managed-audio.cleanup-completed-after-retry"
            }
        }

        public var message: String {
            switch outcome {
            case .retryPending:
                "Managed temporary audio cleanup remains pending."
            case .completedAfterRetry:
                "Managed temporary audio cleanup completed after a retry."
            }
        }
    }

    public typealias Removal = @Sendable (URL) async throws -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias DiagnosticReporter = @Sendable (Diagnostic) async -> Void

    private struct Work: Sendable {
        let runID: UUID
        let standardizedURL: URL
        let task: Task<Void, Never>
    }

    private let removal: Removal
    private let initialRetryDelay: Duration
    private let maximumRetryDelay: Duration
    private let sleep: Sleep
    private let diagnosticReporter: DiagnosticReporter

    private var workByID: [UUID: Work] = [:]
    private var workIDByURL: [URL: UUID] = [:]

    public init(
        removal: @escaping Removal = { url in
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return
            }
            guard !isDirectory.boolValue else {
                return
            }
            try fileManager.removeItem(at: url)
        },
        initialRetryDelay: Duration = .milliseconds(100),
        maximumRetryDelay: Duration = .seconds(5),
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(for: delay)
        },
        diagnosticReporter: @escaping DiagnosticReporter = { _ in }
    ) {
        precondition(initialRetryDelay > .zero)
        precondition(maximumRetryDelay >= initialRetryDelay)
        self.removal = removal
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
        self.sleep = sleep
        self.diagnosticReporter = diagnosticReporter
    }

    /// Transfers a raw service-owned URL before the service clears its capture state.
    /// Invalid or non-Rill temporary URLs are rejected without touching the file.
    @discardableResult
    public func transfer(fileURL: URL, runID: UUID) -> Bool {
        let standardizedURL = fileURL.standardizedFileURL
        guard CapturedAudio.isManagedTemporaryFileURL(standardizedURL) else {
            return false
        }
        if workIDByURL[standardizedURL] != nil {
            return true
        }

        let workID = UUID()
        let removal = self.removal
        let initialRetryDelay = self.initialRetryDelay
        let maximumRetryDelay = self.maximumRetryDelay
        let sleep = self.sleep
        let diagnosticReporter = self.diagnosticReporter
        let task = Task { [weak self] in
            await Self.retryRemoval(
                standardizedURL,
                runID: runID,
                removal: removal,
                initialRetryDelay: initialRetryDelay,
                maximumRetryDelay: maximumRetryDelay,
                sleep: sleep,
                diagnosticReporter: diagnosticReporter
            )
            await self?.didFinish(workID)
        }
        workByID[workID] = Work(
            runID: runID,
            standardizedURL: standardizedURL,
            task: task
        )
        workIDByURL[standardizedURL] = workID
        return true
    }

    /// Waits for all currently and subsequently finishing accepted work in the selected scope.
    public func drain(runID: UUID? = nil) async {
        while true {
            let tasks: [Task<Void, Never>] = workByID.values.compactMap { work -> Task<Void, Never>? in
                guard runID == nil || work.runID == runID else { return nil }
                return work.task
            }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    public var pendingCount: Int {
        workByID.count
    }

    private static func retryRemoval(
        _ fileURL: URL,
        runID: UUID,
        removal: @escaping Removal,
        initialRetryDelay: Duration,
        maximumRetryDelay: Duration,
        sleep: @escaping Sleep,
        diagnosticReporter: @escaping DiagnosticReporter
    ) async {
        var retryDelay = initialRetryDelay
        var didFail = false
        while true {
            do {
                try await removal(fileURL)
                if didFail {
                    await diagnosticReporter(
                        Diagnostic(runID: runID, outcome: .completedAfterRetry)
                    )
                }
                return
            } catch {
                if !didFail {
                    didFail = true
                    await diagnosticReporter(
                        Diagnostic(runID: runID, outcome: .retryPending)
                    )
                }
                let delay = retryDelay
                await Task.detached {
                    do {
                        try await sleep(delay)
                    } catch {
                        try? await Task.sleep(for: delay)
                    }
                }.value
                retryDelay = min(retryDelay * 2, maximumRetryDelay)
            }
        }
    }

    private func didFinish(_ workID: UUID) {
        guard let work = workByID.removeValue(forKey: workID) else { return }
        if workIDByURL[work.standardizedURL] == workID {
            workIDByURL[work.standardizedURL] = nil
        }
    }
}
