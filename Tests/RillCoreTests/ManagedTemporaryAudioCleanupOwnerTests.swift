import Foundation
import XCTest
@testable import RillCore

private enum ManagedAudioRemovalProbeError: Error {
    case transient
}

private actor ManagedAudioRemovalProbe {
    private var attempts = 0
    private var diagnostics: [ManagedTemporaryAudioCleanupOwner.Diagnostic] = []

    func remove(_ fileURL: URL) throws {
        attempts += 1
        if attempts == 1 {
            throw ManagedAudioRemovalProbeError.transient
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    func record(_ diagnostic: ManagedTemporaryAudioCleanupOwner.Diagnostic) {
        diagnostics.append(diagnostic)
    }

    func snapshot() -> (
        attempts: Int,
        diagnostics: [ManagedTemporaryAudioCleanupOwner.Diagnostic]
    ) {
        (attempts, diagnostics)
    }
}

private actor ManagedAudioRetryGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

final class ManagedTemporaryAudioCleanupOwnerTests: XCTestCase {
    func testFirstRemovalFailureRetriesWithoutLeakingPathOrPayload() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-cleanup-private-canary-\(UUID().uuidString).wav")
        try Data("private-audio-canary".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let probe = ManagedAudioRemovalProbe()
        let runID = UUID()
        let owner = ManagedTemporaryAudioCleanupOwner(
            removal: { try await probe.remove($0) },
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(1),
            sleep: { _ in },
            diagnosticReporter: { await probe.record($0) }
        )

        let accepted = await owner.transfer(fileURL: fileURL, runID: runID)
        XCTAssertTrue(accepted)
        await owner.drain(runID: runID)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, 2)
        XCTAssertEqual(
            snapshot.diagnostics.map(\.outcome),
            [.retryPending, .completedAfterRetry]
        )
        XCTAssertTrue(snapshot.diagnostics.allSatisfy { $0.runID == runID })
        let diagnosticText = snapshot.diagnostics
            .flatMap { [$0.event, $0.message] }
            .joined(separator: " ")
        XCTAssertFalse(diagnosticText.contains(fileURL.path))
        XCTAssertFalse(diagnosticText.contains("private-audio-canary"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let pendingCount = await owner.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testCallerCancellationDoesNotCancelAcceptedCleanup() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-cleanup-cancellation-\(UUID().uuidString).wav")
        try Data([0x01]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let probe = ManagedAudioRemovalProbe()
        let retryGate = ManagedAudioRetryGate()
        let runID = UUID()
        let owner = ManagedTemporaryAudioCleanupOwner(
            removal: { try await probe.remove($0) },
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(1),
            sleep: { _ in await retryGate.hold() }
        )

        let accepted = await owner.transfer(fileURL: fileURL, runID: runID)
        XCTAssertTrue(accepted)
        await retryGate.waitUntilEntered()
        let caller = Task {
            await owner.drain(runID: runID)
        }
        caller.cancel()
        await retryGate.release()
        await caller.value

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let pendingCount = await owner.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }
}
