import Foundation
import XCTest
@testable import RillCore
@testable import RillPlatform

final class AVAudioCaptureServiceCleanupTests: XCTestCase {
    func testMismatchedEndpointControlFailsBeforeRecorderCreation() async throws {
        let service = AVAudioCaptureService()
        let endpointControl = AudioCaptureEndpointControl(
            runID: UUID(),
            policy: .shortDictation
        )
        let request = AudioCaptureRequest(
            runID: UUID(),
            workflow: WorkflowDefinition(
                name: "Mismatched endpoint control",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "sherpa-onnx.local",
                    outputActions: []
                ),
                ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
            ),
            endpointControl: endpointControl
        )

        do {
            try await service.startCapture(request)
            XCTFail("A mismatched endpoint control must fail closed.")
        } catch let error as AVAudioCaptureService.CaptureError {
            XCTAssertEqual(error, .invalidEndpointControl)
        }

        let stream = try XCTUnwrap(endpointControl.claimStream())
        var iterator = stream.makeAsyncIterator()
        let signal = await iterator.next()
        XCTAssertNil(signal)
    }

    func testShutdownPermanentlyRejectsLaterCaptureStarts() async {
        let service = AVAudioCaptureService()
        await service.shutdown()
        let request = AudioCaptureRequest(
            runID: UUID(),
            workflow: WorkflowDefinition(
                name: "Post-shutdown capture",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "sherpa-onnx.local",
                    outputActions: []
                ),
                ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue")
            )
        )

        do {
            try await service.startCapture(request)
            XCTFail("Shutdown must permanently reject later AVAudioRecorder starts.")
        } catch let error as AVAudioCaptureService.CaptureError {
            XCTAssertEqual(error, .shuttingDown)
        } catch {
            XCTFail("Unexpected post-shutdown error: \(error)")
        }
    }

    func testServiceOwnedFileTransfersToCleanupOwnerAndDrainsBeforeReturning() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-av-cleanup-\(UUID().uuidString).wav")
        try Data([0x01, 0x02]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let probe = AVAudioCleanupHandoffProbe()
        let owner = ManagedTemporaryAudioCleanupOwner(
            removal: { try await probe.remove($0) }
        )
        let service = AVAudioCaptureService(cleanupOwner: owner)

        let cleanup = Task {
            await service.removeServiceOwnedFile(fileURL, runID: UUID())
            await probe.recordCallerReturned()
        }
        await probe.waitUntilRemovalStarted()

        let suspendedSnapshot = await probe.snapshot()
        XCTAssertEqual(suspendedSnapshot.removedURL, fileURL.standardizedFileURL)
        XCTAssertFalse(suspendedSnapshot.callerReturned)
        let pendingBeforeRelease = await owner.pendingCount
        XCTAssertEqual(pendingBeforeRelease, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await probe.releaseRemoval()
        await cleanup.value

        let completedSnapshot = await probe.snapshot()
        XCTAssertTrue(completedSnapshot.callerReturned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let pendingAfterDrain = await owner.pendingCount
        XCTAssertEqual(pendingAfterDrain, 0)
    }
}

private actor AVAudioCleanupHandoffProbe {
    private var removalStarted = false
    private var removalReleased = false
    private var removedURL: URL?
    private var callerReturned = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func remove(_ fileURL: URL) async throws {
        removedURL = fileURL.standardizedFileURL
        removalStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !removalReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    func waitUntilRemovalStarted() async {
        guard !removalStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseRemoval() {
        removalReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func recordCallerReturned() {
        callerReturned = true
    }

    func snapshot() -> (removedURL: URL?, callerReturned: Bool) {
        (removedURL, callerReturned)
    }
}
