import AppKit
import XCTest
@testable import RillApp

private actor TerminationInvocationProbe {
    private typealias CountWaiter = (
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )

    private var counts: [String: Int] = [:]
    private var orderedInvocations: [String] = []
    private var countWaiters: [String: [CountWaiter]] = [:]

    func record(_ name: String) {
        counts[name, default: 0] += 1
        orderedInvocations.append(name)
        let currentCount = counts[name, default: 0]
        let waiters = countWaiters.removeValue(forKey: name) ?? []
        var remainingWaiters: [CountWaiter] = []
        for waiter in waiters {
            if currentCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        if !remainingWaiters.isEmpty {
            countWaiters[name] = remainingWaiters
        }
    }

    func count(for name: String) -> Int {
        counts[name, default: 0]
    }

    func orderedSnapshot() -> [String] {
        orderedInvocations
    }

    func waitUntilCount(for name: String, reaches target: Int) async {
        guard counts[name, default: 0] < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters[name, default: []].append((target, continuation))
        }
    }
}

private actor TerminationLatch {
    private var isOpen = false
    private var hasWaiter = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var observationContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        hasWaiter = true
        let observations = observationContinuations
        observationContinuations.removeAll()
        for continuation in observations {
            continuation.resume()
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilWaiting() async {
        guard !hasWaiter else { return }
        await withCheckedContinuation { continuation in
            observationContinuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class TerminationReplyProbe {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    func testRepeatedTerminationWaitsForOneCleanupAndRepliesOnce() async {
        let invocations = TerminationInvocationProbe()
        let cleanupLatch = TerminationLatch()
        let replies = TerminationReplyProbe()
        let coordinator = ApplicationTerminationCoordinator(
            timeout: .seconds(30),
            cleanupOperation: {
                await invocations.record("cleanup")
                await cleanupLatch.wait()
            }
        )

        XCTAssertEqual(
            coordinator.beginTermination(reply: replies.record),
            .terminateLater
        )
        XCTAssertEqual(
            coordinator.beginTermination { _ in
                XCTFail("A repeated termination request must not replace the pending reply.")
            },
            .terminateLater
        )

        await waitUntil {
            await invocations.count(for: "cleanup") == 1
        }
        XCTAssertTrue(replies.values.isEmpty)

        await cleanupLatch.open()
        await waitUntil { replies.values == [true] }

        XCTAssertEqual(
            coordinator.beginTermination { _ in
                XCTFail("A completed termination must not request another deferred reply.")
            },
            .terminateNow
        )
        let cleanupCount = await invocations.count(for: "cleanup")
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(replies.values, [true])
    }

    func testTimeoutKeepsQuitPendingUntilRequiredCleanupFinishes() async {
        let invocations = TerminationInvocationProbe()
        let cleanupLatch = TerminationLatch()
        let replies = TerminationReplyProbe()
        let coordinator = ApplicationTerminationCoordinator(
            timeout: .zero,
            cleanupOperation: {
                await invocations.record("cleanup")
                await cleanupLatch.wait()
                await invocations.record(
                    Task.isCancelled ? "cleanup-cancelled" : "cleanup-continued"
                )
            },
            sleep: { _ in }
        )

        XCTAssertEqual(
            coordinator.beginTermination(reply: replies.record),
            .terminateLater
        )
        await waitUntil { coordinator.hasExceededCleanupDeadline }
        XCTAssertTrue(replies.values.isEmpty)

        XCTAssertEqual(
            coordinator.beginTermination { _ in
                XCTFail("A repeated quit must not replace the pending termination reply.")
            },
            .terminateLater
        )

        await cleanupLatch.open()
        await waitUntil {
            await invocations.count(for: "cleanup") == 1
        }
        await waitUntil {
            await invocations.count(for: "cleanup-continued") == 1
        }
        await waitUntil { replies.values == [true] }
        let cancelledCleanupCount = await invocations.count(for: "cleanup-cancelled")
        XCTAssertEqual(cancelledCleanupCount, 0)
        await waitUntil {
            coordinator.beginTermination { _ in
                XCTFail("Completed cleanup must allow immediate termination.")
            } == .terminateNow
        }

        XCTAssertEqual(replies.values, [true])
    }

    func testApplicationShutdownRunsEveryCleanupOperation() async {
        let invocations = TerminationInvocationProbe()
        let deepgramTestLatch = TerminationLatch()
        let recoveryRetryLatch = TerminationLatch()
        let historyMaintenanceLatch = TerminationLatch()
        let preparationLatch = TerminationLatch()
        let eventListenerLatch = TerminationLatch()
        let persistenceLatch = TerminationLatch()
        let shutdown = ApplicationShutdownOperation.make(
            cancelRecording: {
                await invocations.record("recording")
            },
            cancelWorkflowRun: {
                await invocations.record("workflow")
            },
            cancelFailedAudioRecoveryRetries: {
                await invocations.record("audio-recovery")
                await recoveryRetryLatch.wait()
            },
            stopLocalHistoryMaintenance: {
                await invocations.record("history-maintenance")
                await historyMaintenanceLatch.wait()
            },
            shutdownAudioQueue: {
                await invocations.record("audio-queue")
            },
            cancelDeepgramTest: {
                await invocations.record("deepgram-test")
                await deepgramTestLatch.wait()
            },
            drainTextInjectionClipboardRecovery: {
                await invocations.record("text-injection-clipboard")
            },
            stopStackPaste: {
                await invocations.record("stack")
            },
            stopClipboardGroupScheduler: {
                await invocations.record("group-scheduler")
            },
            stopLocalSpeechPreparation: {
                await invocations.record("preparation")
                await preparationLatch.wait()
            },
            stopEventListener: {
                await invocations.record("event-listener")
                await eventListenerLatch.wait()
            },
            flushPersistence: {
                await invocations.record("persistence")
                await persistenceLatch.wait()
            }
        )

        let shutdownTask = Task {
            await shutdown()
            await invocations.record("shutdown-complete")
        }
        await deepgramTestLatch.waitUntilWaiting()
        await recoveryRetryLatch.waitUntilWaiting()
        await historyMaintenanceLatch.waitUntilWaiting()
        await invocations.waitUntilCount(for: "recording", reaches: 1)
        await invocations.waitUntilCount(for: "workflow", reaches: 1)
        await invocations.waitUntilCount(for: "audio-queue", reaches: 1)

        let recordingCount = await invocations.count(for: "recording")
        let workflowCount = await invocations.count(for: "workflow")
        let recoveryRetryCount = await invocations.count(for: "audio-recovery")
        let historyMaintenanceCount = await invocations.count(for: "history-maintenance")
        let audioQueueCount = await invocations.count(for: "audio-queue")
        let deepgramTestCount = await invocations.count(for: "deepgram-test")
        let textInjectionClipboardCount = await invocations.count(
            for: "text-injection-clipboard"
        )
        let stackCount = await invocations.count(for: "stack")
        let groupSchedulerCount = await invocations.count(for: "group-scheduler")
        let preparationCount = await invocations.count(for: "preparation")
        let eventListenerCount = await invocations.count(for: "event-listener")
        let persistenceCount = await invocations.count(for: "persistence")
        XCTAssertEqual(recordingCount, 1)
        XCTAssertEqual(workflowCount, 1)
        XCTAssertEqual(recoveryRetryCount, 1)
        XCTAssertEqual(historyMaintenanceCount, 1)
        XCTAssertEqual(audioQueueCount, 1)
        XCTAssertEqual(deepgramTestCount, 1)
        XCTAssertEqual(textInjectionClipboardCount, 0)
        XCTAssertEqual(stackCount, 0)
        XCTAssertEqual(
            groupSchedulerCount,
            0,
            "The scheduler must remain attached until every producer has stopped."
        )
        XCTAssertEqual(
            persistenceCount,
            0,
            "Persistence must flush only after every producer and scheduler has stopped."
        )
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(eventListenerCount, 0)
        let incompleteShutdownCount = await invocations.count(for: "shutdown-complete")
        XCTAssertEqual(incompleteShutdownCount, 0)

        await deepgramTestLatch.open()
        await Task.yield()
        let schedulerCountWhileRecoveryWasBlocked = await invocations.count(
            for: "group-scheduler"
        )
        XCTAssertEqual(
            schedulerCountWhileRecoveryWasBlocked,
            0,
            "Event draining must wait for decrypted recovery audio cleanup."
        )
        await recoveryRetryLatch.open()
        await Task.yield()
        let schedulerCountWhileHistoryMaintenanceWasBlocked = await invocations.count(
            for: "group-scheduler"
        )
        XCTAssertEqual(
            schedulerCountWhileHistoryMaintenanceWasBlocked,
            0,
            "Event draining must wait for in-flight history maintenance."
        )
        await historyMaintenanceLatch.open()
        await eventListenerLatch.waitUntilWaiting()
        let producerDrainOrder = await invocations.orderedSnapshot()
        let textInjectionDrainIndex = producerDrainOrder.firstIndex(
            of: "text-injection-clipboard"
        )
        let stackStopIndex = producerDrainOrder.firstIndex(of: "stack")
        XCTAssertNotNil(textInjectionDrainIndex)
        XCTAssertNotNil(stackStopIndex)
        if let textInjectionDrainIndex, let stackStopIndex {
            XCTAssertLessThan(textInjectionDrainIndex, stackStopIndex)
        }
        let schedulerCountBeforeListenerRelease = await invocations.count(for: "group-scheduler")
        let preparationCountBeforeListenerRelease = await invocations.count(for: "preparation")
        let eventListenerCountBeforeRelease = await invocations.count(for: "event-listener")
        let persistenceCountBeforeListenerRelease = await invocations.count(for: "persistence")
        let shutdownCountBeforeFlush = await invocations.count(for: "shutdown-complete")
        XCTAssertEqual(schedulerCountBeforeListenerRelease, 1)
        XCTAssertEqual(preparationCountBeforeListenerRelease, 0)
        XCTAssertEqual(eventListenerCountBeforeRelease, 1)
        XCTAssertEqual(persistenceCountBeforeListenerRelease, 0)
        XCTAssertEqual(shutdownCountBeforeFlush, 0)

        await eventListenerLatch.open()
        await persistenceLatch.waitUntilWaiting()
        let eventListenerCountBeforeFlush = await invocations.count(for: "event-listener")
        let persistenceCountBeforeRelease = await invocations.count(for: "persistence")
        let preparationCountBeforeFlush = await invocations.count(for: "preparation")
        XCTAssertEqual(eventListenerCountBeforeFlush, 1)
        XCTAssertEqual(persistenceCountBeforeRelease, 1)
        XCTAssertEqual(preparationCountBeforeFlush, 0)

        await persistenceLatch.open()
        await preparationLatch.waitUntilWaiting()
        let preparationCountBeforeRelease = await invocations.count(for: "preparation")
        let shutdownCountBeforePreparationRelease = await invocations.count(for: "shutdown-complete")
        XCTAssertEqual(preparationCountBeforeRelease, 1)
        XCTAssertEqual(shutdownCountBeforePreparationRelease, 0)

        await preparationLatch.open()
        await shutdownTask.value
        let completedGroupSchedulerCount = await invocations.count(for: "group-scheduler")
        let completedTextInjectionClipboardCount = await invocations.count(
            for: "text-injection-clipboard"
        )
        let completedStackCount = await invocations.count(for: "stack")
        let completedPreparationCount = await invocations.count(for: "preparation")
        let completedEventListenerCount = await invocations.count(for: "event-listener")
        let completedPersistenceCount = await invocations.count(for: "persistence")
        let completedShutdownCount = await invocations.count(for: "shutdown-complete")
        XCTAssertEqual(completedGroupSchedulerCount, 1)
        XCTAssertEqual(completedTextInjectionClipboardCount, 1)
        XCTAssertEqual(completedStackCount, 1)
        XCTAssertEqual(completedPreparationCount, 1)
        XCTAssertEqual(completedEventListenerCount, 1)
        XCTAssertEqual(completedPersistenceCount, 1)
        XCTAssertEqual(completedShutdownCount, 1)
    }

    func testApplicationShutdownSealsThenDrainsMutationsBeforeDownstreamBarriers() async {
        let invocations = TerminationInvocationProbe()
        let startupLatch = TerminationLatch()
        let settingsReadLatch = TerminationLatch()
        let mutationDrainLatch = TerminationLatch()
        let producerLatch = TerminationLatch()
        let shutdown = ApplicationShutdownOperation.make(
            sealClipboardMutations: {
                await invocations.record("seal-mutations")
            },
            stopStartupTasks: {
                await invocations.record("stop-startup")
                await startupLatch.wait()
            },
            stopSettingsReads: {
                await invocations.record("stop-settings-reads")
                await settingsReadLatch.wait()
            },
            drainClipboardMutations: {
                await invocations.record("drain-mutations")
                await mutationDrainLatch.wait()
            },
            cancelRecording: {
                await invocations.record("stop-producer")
                await producerLatch.wait()
            },
            cancelWorkflowRun: {},
            cancelFailedAudioRecoveryRetries: {},
            stopLocalHistoryMaintenance: {},
            shutdownAudioQueue: {},
            cancelDeepgramTest: {},
            stopStackPaste: {},
            stopClipboardGroupScheduler: {
                await invocations.record("stop-scheduler")
            },
            stopLocalSpeechPreparation: {
                await invocations.record("unload-whisper")
            },
            stopEventListener: {
                await invocations.record("stop-listener")
            },
            flushPersistence: {
                await invocations.record("flush-persistence")
            }
        )

        let shutdownTask = Task { await shutdown() }
        await startupLatch.waitUntilWaiting()
        await settingsReadLatch.waitUntilWaiting()
        let startupOrder = await invocations.orderedSnapshot()
        XCTAssertEqual(startupOrder.first, "seal-mutations")
        XCTAssertTrue(startupOrder.contains("stop-startup"))
        XCTAssertTrue(startupOrder.contains("stop-settings-reads"))
        XCTAssertFalse(startupOrder.contains("drain-mutations"))
        XCTAssertFalse(startupOrder.contains("stop-producer"))

        await startupLatch.open()
        await Task.yield()
        let producerCountWhileSettingsReadsAreBlocked = await invocations.count(
            for: "stop-producer"
        )
        XCTAssertEqual(producerCountWhileSettingsReadsAreBlocked, 0)

        await settingsReadLatch.open()
        await mutationDrainLatch.waitUntilWaiting()
        await producerLatch.waitUntilWaiting()
        let schedulerCountWhileProducersAreActive = await invocations.count(for: "stop-scheduler")
        XCTAssertEqual(schedulerCountWhileProducersAreActive, 0)

        await producerLatch.open()
        await Task.yield()
        let schedulerCountWhileMutationsAreDraining = await invocations.count(
            for: "stop-scheduler"
        )
        XCTAssertEqual(
            schedulerCountWhileMutationsAreDraining,
            0,
            "The scheduler must not stop while an accepted clipboard mutation is still draining."
        )

        await mutationDrainLatch.open()
        await shutdownTask.value

        let order = await invocations.orderedSnapshot()
        let index: (String) -> Int = { name in
            order.firstIndex(of: name) ?? Int.max
        }
        XCTAssertLessThan(index("seal-mutations"), index("stop-startup"))
        XCTAssertLessThan(index("seal-mutations"), index("stop-settings-reads"))
        XCTAssertLessThan(index("stop-startup"), index("drain-mutations"))
        XCTAssertLessThan(index("stop-settings-reads"), index("drain-mutations"))
        XCTAssertLessThan(index("stop-startup"), index("stop-producer"))
        XCTAssertLessThan(index("stop-settings-reads"), index("stop-producer"))
        XCTAssertLessThan(index("drain-mutations"), index("stop-scheduler"))
        XCTAssertLessThan(index("stop-producer"), index("stop-scheduler"))
        XCTAssertLessThan(index("stop-scheduler"), index("stop-listener"))
        XCTAssertLessThan(index("stop-listener"), index("flush-persistence"))
        XCTAssertLessThan(index("flush-persistence"), index("unload-whisper"))
    }

    func testApplicationShutdownSealsAndDrainsMarkdownBeforeEventAndPersistenceBarriers() async {
        let invocations = TerminationInvocationProbe()
        let markdownDrainLatch = TerminationLatch()
        let shutdown = ApplicationShutdownOperation.make(
            sealMarkdownPostCommitCleanups: {
                await invocations.record("seal-markdown")
            },
            cancelRecording: {},
            cancelWorkflowRun: {},
            cancelFailedAudioRecoveryRetries: {},
            stopLocalHistoryMaintenance: {},
            shutdownAudioQueue: {},
            cancelDeepgramTest: {},
            stopStackPaste: {},
            stopClipboardGroupScheduler: {
                await invocations.record("stop-scheduler")
            },
            drainMarkdownPostCommitCleanups: {
                await invocations.record("drain-markdown")
                await markdownDrainLatch.wait()
            },
            stopLocalSpeechPreparation: {
                await invocations.record("unload-whisper")
            },
            stopEventListener: {
                await invocations.record("stop-listener")
            },
            flushPersistence: {
                await invocations.record("flush-persistence")
            }
        )

        let shutdownTask = Task { await shutdown() }
        await markdownDrainLatch.waitUntilWaiting()

        let blockedOrder = await invocations.orderedSnapshot()
        XCTAssertEqual(
            blockedOrder,
            ["seal-markdown", "stop-scheduler", "drain-markdown"]
        )
        let listenerCountWhileMarkdownWasBlocked = await invocations.count(for: "stop-listener")
        let persistenceCountWhileMarkdownWasBlocked = await invocations.count(
            for: "flush-persistence"
        )
        XCTAssertEqual(listenerCountWhileMarkdownWasBlocked, 0)
        XCTAssertEqual(persistenceCountWhileMarkdownWasBlocked, 0)

        await markdownDrainLatch.open()
        await shutdownTask.value

        let order = await invocations.orderedSnapshot()
        let index: (String) -> Int = { name in
            order.firstIndex(of: name) ?? Int.max
        }
        XCTAssertLessThan(index("seal-markdown"), index("stop-scheduler"))
        XCTAssertLessThan(index("stop-scheduler"), index("drain-markdown"))
        XCTAssertLessThan(index("drain-markdown"), index("stop-listener"))
        XCTAssertLessThan(index("stop-listener"), index("flush-persistence"))
        XCTAssertLessThan(index("flush-persistence"), index("unload-whisper"))
    }

    private func waitUntil(
        attempts: Int = 200,
        _ predicate: () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("The asynchronous condition did not become true.")
    }
}
