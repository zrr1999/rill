import Darwin
import Foundation
import RillCore

public struct ShortcutsRunAction: OutputAction {
    public let id = ExternalOutputActionID.shortcutsRun
    private let runner: any ShortcutsProcessRunning

    public init() {
        self.runner = SystemShortcutsProcessRunner()
    }

    init(runner: any ShortcutsProcessRunning) {
        self.runner = runner
    }

    public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        do {
            guard case .shortcut(let shortcutName) = try context.configuration(for: id) else {
                return .failed("Shortcut configuration is invalid.")
            }
            try await runner.runShortcut(named: shortcutName, inputText: text)
            return .externalOutput("Shortcut: \(shortcutName)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

protocol ShortcutsProcessRunning: Sendable {
    func runShortcut(named shortcutName: String, inputText: String) async throws
}

struct ShortcutProcessCommand: Sendable {
    var executableURL: URL
    var arguments: [String]
}

struct SystemShortcutsProcessRunner: ShortcutsProcessRunning {
    typealias CommandBuilder = @Sendable (String, URL) -> ShortcutProcessCommand

    private static let defaultStderrByteLimit = 16 * 1_024

    private let timeout: Duration
    private let terminationGracePeriod: Duration
    private let stderrDrainGracePeriod: Duration
    private let stderrByteLimit: Int
    private let temporaryDirectory: URL
    private let commandBuilder: CommandBuilder

    init(
        timeout: Duration = .seconds(30),
        terminationGracePeriod: Duration = .milliseconds(500),
        stderrDrainGracePeriod: Duration = .milliseconds(100),
        stderrByteLimit: Int = defaultStderrByteLimit,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        commandBuilder: @escaping CommandBuilder = { shortcutName, inputURL in
            ShortcutProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
                arguments: ["run", shortcutName, "--input-path", inputURL.path]
            )
        }
    ) {
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.stderrDrainGracePeriod = stderrDrainGracePeriod
        self.stderrByteLimit = max(stderrByteLimit, 0)
        self.temporaryDirectory = temporaryDirectory
        self.commandBuilder = commandBuilder
    }

    func runShortcut(named shortcutName: String, inputText: String) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let inputURL = temporaryDirectory
            .appendingPathComponent("rill-shortcut-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try inputText.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let execution = ShortcutProcessExecution(
            command: commandBuilder(shortcutName, inputURL),
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            stderrDrainGracePeriod: stderrDrainGracePeriod,
            stderrByteLimit: stderrByteLimit
        )
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class ShortcutProcessExecution: @unchecked Sendable {
    private enum RequestedTermination: Sendable {
        case cancelled
        case timedOut
    }

    private struct Completion: Sendable {
        var terminationStatus: Int32
        var requestedTermination: RequestedTermination?
        var stderr: String?
    }

    private let lock = NSLock()
    private let command: ShortcutProcessCommand
    private let timeout: Duration
    private let terminationGracePeriod: Duration
    private let stderrDrainGracePeriod: Duration
    private let stderrByteLimit: Int

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stderrData = Data()
    private var stderrWasTruncated = false
    private var stderrReachedEOF = false
    private var terminationStatus: Int32?
    private var requestedTermination: RequestedTermination?
    private var completion: Completion?
    private var completionContinuation: CheckedContinuation<Completion, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var stderrDrainTask: Task<Void, Never>?

    init(
        command: ShortcutProcessCommand,
        timeout: Duration,
        terminationGracePeriod: Duration,
        stderrDrainGracePeriod: Duration,
        stderrByteLimit: Int
    ) {
        self.command = command
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.stderrDrainGracePeriod = stderrDrainGracePeriod
        self.stderrByteLimit = stderrByteLimit
    }

    func run() async throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.stderrDidReachEOF()
            } else {
                self?.appendStderr(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        let prelaunchTermination = withLock {
            self.process = process
            self.stderrPipe = stderrPipe
            return requestedTermination
        }
        if let prelaunchTermination {
            cleanup(process: process, stderrPipe: stderrPipe)
            throw error(for: prelaunchTermination)
        }

        do {
            try process.run()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            cleanup(process: process, stderrPipe: stderrPipe)
            throw error
        }

        let terminationAfterLaunch = withLock { requestedTermination }
        if let terminationAfterLaunch {
            requestTermination(terminationAfterLaunch)
        } else {
            scheduleTimeout()
        }

        let completion = await waitForCompletion()
        cleanup(process: process, stderrPipe: stderrPipe)

        switch completion.requestedTermination {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw ExternalOutputActionError.shortcutTimedOut
        case nil:
            guard completion.terminationStatus == 0 else {
                throw ExternalOutputActionError.shortcutFailed(completion.stderr)
            }
        }
    }

    func cancel() {
        requestTermination(.cancelled)
    }

    private func scheduleTimeout() {
        let task = Task.detached(priority: .utility) { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.requestTermination(.timedOut)
        }
        let shouldKeepTask = withLock {
            guard terminationStatus == nil, requestedTermination == nil, completion == nil else {
                return false
            }
            timeoutTask = task
            return true
        }
        if !shouldKeepTask {
            task.cancel()
        }
    }

    private func requestTermination(_ reason: RequestedTermination) {
        let processToTerminate: Process? = withLock {
            guard terminationStatus == nil, completion == nil else { return nil }
            if requestedTermination == nil {
                requestedTermination = reason
            }
            return process?.isRunning == true ? process : nil
        }
        guard let processToTerminate else { return }

        processToTerminate.terminate()
        scheduleForcedTermination()
    }

    private func scheduleForcedTermination() {
        let task = Task.detached(priority: .utility) { [weak self, terminationGracePeriod] in
            do {
                try await Task.sleep(for: terminationGracePeriod)
            } catch {
                return
            }
            self?.forceTerminateIfNeeded()
        }
        let shouldKeepTask = withLock {
            guard terminationStatus == nil, completion == nil, escalationTask == nil else {
                return false
            }
            escalationTask = task
            return true
        }
        if !shouldKeepTask {
            task.cancel()
        }
    }

    private func forceTerminateIfNeeded() {
        let processIdentifier: pid_t? = withLock {
            guard terminationStatus == nil,
                  completion == nil,
                  let process,
                  process.isRunning else {
                return nil
            }
            return process.processIdentifier
        }
        if let processIdentifier {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func appendStderr(_ data: Data) {
        withLock {
            let remainingCapacity = max(stderrByteLimit - stderrData.count, 0)
            if remainingCapacity > 0 {
                stderrData.append(contentsOf: data.prefix(remainingCapacity))
            }
            if data.count > remainingCapacity {
                stderrWasTruncated = true
            }
        }
    }

    private func stderrDidReachEOF() {
        let resolution = withLock { () -> (CheckedContinuation<Completion, Never>, Completion)? in
            stderrReachedEOF = true
            return resolveCompletionIfReady(force: false)
        }
        if let resolution {
            resolution.0.resume(returning: resolution.1)
        }
    }

    private func processDidTerminate(status: Int32) {
        let outcome = withLock { () -> (
            resolution: (CheckedContinuation<Completion, Never>, Completion)?,
            needsDrainDeadline: Bool
        ) in
            guard terminationStatus == nil, completion == nil else {
                return (nil, false)
            }
            terminationStatus = status
            timeoutTask?.cancel()
            timeoutTask = nil
            escalationTask?.cancel()
            escalationTask = nil
            let resolution = resolveCompletionIfReady(force: false)
            return (resolution, resolution == nil)
        }
        if let resolution = outcome.resolution {
            resolution.0.resume(returning: resolution.1)
        }
        if outcome.needsDrainDeadline {
            scheduleStderrDrainDeadline()
        }
    }

    private func scheduleStderrDrainDeadline() {
        let task = Task.detached(priority: .utility) { [weak self, stderrDrainGracePeriod] in
            do {
                try await Task.sleep(for: stderrDrainGracePeriod)
            } catch {
                return
            }
            self?.forceStderrDrainCompletion()
        }
        let shouldKeepTask = withLock {
            guard completion == nil, stderrDrainTask == nil else { return false }
            stderrDrainTask = task
            return true
        }
        if !shouldKeepTask {
            task.cancel()
        }
    }

    private func forceStderrDrainCompletion() {
        let resolution = withLock {
            resolveCompletionIfReady(force: true)
        }
        if let resolution {
            resolution.0.resume(returning: resolution.1)
        }
    }

    private func resolveCompletionIfReady(
        force: Bool
    ) -> (CheckedContinuation<Completion, Never>, Completion)? {
        guard completion == nil,
              let terminationStatus,
              force || stderrReachedEOF else {
            return nil
        }

        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        let resolved = Completion(
            terminationStatus: terminationStatus,
            requestedTermination: requestedTermination,
            stderr: stderrMessage()
        )
        completion = resolved
        guard let completionContinuation else { return nil }
        self.completionContinuation = nil
        return (completionContinuation, resolved)
    }

    private func waitForCompletion() async -> Completion {
        await withCheckedContinuation { continuation in
            let readyCompletion = withLock { () -> Completion? in
                if let completion {
                    return completion
                }
                completionContinuation = continuation
                return nil
            }
            if let readyCompletion {
                continuation.resume(returning: readyCompletion)
            }
        }
    }

    private func stderrMessage() -> String? {
        var message = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stderrWasTruncated {
            message += message.isEmpty ? "[stderr truncated]" : "\n[stderr truncated]"
        }
        return message.isEmpty ? nil : message
    }

    private func error(for reason: RequestedTermination) -> any Error {
        switch reason {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return ExternalOutputActionError.shortcutTimedOut
        }
    }

    private func cleanup(process: Process, stderrPipe: Pipe) {
        process.terminationHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        withLock {
            timeoutTask?.cancel()
            timeoutTask = nil
            escalationTask?.cancel()
            escalationTask = nil
            stderrDrainTask?.cancel()
            stderrDrainTask = nil
            self.process = nil
            self.stderrPipe = nil
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

public struct MarkdownAppendAction: OutputAction {
    public let id = ExternalOutputActionID.markdownAppend
    private let appender: any MarkdownFileAppending

    public init() {
        self.appender = FileManagerMarkdownFileAppender()
    }

    public init(cleanupCoordinator: MarkdownFileAppendCoordinator) {
        self.appender = FileManagerMarkdownFileAppender(coordinator: cleanupCoordinator)
    }

    init(appender: any MarkdownFileAppending) {
        self.appender = appender
    }

    public func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        do {
            guard case .markdown(let fileURL) = try context.configuration(for: id) else {
                return .failed("Markdown configuration is invalid.")
            }
            switch try await appender.append(text: text, to: fileURL) {
            case .committed:
                return .externalOutput("Markdown append")
            case .committedCleanupPending:
                return .externalOutput("Markdown append committed; cleanup pending")
            case .committedCleanupIndeterminate:
                return .externalOutput("Markdown append committed; cleanup indeterminate")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

enum MarkdownAppendCommitResult: Sendable, Equatable {
    case committed
    case committedCleanupPending
    case committedCleanupIndeterminate
}

protocol MarkdownFileAppending: Sendable {
    func append(text: String, to fileURL: URL) async throws -> MarkdownAppendCommitResult
}

struct FileManagerMarkdownFileAppender: MarkdownFileAppending {
    typealias BeforeCommit = @Sendable () async throws -> Void

    private let coordinator: MarkdownFileAppendCoordinator
    private let beforeCommit: BeforeCommit

    init(
        coordinator: MarkdownFileAppendCoordinator = .shared,
        beforeCommit: @escaping BeforeCommit = {}
    ) {
        self.coordinator = coordinator
        self.beforeCommit = beforeCommit
    }

    func append(text: String, to fileURL: URL) async throws -> MarkdownAppendCommitResult {
        try Task.checkCancellation()
        try await beforeCommit()
        try Task.checkCancellation()
        return try await coordinator.append(text: text, to: fileURL)
    }
}

protocol MarkdownPayloadWriting: Sendable {
    func write(_ data: Data, to descriptor: Int32) throws
}

struct POSIXMarkdownPayloadWriter: MarkdownPayloadWriting {
    func write(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
            }
            if result > 0 {
                written += result
                continue
            }
            if result < 0, errno == EINTR {
                continue
            }
            throw MarkdownFileAppendError.filesystemFailure
        }
    }
}

struct MarkdownAppendTransactionContext: Sendable {
    let parentDescriptor: Int32
    let targetName: String
    let temporaryName: String
}

struct MarkdownAppendTransactionHooks: Sendable {
    let beforePublish: @Sendable (MarkdownAppendTransactionContext) throws -> Void
    let afterPublishBeforeVerification: @Sendable (MarkdownAppendTransactionContext) throws -> Void
    let beforeSwappedOutCleanup: @Sendable (MarkdownAppendTransactionContext) throws -> Void
    let beforeParentDirectorySync: @Sendable (MarkdownAppendTransactionContext) throws -> Void
    let afterCommit: @Sendable (MarkdownAppendTransactionContext) -> Void

    init(
        beforePublish: @escaping @Sendable (MarkdownAppendTransactionContext) throws -> Void = { _ in },
        afterPublishBeforeVerification: @escaping @Sendable (MarkdownAppendTransactionContext) throws -> Void = { _ in },
        beforeSwappedOutCleanup: @escaping @Sendable (MarkdownAppendTransactionContext) throws -> Void = { _ in },
        beforeParentDirectorySync: @escaping @Sendable (MarkdownAppendTransactionContext) throws -> Void = { _ in },
        afterCommit: @escaping @Sendable (MarkdownAppendTransactionContext) -> Void = { _ in }
    ) {
        self.beforePublish = beforePublish
        self.afterPublishBeforeVerification = afterPublishBeforeVerification
        self.beforeSwappedOutCleanup = beforeSwappedOutCleanup
        self.beforeParentDirectorySync = beforeParentDirectorySync
        self.afterCommit = afterCommit
    }
}

struct MarkdownFilesystemCapabilities: Sendable {
    let openUniqueFlag: Int32
    let atUniqueFlag: Int32
    let renameNoFollowAnyFlag: UInt32

    static let compatibility = MarkdownFilesystemCapabilities(
        openUniqueFlag: 0,
        atUniqueFlag: 0,
        renameNoFollowAnyFlag: 0
    )

    static var current: MarkdownFilesystemCapabilities {
        let firstSupportedVersion = OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 1,
            patchVersion: 0
        )
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(firstSupportedVersion) else {
            return .compatibility
        }
        // These values are SDK constants beginning with macOS 26.1. Keep the
        // raw values behind a runtime gate so the macOS 14 build remains
        // source-compatible with older SDKs and never sends unknown flags to
        // an older kernel.
        return MarkdownFilesystemCapabilities(
            openUniqueFlag: 0x0000_2000,
            atUniqueFlag: 0x0000_8000,
            renameNoFollowAnyFlag: 0x0000_0010
        )
    }
}

public struct MarkdownPostCommitCleanupDiagnostic: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case retryPending = "retry-pending"
        case completedAfterRetry = "completed-after-retry"
        case indeterminate = "indeterminate"
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }

    public var event: DiagnosticEventName {
        switch outcome {
        case .retryPending:
            .markdownAppendCleanupRetryPending
        case .completedAfterRetry:
            .markdownAppendCleanupCompletedAfterRetry
        case .indeterminate:
            .markdownAppendCleanupIndeterminate
        }
    }

    public var message: String {
        switch outcome {
        case .retryPending:
            "Markdown post-commit cleanup remains pending."
        case .completedAfterRetry:
            "Markdown post-commit cleanup completed after a retry."
        case .indeterminate:
            "Markdown append committed, but concurrent namespace changes made displaced-file cleanup indeterminate."
        }
    }
}

public actor MarkdownFileAppendCoordinator {
    static let shared = MarkdownFileAppendCoordinator(
        automaticCleanupRetryDelays: [
            .milliseconds(50),
            .milliseconds(250),
            .seconds(1),
            .seconds(5),
        ]
    )

    private static let maximumFileByteCount = 64 * 1_024 * 1_024
    private let payloadWriter: any MarkdownPayloadWriting
    private let hooks: MarkdownAppendTransactionHooks
    private let filesystemCapabilities: MarkdownFilesystemCapabilities
    private let automaticCleanupRetryDelays: [Duration]
    private let drainInitialRetryDelay: Duration
    private let drainMaximumRetryDelay: Duration
    private let cleanupRetrySleep: @Sendable (Duration) async throws -> Void
    private let diagnosticReporter: @Sendable (MarkdownPostCommitCleanupDiagnostic) async -> Void
    private var pendingPostCommitCleanups: [PendingPostCommitCleanup] = []
    private var automaticCleanupRetryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var cleanupGeneration: UInt64 = 0
    private var lifecycleState: LifecycleState = .accepting

    private enum LifecycleState {
        case accepting
        case sealed
        case drained
    }

    public init(
        cleanupDiagnosticReporter: @escaping @Sendable (
            MarkdownPostCommitCleanupDiagnostic
        ) async -> Void
    ) {
        self.payloadWriter = POSIXMarkdownPayloadWriter()
        self.hooks = MarkdownAppendTransactionHooks()
        self.filesystemCapabilities = .current
        self.automaticCleanupRetryDelays = [
            .milliseconds(50),
            .milliseconds(250),
            .seconds(1),
            .seconds(5),
        ]
        self.drainInitialRetryDelay = .milliseconds(100)
        self.drainMaximumRetryDelay = .seconds(5)
        self.cleanupRetrySleep = { delay in
            try await Task.sleep(for: delay)
        }
        self.diagnosticReporter = cleanupDiagnosticReporter
    }

    init(
        payloadWriter: any MarkdownPayloadWriting = POSIXMarkdownPayloadWriter(),
        hooks: MarkdownAppendTransactionHooks = MarkdownAppendTransactionHooks(),
        filesystemCapabilities: MarkdownFilesystemCapabilities = .current,
        automaticCleanupRetryDelays: [Duration] = [],
        drainInitialRetryDelay: Duration = .milliseconds(1),
        drainMaximumRetryDelay: Duration = .milliseconds(1),
        cleanupRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await Task.sleep(for: delay)
        },
        diagnosticReporter: @escaping @Sendable (
            MarkdownPostCommitCleanupDiagnostic
        ) async -> Void = { _ in }
    ) {
        precondition(drainInitialRetryDelay > .zero)
        precondition(drainMaximumRetryDelay >= drainInitialRetryDelay)
        self.payloadWriter = payloadWriter
        self.hooks = hooks
        self.filesystemCapabilities = filesystemCapabilities
        self.automaticCleanupRetryDelays = automaticCleanupRetryDelays
        self.drainInitialRetryDelay = drainInitialRetryDelay
        self.drainMaximumRetryDelay = drainMaximumRetryDelay
        self.cleanupRetrySleep = cleanupRetrySleep
        self.diagnosticReporter = diagnosticReporter
    }

    deinit {
        automaticCleanupRetryTask?.cancel()
        drainTask?.cancel()
        for cleanup in pendingPostCommitCleanups {
            if let swappedOut = cleanup.swappedOut {
                _ = Darwin.close(swappedOut.descriptor)
            }
            _ = Darwin.close(cleanup.parentDescriptor)
        }
    }

    func append(text: String, to fileURL: URL) async throws -> MarkdownAppendCommitResult {
        guard lifecycleState == .accepting else {
            throw MarkdownFileAppendError.shuttingDown
        }
        _ = await retryPendingPostCommitCleanups()
        guard lifecycleState == .accepting else {
            throw MarkdownFileAppendError.shuttingDown
        }
        try Task.checkCancellation()
        let parentURL = fileURL.deletingLastPathComponent()
        let targetName = fileURL.lastPathComponent
        guard !targetName.isEmpty, targetName != ".", targetName != ".." else {
            throw MarkdownFileAppendError.unsafeTarget
        }

        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard parentDescriptor >= 0 else {
            throw MarkdownFileAppendError.unsafeParent
        }
        var appendOwnsParentDescriptor = true
        defer {
            if appendOwnsParentDescriptor {
                _ = Darwin.close(parentDescriptor)
            }
        }

        let original = try Self.readOriginalTarget(
            named: targetName,
            parentDescriptor: parentDescriptor,
            openUniqueFlag: filesystemCapabilities.openUniqueFlag
        )
        let originalDescriptor = original?.descriptor ?? -1
        var appendOwnsOriginalDescriptor = originalDescriptor >= 0
        defer {
            if appendOwnsOriginalDescriptor {
                _ = Darwin.close(originalDescriptor)
            }
        }
        let (entryByteCount, entryByteCountOverflow) = text.utf8.count.addingReportingOverflow(1)
        guard !entryByteCountOverflow,
              entryByteCount <= Self.maximumFileByteCount else {
            throw MarkdownFileAppendError.fileTooLarge
        }
        let entryData = Data("\(text)\n".utf8)
        let separatorData = original?.data.isEmpty == false
            ? Data("\n---\n\n".utf8)
            : Data()
        let originalCount = original?.data.count ?? 0
        let (prefixCount, prefixOverflow) = originalCount.addingReportingOverflow(separatorData.count)
        let (finalCount, finalOverflow) = prefixCount.addingReportingOverflow(entryData.count)
        guard !prefixOverflow,
              !finalOverflow,
              finalCount <= Self.maximumFileByteCount else {
            throw MarkdownFileAppendError.fileTooLarge
        }
        var completeData = original?.data ?? Data()
        completeData.append(separatorData)
        completeData.append(entryData)

        let temporaryName = ".rill-markdown-\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = Darwin.openat(
            parentDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw MarkdownFileAppendError.filesystemFailure
        }
        var temporaryExists = true
        defer {
            if temporaryExists {
                _ = Self.removeNameIfItStillReferencesDescriptor(
                    named: temporaryName,
                    descriptor: temporaryDescriptor,
                    parentDescriptor: parentDescriptor,
                    atUniqueFlag: filesystemCapabilities.atUniqueFlag
                )
            }
            if temporaryDescriptor >= 0 {
                _ = Darwin.close(temporaryDescriptor)
            }
        }

        do {
            try payloadWriter.write(completeData, to: temporaryDescriptor)
        } catch {
            throw MarkdownFileAppendError.filesystemFailure
        }
        if let original {
            guard fcopyfile(
                originalDescriptor,
                temporaryDescriptor,
                nil,
                copyfile_flags_t(COPYFILE_METADATA)
            ) == 0 else {
                throw MarkdownFileAppendError.filesystemFailure
            }
            try Self.preserveCreationTime(
                original.status.st_birthtimespec,
                on: temporaryDescriptor
            )
            var updatedTimes = [
                original.status.st_atimespec,
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW)),
            ]
            guard updatedTimes.withUnsafeMutableBufferPointer({ times in
                Darwin.futimens(temporaryDescriptor, times.baseAddress)
            }) == 0 else {
                throw MarkdownFileAppendError.filesystemFailure
            }
        }
        try Self.syncBeforeCommit(temporaryDescriptor)
        var temporaryStatus = stat()
        guard Self.fstatRetryingInterrupts(temporaryDescriptor, status: &temporaryStatus),
              Self.isRegularSingleLinkFile(temporaryStatus),
              temporaryStatus.st_size == off_t(completeData.count) else {
            throw MarkdownFileAppendError.filesystemFailure
        }
        let context = MarkdownAppendTransactionContext(
            parentDescriptor: parentDescriptor,
            targetName: targetName,
            temporaryName: temporaryName
        )
        try hooks.beforePublish(context)
        try Task.checkCancellation()
        try Self.verifyTemporaryTarget(
            named: temporaryName,
            expected: temporaryStatus,
            parentDescriptor: parentDescriptor,
            atUniqueFlag: filesystemCapabilities.atUniqueFlag
        )

        var swappedOutCleanup: PendingSwappedOutCleanup?
        var cleanupIsIndeterminate = false
        if let original {
            try Self.verifyOriginalTarget(
                named: targetName,
                expected: original.status,
                parentDescriptor: parentDescriptor,
                atUniqueFlag: filesystemCapabilities.atUniqueFlag
            )
            let swapResult = renameatx_np(
                parentDescriptor,
                temporaryName,
                parentDescriptor,
                targetName,
                UInt32(RENAME_SWAP) | filesystemCapabilities.renameNoFollowAnyFlag
            )
            guard swapResult == 0 else {
                throw MarkdownFileAppendError.targetChanged
            }
            // The name now refers to the displaced target, not to the private
            // file created above. Never let the generic defer unlink it.
            temporaryExists = false
            try? hooks.afterPublishBeforeVerification(context)

            let swappedOutIsOriginal = Self.nameReferencesDescriptor(
                named: temporaryName,
                descriptor: originalDescriptor,
                parentDescriptor: parentDescriptor,
                atUniqueFlag: filesystemCapabilities.atUniqueFlag
            ) && Self.descriptorMatchesExpectedAfterRename(
                originalDescriptor,
                expected: original.status
            )
            let publishedIsTemporary = Self.nameReferencesDescriptor(
                named: targetName,
                descriptor: temporaryDescriptor,
                parentDescriptor: parentDescriptor,
                atUniqueFlag: filesystemCapabilities.atUniqueFlag
            ) && Self.descriptorMatchesExpectedAfterRename(
                temporaryDescriptor,
                expected: temporaryStatus
            )
            if !publishedIsTemporary {
                // The visible target is not ours. Never exchange it again:
                // it may be a concurrent writer's newer file. Leave both
                // names intact and require inspection before any retry.
                throw MarkdownFileAppendError.publicationIndeterminate
            }

            if swappedOutIsOriginal {
                swappedOutCleanup = PendingSwappedOutCleanup(
                    descriptor: originalDescriptor,
                    expected: original.status
                )
            } else {
                cleanupIsIndeterminate = true
            }
            // Once the visible target is descriptor-verified as our complete
            // replacement, the append is logically committed. A concurrent
            // writer may have moved, replaced, or edited the displaced name;
            // that only makes old-name cleanup indeterminate. Never turn the
            // committed append into a retryable failure, because doing so can
            // duplicate the entry on a user retry.
        } else {
            try Self.verifyTargetIsStillMissing(
                named: targetName,
                parentDescriptor: parentDescriptor
            )
            let renameResult = renameatx_np(
                parentDescriptor,
                temporaryName,
                parentDescriptor,
                targetName,
                UInt32(RENAME_EXCL) | filesystemCapabilities.renameNoFollowAnyFlag
            )
            guard renameResult == 0 else {
                throw MarkdownFileAppendError.targetChanged
            }
            temporaryExists = false
            try? hooks.afterPublishBeforeVerification(context)
            guard Self.nameReferencesDescriptor(
                named: targetName,
                descriptor: temporaryDescriptor,
                parentDescriptor: parentDescriptor,
                atUniqueFlag: filesystemCapabilities.atUniqueFlag
            ), Self.descriptorMatchesExpectedAfterRename(
                temporaryDescriptor,
                expected: temporaryStatus
            ) else {
                throw MarkdownFileAppendError.publicationIndeterminate
            }
        }

        // Publication plus descriptor-bound identity verification is the
        // logical commit point. Cleanup ownership moves to the coordinator so
        // later failure cannot turn a completed append into a retryable result
        // or discard the descriptor needed for identity-safe removal.
        hooks.afterCommit(context)
        let cleanupID = UUID()
        pendingPostCommitCleanups.append(
            PendingPostCommitCleanup(
                id: cleanupID,
                context: context,
                parentDescriptor: parentDescriptor,
                swappedOut: swappedOutCleanup,
                didReportPending: false
            )
        )
        cleanupGeneration &+= 1
        appendOwnsParentDescriptor = false
        if swappedOutCleanup != nil {
            appendOwnsOriginalDescriptor = false
        }
        if cleanupIsIndeterminate {
            await diagnosticReporter(
                MarkdownPostCommitCleanupDiagnostic(outcome: .indeterminate)
            )
        }
        let cleanupDiagnostic = attemptPendingPostCommitCleanup(id: cleanupID)
        if let cleanupDiagnostic {
            await diagnosticReporter(cleanupDiagnostic)
        }
        guard pendingPostCommitCleanups.contains(where: { $0.id == cleanupID }) else {
            return cleanupIsIndeterminate ? .committedCleanupIndeterminate : .committed
        }
        scheduleAutomaticCleanupRetryIfNeeded()
        return .committedCleanupPending
    }

    @discardableResult
    func retryPendingPostCommitCleanups() async -> Int {
        let cleanupIDs = pendingPostCommitCleanups.map(\.id)
        var diagnostics: [MarkdownPostCommitCleanupDiagnostic] = []
        for cleanupID in cleanupIDs {
            if let diagnostic = attemptPendingPostCommitCleanup(id: cleanupID) {
                diagnostics.append(diagnostic)
            }
        }
        for diagnostic in diagnostics {
            await diagnosticReporter(diagnostic)
        }
        return pendingPostCommitCleanups.count
    }

    var pendingPostCommitCleanupCount: Int {
        pendingPostCommitCleanups.count
    }

    private struct PendingSwappedOutCleanup {
        let descriptor: Int32
        let expected: stat
    }

    private struct PendingPostCommitCleanup {
        let id: UUID
        let context: MarkdownAppendTransactionContext
        let parentDescriptor: Int32
        var swappedOut: PendingSwappedOutCleanup?
        var didReportPending: Bool
    }

    private func attemptPendingPostCommitCleanup(
        id: UUID
    ) -> MarkdownPostCommitCleanupDiagnostic? {
        guard let index = pendingPostCommitCleanups.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var cleanup = pendingPostCommitCleanups[index]
        if let swappedOut = cleanup.swappedOut {
            do {
                try hooks.beforeSwappedOutCleanup(cleanup.context)
            } catch {
                return markCleanupPending(at: index)
            }
            guard Self.descriptorMatchesExpectedAfterRename(
                swappedOut.descriptor,
                expected: swappedOut.expected
            ), Self.removeNameIfItStillReferencesDescriptor(
                named: cleanup.context.temporaryName,
                descriptor: swappedOut.descriptor,
                parentDescriptor: cleanup.parentDescriptor,
                atUniqueFlag: filesystemCapabilities.atUniqueFlag
            ) else {
                return markCleanupPending(at: index)
            }
            _ = Darwin.close(swappedOut.descriptor)
            cleanup.swappedOut = nil
            pendingPostCommitCleanups[index] = cleanup
        }
        do {
            try hooks.beforeParentDirectorySync(cleanup.context)
        } catch {
            return markCleanupPending(at: index)
        }
        guard Self.syncDirectoryAfterCommit(cleanup.parentDescriptor) else {
            return markCleanupPending(at: index)
        }
        let didReportPending = cleanup.didReportPending
        _ = Darwin.close(cleanup.parentDescriptor)
        pendingPostCommitCleanups.remove(at: index)
        return didReportPending
            ? MarkdownPostCommitCleanupDiagnostic(outcome: .completedAfterRetry)
            : nil
    }

    private func markCleanupPending(
        at index: Int
    ) -> MarkdownPostCommitCleanupDiagnostic? {
        guard pendingPostCommitCleanups.indices.contains(index),
              !pendingPostCommitCleanups[index].didReportPending else {
            return nil
        }
        pendingPostCommitCleanups[index].didReportPending = true
        return MarkdownPostCommitCleanupDiagnostic(outcome: .retryPending)
    }

    private func scheduleAutomaticCleanupRetryIfNeeded() {
        guard lifecycleState == .accepting,
              automaticCleanupRetryTask == nil,
              !pendingPostCommitCleanups.isEmpty,
              !automaticCleanupRetryDelays.isEmpty else {
            return
        }
        let delays = automaticCleanupRetryDelays
        let scheduledGeneration = cleanupGeneration
        automaticCleanupRetryTask = Task.detached { [weak self] in
            for delay in delays {
                do {
                    try await ContinuousClock().sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.retryPendingPostCommitCleanups() == 0 {
                    break
                }
            }
            await self?.automaticCleanupRetryFinished(
                scheduledGeneration: scheduledGeneration
            )
        }
    }

    private func automaticCleanupRetryFinished(scheduledGeneration: UInt64) {
        automaticCleanupRetryTask = nil
        if lifecycleState == .accepting,
           cleanupGeneration != scheduledGeneration {
            scheduleAutomaticCleanupRetryIfNeeded()
        }
    }

    /// Stops accepting new append transactions. Existing logical commits and
    /// their cleanup ownership remain intact for the shutdown drain.
    public func seal() {
        guard lifecycleState == .accepting else { return }
        lifecycleState = .sealed
        automaticCleanupRetryTask?.cancel()
        automaticCleanupRetryTask = nil
    }

    /// Seals the coordinator and waits until every committed append has either
    /// removed its displaced file and synced the parent directory. This drain
    /// deliberately outlives caller cancellation; the app termination layer
    /// cancels the quit request rather than abandoning user content cleanup.
    public func sealAndDrain() async {
        seal()
        if let drainTask {
            await drainTask.value
            return
        }
        guard !pendingPostCommitCleanups.isEmpty else {
            lifecycleState = .drained
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDrain()
        }
        drainTask = task
        await task.value
    }

    private func performDrain() async {
        var retryDelay = drainInitialRetryDelay
        while await retryPendingPostCommitCleanups() > 0 {
            let delay = retryDelay
            let sleep = cleanupRetrySleep
            await Task.detached {
                do {
                    try await sleep(delay)
                } catch {
                    try? await Task.sleep(for: delay)
                }
            }.value
            retryDelay = min(retryDelay * 2, drainMaximumRetryDelay)
        }
        lifecycleState = .drained
        drainTask = nil
    }

    private struct OriginalTarget {
        let status: stat
        let data: Data
        let descriptor: Int32
    }

    private static func readOriginalTarget(
        named targetName: String,
        parentDescriptor: Int32,
        openUniqueFlag: Int32
    ) throws -> OriginalTarget? {
        let descriptor = Darwin.openat(
            parentDescriptor,
            targetName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | openUniqueFlag
        )
        if descriptor < 0 {
            let status = errno
            if status == ENOENT {
                return nil
            }
            if status == ELOOP || status == ENOTCAPABLE || status == EMLINK {
                throw MarkdownFileAppendError.unsafeTarget
            }
            throw MarkdownFileAppendError.filesystemFailure
        }
        var descriptorToClose = descriptor
        defer {
            if descriptorToClose >= 0 {
                _ = Darwin.close(descriptorToClose)
            }
        }

        var before = stat()
        guard fstatRetryingInterrupts(descriptor, status: &before),
              isRegularSingleLinkFile(before),
              before.st_size >= 0 else {
            throw MarkdownFileAppendError.unsafeTarget
        }
        guard before.st_size <= off_t(maximumFileByteCount) else {
            throw MarkdownFileAppendError.fileTooLarge
        }
        let data = try readBoundedData(
            from: descriptor,
            maximumByteCount: maximumFileByteCount
        )
        guard String(data: data, encoding: .utf8) != nil else {
            throw MarkdownFileAppendError.invalidUTF8
        }
        var after = stat()
        guard fstatRetryingInterrupts(descriptor, status: &after),
              sameIdentityAndContent(after, before) else {
            throw MarkdownFileAppendError.targetChanged
        }
        descriptorToClose = -1
        return OriginalTarget(status: before, data: data, descriptor: descriptor)
    }

    private static func readBoundedData(
        from descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if result > 0 {
                guard data.count <= maximumByteCount - result else {
                    throw MarkdownFileAppendError.fileTooLarge
                }
                data.append(contentsOf: buffer.prefix(result))
                continue
            }
            if result == 0 {
                return data
            }
            if errno == EINTR {
                continue
            }
            throw MarkdownFileAppendError.filesystemFailure
        }
    }

    private static func syncBeforeCommit(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            throw MarkdownFileAppendError.filesystemFailure
        }
    }

    private static func syncDirectoryAfterCommit(_ descriptor: Int32) -> Bool {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            return false
        }
        return true
    }

    private static func preserveCreationTime(
        _ creationTime: timespec,
        on descriptor: Int32
    ) throws {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var timestamp = creationTime
        guard Darwin.fsetattrlist(
            descriptor,
            &attributes,
            &timestamp,
            MemoryLayout<timespec>.size,
            0
        ) == 0 else {
            throw MarkdownFileAppendError.filesystemFailure
        }
    }

    private static func fstatRetryingInterrupts(
        _ descriptor: Int32,
        status: inout stat
    ) -> Bool {
        while Darwin.fstat(descriptor, &status) != 0 {
            if errno == EINTR {
                continue
            }
            return false
        }
        return true
    }

    private static func verifyTemporaryTarget(
        named temporaryName: String,
        expected: stat,
        parentDescriptor: Int32,
        atUniqueFlag: Int32
    ) throws {
        var current = stat()
        guard fstatat(
            parentDescriptor,
            temporaryName,
            &current,
            AT_SYMLINK_NOFOLLOW | atUniqueFlag
        ) == 0,
        sameIdentityAndContent(current, expected) else {
            throw MarkdownFileAppendError.targetChanged
        }
    }

    private static func verifyOriginalTarget(
        named targetName: String,
        expected: stat,
        parentDescriptor: Int32,
        atUniqueFlag: Int32
    ) throws {
        var current = stat()
        guard fstatat(
            parentDescriptor,
            targetName,
            &current,
            AT_SYMLINK_NOFOLLOW | atUniqueFlag
        ) == 0,
        sameIdentityAndContent(current, expected) else {
            throw MarkdownFileAppendError.targetChanged
        }
    }

    private static func verifyTargetIsStillMissing(
        named targetName: String,
        parentDescriptor: Int32
    ) throws {
        var current = stat()
        errno = 0
        guard fstatat(
            parentDescriptor,
            targetName,
            &current,
            AT_SYMLINK_NOFOLLOW
        ) != 0,
        errno == ENOENT else {
            throw MarkdownFileAppendError.targetChanged
        }
    }

    private static func nameReferencesDescriptor(
        named name: String,
        descriptor: Int32,
        parentDescriptor: Int32,
        atUniqueFlag: Int32
    ) -> Bool {
        guard descriptor >= 0 else { return false }
        var descriptorStatus = stat()
        var nameStatus = stat()
        guard fstatRetryingInterrupts(descriptor, status: &descriptorStatus),
              fstatat(
                  parentDescriptor,
                  name,
                  &nameStatus,
                  AT_SYMLINK_NOFOLLOW | atUniqueFlag
              ) == 0,
              isRegularSingleLinkFile(descriptorStatus),
              isRegularSingleLinkFile(nameStatus) else {
            return false
        }
        return descriptorStatus.st_dev == nameStatus.st_dev
            && descriptorStatus.st_ino == nameStatus.st_ino
    }

    private static func descriptorMatchesExpectedAfterRename(
        _ descriptor: Int32,
        expected: stat
    ) -> Bool {
        var current = stat()
        return fstatRetryingInterrupts(descriptor, status: &current)
            && sameIdentityAndContentAfterRename(current, expected)
    }

    @discardableResult
    private static func removeNameIfItStillReferencesDescriptor(
        named name: String,
        descriptor: Int32,
        parentDescriptor: Int32,
        atUniqueFlag: Int32
    ) -> Bool {
        // macOS 14 has no public expected-inode unlink operation. Keep this
        // non-suspending cleanup inside the serialized coordinator, use a
        // random private name, bind it to the held descriptor immediately
        // before removal, and add the kernel's single-link guard where it is
        // available. A mismatch is preserved rather than deleted.
        guard nameReferencesDescriptor(
            named: name,
            descriptor: descriptor,
            parentDescriptor: parentDescriptor,
            atUniqueFlag: atUniqueFlag
        ), Darwin.unlinkat(parentDescriptor, name, atUniqueFlag) == 0 else {
            return false
        }
        var statusAfterUnlink = stat()
        return fstatRetryingInterrupts(descriptor, status: &statusAfterUnlink)
            && statusAfterUnlink.st_nlink == 0
    }

    private static func isRegularSingleLinkFile(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && status.st_nlink == 1
            && status.st_uid == geteuid()
            && status.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0
    }

    private static func sameIdentityAndContent(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameIdentityAndContentAfterRename(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_flags == rhs.st_flags
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

private enum MarkdownFileAppendError: LocalizedError {
    case fileTooLarge
    case filesystemFailure
    case invalidUTF8
    case publicationIndeterminate
    case shuttingDown
    case unsafeParent
    case unsafeTarget
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Markdown append target exceeds the supported 64 MiB transaction limit."
        case .filesystemFailure:
            return "Markdown append could not complete its private file transaction."
        case .invalidUTF8:
            return "Markdown append target must contain valid UTF-8 text."
        case .publicationIndeterminate:
            return "Markdown append publication could not be verified; inspect the target before retrying."
        case .shuttingDown:
            return "Markdown append is unavailable while Rill is shutting down."
        case .unsafeParent:
            return "Markdown append parent directory must already exist and cannot contain symbolic links."
        case .unsafeTarget:
            return "Markdown append target must be a single-link regular file and cannot be a symbolic link."
        case .targetChanged:
            return "Markdown append target changed before it could be written safely."
        }
    }
}

enum ExternalOutputActionError: LocalizedError, Equatable, Sendable {
    case invalidWebhookHeaders
    case shortcutFailed(String?)
    case shortcutTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidWebhookHeaders:
            return "Webhook headers must be a JSON object with string values."
        case .shortcutFailed(let message):
            return message.map { "Shortcuts failed: \($0)" } ?? "Shortcuts failed."
        case .shortcutTimedOut:
            return "Shortcuts timed out."
        }
    }
}

private extension Optional where Wrapped == String {
    var trimmingWhitespaceAndNewlines: String? {
        self?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
