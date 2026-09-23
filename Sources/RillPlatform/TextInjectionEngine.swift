import AppKit
import ApplicationServices
import Foundation
import RillCore

public actor TextInjectionEngine {
    @TaskLocal private static var diagnosticRunID: UUID?

    static let maximumKeyboardEventLength = 20
    private static let clipboardSettleDelay: Duration = .milliseconds(100)
    private static let focusRestoreSettleDelay: Duration = .milliseconds(180)
    private static let postPasteSettleDelay: Duration = .milliseconds(800)

    public enum InjectionMethod: Sendable {
        case clipboardPaste
        case keyboard
    }

    /// The minimum identity needed to prove that generated input is still
    /// addressed to the application that requested it.
    public struct FocusIdentity: Sendable, Equatable {
        public let bundleIdentifier: String?
        public let processIdentifier: Int32?

        public init(bundleIdentifier: String?, processIdentifier: Int32?) {
            self.bundleIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
            self.processIdentifier = processIdentifier
        }

        fileprivate init(_ snapshot: FocusSnapshot) {
            self.init(
                bundleIdentifier: snapshot.bundleIdentifier,
                processIdentifier: snapshot.processIdentifier
            )
        }

        fileprivate var isVerifiable: Bool {
            bundleIdentifier != nil || processIdentifier != nil
        }

        fileprivate func matches(_ current: FocusIdentity?) -> Bool {
            guard isVerifiable, let current else { return false }
            if let processIdentifier,
               current.processIdentifier != processIdentifier {
                return false
            }
            if let bundleIdentifier,
               current.bundleIdentifier != bundleIdentifier {
                return false
            }
            return true
        }
    }

    /// Separates target-focus policy from AppKit so focus restoration and
    /// verification remain deterministic in tests.
    public struct FocusController: Sendable {
        private let currentIdentityProvider: @Sendable () async -> FocusIdentity?
        private let targetActivator: @Sendable (FocusIdentity) async -> Bool

        public init(
            currentIdentity: @escaping @Sendable () async -> FocusIdentity?,
            activate: @escaping @Sendable (FocusIdentity) async -> Bool
        ) {
            currentIdentityProvider = currentIdentity
            targetActivator = activate
        }

        fileprivate func currentIdentity() async -> FocusIdentity? {
            await currentIdentityProvider()
        }

        fileprivate func activate(_ target: FocusIdentity) async -> Bool {
            await targetActivator(target)
        }

        public static var system: FocusController {
            FocusController(
                currentIdentity: {
                    await MainActor.run {
                        guard let application = NSWorkspace.shared.frontmostApplication else {
                            return nil
                        }
                        return FocusIdentity(
                            bundleIdentifier: application.bundleIdentifier,
                            processIdentifier: application.processIdentifier
                        )
                    }
                },
                activate: { target in
                    await MainActor.run {
                        let application: NSRunningApplication?
                        if let processIdentifier = target.processIdentifier {
                            let exactApplication = NSRunningApplication(
                                processIdentifier: processIdentifier
                            )
                            if let bundleIdentifier = target.bundleIdentifier,
                               exactApplication?.bundleIdentifier != bundleIdentifier {
                                application = nil
                            } else {
                                application = exactApplication
                            }
                        } else if let bundleIdentifier = target.bundleIdentifier {
                            application = NSWorkspace.shared.runningApplications.first { candidate in
                                candidate.bundleIdentifier == bundleIdentifier && !candidate.isTerminated
                            }
                        } else {
                            application = nil
                        }
                        guard let application, !application.isTerminated else { return false }
                        return application.activate(options: [])
                    }
                }
            )
        }
    }

    public enum InjectionError: Error, LocalizedError, Equatable {
        case accessibilityPermissionRequired
        case unableToCreatePasteEvent
        case unableToCreateKeyboardEvent
        case protectedClipboardCannotBeReplaced
        case clipboardChangedBeforeTemporaryWrite
        case clipboardContentsCannotBePreserved
        case deliveredButClipboardRestorationFailed
        case temporaryClipboardTransactionInProgress
        case targetFocusCannotBeVerified
        case targetFocusActivationFailed
        case targetFocusChanged

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                return "Accessibility permission is required for text injection."
            case .unableToCreatePasteEvent:
                return "Unable to create the paste event for text injection."
            case .unableToCreateKeyboardEvent:
                return "Unable to create keyboard events for text injection."
            case .protectedClipboardCannotBeReplaced:
                return "The current clipboard is protected and cannot be temporarily replaced."
            case .clipboardChangedBeforeTemporaryWrite:
                return "The clipboard changed before temporary text injection could begin."
            case .clipboardContentsCannotBePreserved:
                return "The current clipboard cannot be preserved losslessly for temporary text injection."
            case .deliveredButClipboardRestorationFailed:
                return CommittedOutputFailure
                    .clipboardRestorationFailedAfterInjection
                    .message
            case .temporaryClipboardTransactionInProgress:
                return "Another temporary clipboard injection is still in progress."
            case .targetFocusCannotBeVerified:
                return "The target application identity cannot be verified for text injection."
            case .targetFocusActivationFailed:
                return "The target application could not be activated for text injection."
            case .targetFocusChanged:
                return "The target application lost focus before text injection completed."
            }
        }
    }

    public init(
        pasteboard: SystemClipboardPort,
        accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        diagnosticReporter: (@Sendable (DiagnosticEvent) async -> Void)? = nil,
        focusController: FocusController = .system,
        pasteCommandSender: @escaping @Sendable () async throws -> Bool = {
            await PasteCommandSender.sendWithEventSpacing()
        },
        keyboardChunkSender: (@Sendable ([UInt16]) async -> Bool)? = nil,
        temporaryClipboardRestorer: (@Sendable (
            SystemClipboardPort.TemporaryWriteTransaction,
            Int
        ) async -> SystemClipboardPort.TemporaryRestoreOutcome)? = nil
    ) {
        self.pasteboard = pasteboard
        self.accessibilityChecker = accessibilityChecker
        self.diagnosticReporter = diagnosticReporter
        self.focusController = focusController
        self.pasteCommandSender = pasteCommandSender
        self.keyboardChunkSender = keyboardChunkSender ?? { chunk in
            TextInjectionEngine.postKeyboardChunk(chunk)
        }
        self.temporaryClipboardRestorer = temporaryClipboardRestorer ?? { transaction, expected in
            await pasteboard.restore(transaction, ifChangeCountIs: expected)
        }
    }

    private let pasteboard: SystemClipboardPort
    private let accessibilityChecker: @Sendable () -> Bool
    private let diagnosticReporter: (@Sendable (DiagnosticEvent) async -> Void)?
    private let focusController: FocusController
    private let pasteCommandSender: @Sendable () async throws -> Bool
    private let keyboardChunkSender: @Sendable ([UInt16]) async -> Bool
    private let temporaryClipboardRestorer: @Sendable (
        SystemClipboardPort.TemporaryWriteTransaction,
        Int
    ) async -> SystemClipboardPort.TemporaryRestoreOutcome
    private struct PendingClipboardRecovery: Sendable {
        var transaction: SystemClipboardPort.TemporaryWriteTransaction
        var expectedChangeCount: Int
        var deliveryCompleted: Bool
        var runID: UUID?
    }

    private var isTemporaryClipboardTransactionActive = false
    private var pendingClipboardRecovery: PendingClipboardRecovery?
    private var applicationShutdownStarted = false
    private var clipboardRecoveryDrainActive = false
    private var temporaryTransactionWaiters: [CheckedContinuation<Void, Never>] = []
    private var clipboardRecoveryDrainWaiters: [CheckedContinuation<Void, Never>] = []

    static func utf16Chunks(for text: String, maxLength: Int = maximumKeyboardEventLength) -> [[UInt16]] {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return [] }
        return stride(from: 0, to: utf16.count, by: maxLength).map { offset in
            Array(utf16[offset..<Swift.min(offset + maxLength, utf16.count)])
        }
    }

    public func inject(
        _ text: String,
        method: InjectionMethod = .clipboardPaste,
        targetFocus: FocusSnapshot? = nil,
        runID: UUID? = nil
    ) async throws {
        try await Self.$diagnosticRunID.withValue(runID) {
            try await injectText(text, method: method, targetFocus: targetFocus)
        }
    }

    private func injectText(
        _ text: String,
        method: InjectionMethod = .clipboardPaste,
        targetFocus: FocusSnapshot? = nil
    ) async throws {
        guard !text.isEmpty else { return }
        guard accessibilityChecker() else {
            throw InjectionError.accessibilityPermissionRequired
        }

        switch method {
        case .clipboardPaste:
            try beginTemporaryClipboardTransaction()
            defer { endTemporaryClipboardTransaction() }
            try await recoverPendingClipboardIfNeeded()
            let preparedTarget = try await prepareTargetFocus(targetFocus)
            let descriptor = await pasteboard.currentDescriptor()
            if !descriptor.protections.isEmpty {
                try await injectUsingProtectedClipboardFallback(
                    text,
                    protections: descriptor.protections,
                    target: preparedTarget
                )
                return
            }
            await recordDiagnostic(
                event: "clipboard.inject.text.prepare",
                message: "Preparing clipboard-based text injection.",
                metadata: [
                    "textLength": String(text.count)
                ]
            )
            let transaction: SystemClipboardPort.TemporaryWriteTransaction
            do {
                transaction = try await pasteboard.beginTemporaryWrite(
                    SystemClipboardSnapshot(plainText: text, changeCount: 0),
                    ifChangeCountIs: descriptor.changeCount
                )
            } catch let error as SystemClipboardPort.ConditionalWriteError {
                switch error {
                case let .protectedClipboard(protections):
                    try await injectUsingProtectedClipboardFallback(
                        text,
                        protections: protections,
                        target: preparedTarget
                    )
                    return
                case .changeCountChanged:
                    throw InjectionError.clipboardChangedBeforeTemporaryWrite
                case .unreadableRepresentation, .preservationLimitExceeded:
                    throw InjectionError.clipboardContentsCannotBePreserved
                }
            }
            try await pasteAndRestore(
                transaction,
                target: preparedTarget
            )
        case .keyboard:
            let preparedTarget = try await prepareTargetFocus(targetFocus)
            try await simulateKeyboard(text, target: preparedTarget)
        }
    }

    public func injectClipboardSnapshot(
        _ snapshot: SystemClipboardSnapshot,
        targetFocus: FocusSnapshot? = nil,
        runID: UUID? = nil
    ) async throws {
        try await Self.$diagnosticRunID.withValue(runID) {
            try await injectSnapshot(snapshot, targetFocus: targetFocus)
        }
    }

    private func injectSnapshot(
        _ snapshot: SystemClipboardSnapshot,
        targetFocus: FocusSnapshot? = nil
    ) async throws {
        guard snapshot.hasTransferableContent else { return }
        guard accessibilityChecker() else {
            throw InjectionError.accessibilityPermissionRequired
        }
        try beginTemporaryClipboardTransaction()
        defer { endTemporaryClipboardTransaction() }
        try await recoverPendingClipboardIfNeeded()
        let descriptor = await pasteboard.currentDescriptor()
        guard descriptor.protections.isEmpty else {
            throw InjectionError.protectedClipboardCannotBeReplaced
        }
        let preparedTarget = try await prepareTargetFocus(targetFocus)
        let revalidatedDescriptor = await pasteboard.currentDescriptor()
        guard revalidatedDescriptor.protections.isEmpty else {
            throw InjectionError.protectedClipboardCannotBeReplaced
        }

        await recordDiagnostic(
            event: "clipboard.inject.snapshot.prepare",
            message: "Preparing clipboard snapshot injection.",
            metadata: [
                "plainTextLength": String(snapshot.plainText.count),
                "hasImage": String(snapshot.imagePNGData != nil),
                "fileCount": String(snapshot.fileURLs.count)
            ]
        )
        let transaction: SystemClipboardPort.TemporaryWriteTransaction
        do {
            transaction = try await pasteboard.beginTemporaryWrite(
                snapshot,
                ifChangeCountIs: revalidatedDescriptor.changeCount
            )
        } catch let error as SystemClipboardPort.ConditionalWriteError {
            switch error {
            case .protectedClipboard:
                throw InjectionError.protectedClipboardCannotBeReplaced
            case .changeCountChanged:
                throw InjectionError.clipboardChangedBeforeTemporaryWrite
            case .unreadableRepresentation, .preservationLimitExceeded:
                throw InjectionError.clipboardContentsCannotBePreserved
            }
        }
        try await pasteAndRestore(
            transaction,
            target: preparedTarget
        )
    }

    @discardableResult
    public func pasteCurrentClipboard(targetFocus: FocusSnapshot? = nil) async throws -> Bool {
        try beginTemporaryClipboardTransaction()
        defer { endTemporaryClipboardTransaction() }
        try await recoverPendingClipboardIfNeeded()
        return try await postPasteCommand(targetFocus: targetFocus)
    }

    /// Seals new clipboard deliveries and retains the exact archive until it is
    /// either verified representation-for-representation or an external
    /// change-count winner is observed. Application termination intentionally
    /// waits here; its existing timeout denies a graceful quit without
    /// cancelling this drain.
    public func drainPendingClipboardRecoveryForApplicationShutdown() async {
        applicationShutdownStarted = true
        if clipboardRecoveryDrainActive {
            await withCheckedContinuation { continuation in
                clipboardRecoveryDrainWaiters.append(continuation)
            }
            return
        }
        clipboardRecoveryDrainActive = true
        await waitForTemporaryClipboardTransaction()

        var retryDelay = Duration.milliseconds(25)
        while let pendingClipboardRecovery {
            let outcome = await temporaryClipboardRestorer(
                pendingClipboardRecovery.transaction,
                pendingClipboardRecovery.expectedChangeCount
            )
            switch outcome {
            case .restored, .skippedChangeCount:
                self.pendingClipboardRecovery = nil
            case let .writeFailed(retryChangeCount):
                self.pendingClipboardRecovery?.expectedChangeCount = retryChangeCount
                try? await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(1))
            }
        }

        clipboardRecoveryDrainActive = false
        let waiters = clipboardRecoveryDrainWaiters
        clipboardRecoveryDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    @discardableResult
    private func postPasteCommand(targetFocus: FocusSnapshot? = nil) async throws -> Bool {
        guard accessibilityChecker() else {
            await recordDiagnostic(
                event: "clipboard.inject.paste.blocked",
                message: "Clipboard paste injection was blocked because accessibility permission is missing.",
                level: .error
            )
            throw InjectionError.accessibilityPermissionRequired
        }
        let preparedTarget = try await prepareTargetFocus(targetFocus)
        return try await postPasteCommand(target: preparedTarget)
    }

    @discardableResult
    private func postPasteCommand(target: FocusIdentity?) async throws -> Bool {
        guard accessibilityChecker() else {
            throw InjectionError.accessibilityPermissionRequired
        }
        await recordDiagnostic(
            event: "clipboard.inject.paste.begin",
            message: "Posting Command-V to the current frontmost app.",
            metadata: [
                "eventTap": PasteCommandSender.eventTapName,
                "eventSourceState": PasteCommandSender.eventSourceStateName,
                "targetFocusProvided": String(target != nil),
            ]
        )
        try await verifyTargetFocus(target)
        let dispatchStart = ContinuousClock.now
        try await simulatePaste()
        let settleStart = ContinuousClock.now
        await recordDiagnostic(
            event: "clipboard.inject.paste.posted",
            message: "Paste command posted; target consumption is not observed.",
            metadata: ["pasteDispatchMillis": DiagnosticTiming.milliseconds(since: dispatchStart)]
        )
        // Diagnostic persistence uses the same protection window rather than
        // adding another delay before the full post-paste wait.
        try? await Task.sleep(until: settleStart.advanced(by: Self.postPasteSettleDelay), clock: .continuous)
        await recordDiagnostic(
            event: "clipboard.inject.paste.end",
            message: "Finished waiting after the paste command.",
            metadata: ["pasteSettleMillis": DiagnosticTiming.milliseconds(since: settleStart)]
        )
        return true
    }

    private func simulatePaste() async throws {
        guard try await pasteCommandSender() else {
            throw InjectionError.unableToCreatePasteEvent
        }
    }

    private func beginTemporaryClipboardTransaction() throws {
        guard !applicationShutdownStarted,
              !isTemporaryClipboardTransactionActive
        else {
            throw InjectionError.temporaryClipboardTransactionInProgress
        }
        isTemporaryClipboardTransactionActive = true
    }

    private func endTemporaryClipboardTransaction() {
        isTemporaryClipboardTransactionActive = false
        let waiters = temporaryTransactionWaiters
        temporaryTransactionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTemporaryClipboardTransaction() async {
        guard isTemporaryClipboardTransactionActive else { return }
        await withCheckedContinuation { continuation in
            temporaryTransactionWaiters.append(continuation)
        }
    }

    private func pasteAndRestore(
        _ transaction: SystemClipboardPort.TemporaryWriteTransaction,
        target: FocusIdentity?
    ) async throws {
        do {
            try await settleClipboardBeforePaste()
            try await postPasteCommand(target: target)
        } catch {
            _ = await restorePreservedClipboard(
                transaction,
                expectedChangeCount: transaction.temporaryChangeCount,
                reason: .pasteFailed
            )
            throw error
        }

        let restoreOutcome = await restorePreservedClipboard(
            transaction,
            expectedChangeCount: transaction.temporaryChangeCount,
            reason: .pasteFinished
        )
        if case .writeFailed = restoreOutcome {
            throw InjectionError.deliveredButClipboardRestorationFailed
        }
    }

    private enum SystemClipboardRestoreReason: String {
        case pasteFailed = "paste-failed"
        case pasteFinished = "paste-finished"

        var deliveryCompleted: Bool {
            self == .pasteFinished
        }
    }

    private func restorePreservedClipboard(
        _ transaction: SystemClipboardPort.TemporaryWriteTransaction,
        expectedChangeCount: Int,
        reason: SystemClipboardRestoreReason
    ) async -> SystemClipboardPort.TemporaryRestoreOutcome {
        let initialOutcome = await attemptClipboardRestore(
            transaction,
            expectedChangeCount: expectedChangeCount,
            reason: reason,
            isRetry: false
        )
        guard case let .writeFailed(retryChangeCount) = initialOutcome else {
            pendingClipboardRecovery = nil
            return initialOutcome
        }

        pendingClipboardRecovery = PendingClipboardRecovery(
            transaction: transaction,
            expectedChangeCount: retryChangeCount,
            deliveryCompleted: reason.deliveryCompleted,
            runID: Self.diagnosticRunID
        )
        let retryOutcome = await attemptClipboardRestore(
            transaction,
            expectedChangeCount: retryChangeCount,
            reason: reason,
            isRetry: true
        )
        switch retryOutcome {
        case .restored, .skippedChangeCount:
            pendingClipboardRecovery = nil
        case let .writeFailed(nextRetryChangeCount):
            pendingClipboardRecovery?.expectedChangeCount = nextRetryChangeCount
        }
        return retryOutcome
    }

    private func recoverPendingClipboardIfNeeded() async throws {
        guard let pendingClipboardRecovery else { return }
        let reason: SystemClipboardRestoreReason = pendingClipboardRecovery.deliveryCompleted
            ? .pasteFinished
            : .pasteFailed
        let outcome = await Self.$diagnosticRunID.withValue(pendingClipboardRecovery.runID) {
            await attemptClipboardRestore(
                pendingClipboardRecovery.transaction,
                expectedChangeCount: pendingClipboardRecovery.expectedChangeCount,
                reason: reason,
                isRetry: true
            )
        }
        switch outcome {
        case .restored, .skippedChangeCount:
            self.pendingClipboardRecovery = nil
        case let .writeFailed(retryChangeCount):
            self.pendingClipboardRecovery?.expectedChangeCount = retryChangeCount
            throw InjectionError.temporaryClipboardTransactionInProgress
        }
    }

    private func attemptClipboardRestore(
        _ transaction: SystemClipboardPort.TemporaryWriteTransaction,
        expectedChangeCount: Int,
        reason: SystemClipboardRestoreReason,
        isRetry: Bool
    ) async -> SystemClipboardPort.TemporaryRestoreOutcome {
        let restoreStart = ContinuousClock.now
        let outcome = await temporaryClipboardRestorer(transaction, expectedChangeCount)
        let message: String
        let outcomeName: String
        let level: DiagnosticLevel
        switch outcome {
        case .restored:
            message = "Restored the clipboard after temporary text injection."
            outcomeName = "restored"
            level = .debug
        case .skippedChangeCount:
            message = "Skipped clipboard restoration because the clipboard changed during text injection."
            outcomeName = "skipped-change-count"
            level = .debug
        case .writeFailed:
            message = reason.deliveryCompleted
                ? "Clipboard restoration is pending after content delivery; the original clipboard archive will be retried without repeating delivery."
                : "Clipboard restoration is pending after content delivery was blocked."
            outcomeName = "write-failed"
            level = .error
        }
        var metadata = [
            "outcome": outcomeName,
            "reason": reason.rawValue,
        ]
        if case .writeFailed = outcome {
            metadata["deliveryCompleted"] = String(reason.deliveryCompleted)
            metadata["retrySafe"] = String(!reason.deliveryCompleted)
        }
        metadata["durationMillis"] = DiagnosticTiming.milliseconds(since: restoreStart)
        if isRetry {
            metadata["restoreAttempt"] = "retry"
        }
        await recordDiagnostic(
            event: "clipboard.inject.restore",
            message: message,
            level: level,
            metadata: metadata
        )
        return outcome
    }

    private func simulateKeyboard(_ text: String, target: FocusIdentity?) async throws {
        let chunks = Self.utf16Chunks(for: text)
        guard !chunks.isEmpty else { return }

        for (index, originalChunk) in chunks.enumerated() {
            try await verifyTargetFocus(target)
            guard await keyboardChunkSender(originalChunk) else {
                throw InjectionError.unableToCreateKeyboardEvent
            }

            if index < chunks.count - 1 {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func injectUsingProtectedClipboardFallback(
        _ text: String,
        protections: [SystemClipboardProtection],
        target: FocusIdentity?
    ) async throws {
        await recordDiagnostic(
            event: "clipboard.inject.keyboard-fallback",
            message: "Used keyboard injection to preserve a protected clipboard.",
            metadata: [
                "protections": protections.map(\.rawValue).joined(separator: ",")
            ]
        )
        try await simulateKeyboard(text, target: target)
    }

    private static func postKeyboardChunk(_ originalChunk: [UInt16]) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }

        var chunk = originalChunk
        keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
        keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func settleClipboardBeforePaste() async throws {
        try await Task.sleep(for: Self.clipboardSettleDelay)
    }

    private func prepareTargetFocus(_ targetFocus: FocusSnapshot?) async throws -> FocusIdentity? {
        guard let targetFocus else { return nil }
        let target = FocusIdentity(targetFocus)
        guard target.isVerifiable else {
            await recordFocusFailure(
                event: "clipboard.inject.focus.unverifiable",
                activationAttempted: false,
                activationSucceeded: false
            )
            throw InjectionError.targetFocusCannotBeVerified
        }

        let current = await focusController.currentIdentity()
        if target.matches(current) {
            return target
        }

        let activated = await focusController.activate(target)
        await recordDiagnostic(
            event: activated
                ? "clipboard.inject.focus.activation-requested"
                : "clipboard.inject.focus.activation-failed",
            message: activated
                ? "Requested foreground focus for the app that started voice input."
                : "Could not restore the target app before text injection.",
            metadata: [
                "targetFocusProvided": "true",
                "targetFocusInitiallyMatched": "false",
                "targetFocusActivationAttempted": "true",
                "targetFocusActivationSucceeded": String(activated),
            ]
        )
        guard activated else {
            throw InjectionError.targetFocusActivationFailed
        }
        try await Task.sleep(for: Self.focusRestoreSettleDelay)
        do {
            try await verifyTargetFocus(target)
        } catch {
            throw InjectionError.targetFocusCannotBeVerified
        }
        return target
    }

    private func verifyTargetFocus(_ target: FocusIdentity?) async throws {
        guard let target else { return }
        let current = await focusController.currentIdentity()
        guard target.matches(current) else {
            await recordFocusFailure(
                event: "clipboard.inject.focus.changed",
                activationAttempted: false,
                activationSucceeded: false
            )
            throw InjectionError.targetFocusChanged
        }
    }

    private func recordFocusFailure(
        event: String,
        activationAttempted: Bool,
        activationSucceeded: Bool
    ) async {
        await recordDiagnostic(
            event: event,
            message: "Text injection was blocked because the target app could not be verified.",
            level: .error,
            metadata: [
                "targetFocusProvided": "true",
                "targetFocusActivationAttempted": String(activationAttempted),
                "targetFocusActivationSucceeded": String(activationSucceeded),
                "targetFocusVerified": "false",
            ]
        )
    }

    private func recordDiagnostic(
        event: String,
        message: String,
        level: DiagnosticLevel = .debug,
        metadata: [String: String] = [:]
    ) async {
        guard let diagnosticReporter else { return }
        await diagnosticReporter(
            DiagnosticEvent(
                runID: Self.diagnosticRunID,
                subsystem: .systemClipboard,
                level: level,
                event: event,
                message: message,
                metadata: metadata
            )
        )
    }
}
