import XCTest
@testable import RillApp
@testable import RillCore

private actor RecordPanelPasteProbe {
    struct Snapshot: Sendable {
        var restoredTargets: [FocusedApplicationTargetIdentity] = []
        var currentTarget: FocusedApplicationTargetIdentity?
        var actionTargets: [FocusedApplicationTargetIdentity] = []
        var abortCount = 0
        var shutdownCount = 0
    }

    private var state = Snapshot()

    func restore(
        _ restoredTarget: FocusedApplicationTargetIdentity,
        thenCurrentTarget: FocusedApplicationTargetIdentity
    ) {
        state.restoredTargets.append(restoredTarget)
        state.currentTarget = thenCurrentTarget
    }

    func recordAction(_ target: FocusedApplicationTargetIdentity) {
        state.actionTargets.append(target)
    }

    func recordAbort() {
        state.abortCount += 1
    }

    func recordShutdown() {
        state.shutdownCount += 1
    }

    func snapshot() -> Snapshot {
        state
    }
}

private actor RecordPanelOperationGate {
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
final class RecordPanelControllerTests: XCTestCase {
    func testAttachedSheetSuppressesAutoHideAndOwnsFirstEscape() {
        XCTAssertFalse(
            RecordPanelModalPolicy.shouldAutoHide(
                isVisible: true,
                hasAttachedSheet: true,
                isSuppressed: false
            )
        )
        XCTAssertEqual(
            RecordPanelModalPolicy.escapeDestination(hasAttachedSheet: true),
            .attachedSheet
        )
        XCTAssertEqual(
            RecordPanelModalPolicy.escapeDestination(hasAttachedSheet: false),
            .panel
        )
    }

    func testCancelledFocusLossDelayCannotContinueToAutoHideDecision() async {
        let delayTask = Task {
            await RecordPanelModalPolicy.waitForAutoHideDelay(.seconds(5))
        }

        await Task.yield()
        delayTask.cancel()

        let shouldContinue = await delayTask.value
        XCTAssertFalse(shouldContinue)
    }

    func testPasteCallbackKeepsLockedTargetWhenAnotherAppStealsFocusAfterRestore() async throws {
        let targetA = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.EditorA")
        let targetB = try makeTarget(processIdentifier: 84, bundleIdentifier: "com.example.EditorB")
        let probe = RecordPanelPasteProbe()
        let controller = RecordPanelController(
            pasteTargetProvider: { targetA },
            pasteTargetRestorer: { restoredTarget in
                await probe.restore(restoredTarget, thenCurrentTarget: targetB)
                return true
            }
        )

        controller.useSelectedItem(
            { target in await probe.recordAction(target) },
            onAbort: { await probe.recordAbort() }
        )
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertEqual(result.restoredTargets, [targetA])
        XCTAssertEqual(result.currentTarget, targetB)
        XCTAssertEqual(result.actionTargets, [targetA])
        XCTAssertEqual(result.abortCount, 0)
    }

    func testPasteAbortsBeforeRestorationWhenNoTargetCanBeLocked() async throws {
        let fallback = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let probe = RecordPanelPasteProbe()
        let controller = RecordPanelController(
            pasteTargetProvider: { nil },
            pasteTargetRestorer: { restoredTarget in
                await probe.restore(restoredTarget, thenCurrentTarget: fallback)
                return true
            }
        )

        controller.useSelectedItem(
            { target in await probe.recordAction(target) },
            onAbort: { await probe.recordAbort() }
        )
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertTrue(result.restoredTargets.isEmpty)
        XCTAssertTrue(result.actionTargets.isEmpty)
        XCTAssertEqual(result.abortCount, 1)
    }

    func testPasteAbortsWhenLockedTargetCannotBeRestored() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let probe = RecordPanelPasteProbe()
        let controller = RecordPanelController(
            pasteTargetProvider: { target },
            pasteTargetRestorer: { restoredTarget in
                await probe.restore(restoredTarget, thenCurrentTarget: target)
                return false
            }
        )

        controller.useSelectedItem(
            { actionTarget in await probe.recordAction(actionTarget) },
            onAbort: { await probe.recordAbort() }
        )
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertEqual(result.restoredTargets, [target])
        XCTAssertTrue(result.actionTargets.isEmpty)
        XCTAssertEqual(result.abortCount, 1)
    }

    func testShutdownSealsNewPasteWorkAndDrainsAcceptedTargetRestore() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let probe = RecordPanelPasteProbe()
        let restoreGate = RecordPanelOperationGate()
        let controller = RecordPanelController(
            pasteTargetProvider: { target },
            pasteTargetRestorer: { restoredTarget in
                await probe.restore(restoredTarget, thenCurrentTarget: target)
                await restoreGate.hold()
                return true
            }
        )

        controller.useSelectedItem(
            { actionTarget in await probe.recordAction(actionTarget) },
            onAbort: { await probe.recordAbort() }
        )
        await restoreGate.waitUntilStarted()

        controller.useSelectedItem(
            { actionTarget in await probe.recordAction(actionTarget) },
            onAbort: { await probe.recordAbort() }
        )
        let shutdownTask = Task { @MainActor in
            await controller.shutdown()
        }
        while !controller.isShutdown {
            await Task.yield()
        }
        await restoreGate.release()
        await shutdownTask.value
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertEqual(result.restoredTargets, [target])
        XCTAssertTrue(result.actionTargets.isEmpty)
        XCTAssertEqual(result.abortCount, 2)
    }

    func testReservedPasteRejectsASecondSubmissionAndSettlesBothExactlyOnce() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let probe = RecordPanelPasteProbe()
        let owner = RecordPanelPasteTaskOwner()
        let firstReservation = try XCTUnwrap(
            owner.reserve(
                prepare: { true },
                action: { await probe.recordAction(target) },
                onAbort: { await probe.recordAbort() }
            )
        )

        XCTAssertNil(
            owner.reserve(
                prepare: { true },
                action: { await probe.recordAction(target) },
                onAbort: { await probe.recordAbort() }
            )
        )
        owner.start(firstReservation)
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertEqual(result.actionTargets, [target])
        XCTAssertEqual(result.abortCount, 1)
        await owner.shutdown()
    }

    func testShutdownAbortsAnAnimationWindowReservationExactlyOnce() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let probe = RecordPanelPasteProbe()
        let owner = RecordPanelPasteTaskOwner()
        let reservation = try XCTUnwrap(
            owner.reserve(
                prepare: { true },
                action: { await probe.recordAction(target) },
                onAbort: { await probe.recordAbort() }
            )
        )

        await owner.shutdown()
        owner.start(reservation)
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertTrue(result.actionTargets.isEmpty)
        XCTAssertEqual(result.abortCount, 1)
    }

    func testShutdownWaitsForAnActionThatAlreadyStarted() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let probe = RecordPanelPasteProbe()
        let actionGate = RecordPanelOperationGate()
        let owner = RecordPanelPasteTaskOwner()
        let reservation = try XCTUnwrap(
            owner.reserve(
                prepare: { true },
                action: {
                    await actionGate.hold()
                    await probe.recordAction(target)
                },
                onAbort: { await probe.recordAbort() }
            )
        )
        owner.start(reservation)
        await actionGate.waitUntilStarted()

        let shutdownTask = Task { @MainActor in
            await owner.shutdown()
            await probe.recordShutdown()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        var result = await probe.snapshot()
        XCTAssertEqual(result.shutdownCount, 0)

        await actionGate.release()
        await shutdownTask.value
        result = await probe.snapshot()
        XCTAssertEqual(result.actionTargets, [target])
        XCTAssertEqual(result.abortCount, 0)
        XCTAssertEqual(result.shutdownCount, 1)
    }

    private func makeTarget(
        processIdentifier: Int32,
        bundleIdentifier: String
    ) throws -> FocusedApplicationTargetIdentity {
        try XCTUnwrap(
            FocusedApplicationTargetIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    private func waitForPasteWork() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
