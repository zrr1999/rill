import XCTest
@testable import RillCore
@testable import RillUI

private actor ClipboardMutationGate {
    private var enteredCount = 0
    private var isOpen = false
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        enteredCount += 1
        let ready = entryWaiters.filter { enteredCount >= $0.0 }
        entryWaiters.removeAll { enteredCount >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered(_ target: Int) async {
        guard enteredCount < target else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((target, continuation))
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
}

@MainActor
final class AppModelClipboardMutationShutdownTests: XCTestCase {
    func testOwnerSealRejectsNewWorkAndConcurrentDrainsWaitForAcceptedWork() async {
        let owner = AppModelClipboardMutationTaskOwner()
        let gate = ClipboardMutationGate()

        XCTAssertTrue(owner.submit { await gate.wait() })
        XCTAssertTrue(owner.submit { await gate.wait() })
        owner.seal()
        XCTAssertEqual(owner.state, .sealed)
        XCTAssertFalse(owner.submit { XCTFail("A sealed owner must reject new work.") })

        let firstDrain = Task { @MainActor in
            await owner.drainAndStop()
        }
        let secondDrain = Task { @MainActor in
            await owner.drainAndStop()
        }

        await gate.waitUntilEntered(2)
        XCTAssertEqual(owner.state, .draining)
        XCTAssertFalse(firstDrain.isCancelled)
        XCTAssertFalse(secondDrain.isCancelled)

        await gate.open()
        await firstDrain.value
        await secondDrain.value

        XCTAssertEqual(owner.state, .stopped)
        XCTAssertFalse(owner.submit { XCTFail("A stopped owner must reject new work.") })
        await owner.drainAndStop()
        XCTAssertEqual(owner.state, .stopped)
    }

    func testAllClipboardMutationAPIsRejectSynchronouslyAfterShutdownSeal() async {
        let harness = makeHarness()
        let model = harness.model
        let item = ClipboardHistoryItem(
            groupID: ClipboardGroup.defaultGroupID,
            text: "sealed",
            sourceKind: .system
        )
        let entry = ClipboardHistoryEntryBuilder.build(
            from: [item],
            mergeSimilarText: false
        )[0]
        let assignment = ClipboardAppAssignment(
            bundleIdentifier: "com.example.Sealed",
            applicationName: "Sealed"
        )

        model.sealClipboardMutationsForApplicationShutdown()

        XCTAssertFalse(model.deleteClipboardHistoryEntry(entry))
        XCTAssertFalse(model.deleteClipboardItem(item))
        XCTAssertFalse(model.setClipboardMode(.queue, forGroup: ClipboardGroup.defaultGroupID))
        XCTAssertFalse(
            model.setClipboardAllowsCrossGroupPaste(
                true,
                forGroup: ClipboardGroup.defaultGroupID
            )
        )
        XCTAssertFalse(model.createClipboardGroup(named: "Rejected"))
        XCTAssertFalse(model.assignApplication(assignment, toGroup: ClipboardGroup.defaultGroupID))
        XCTAssertFalse(
            model.setClipboardFallbackPriority(9, forGroup: ClipboardGroup.defaultGroupID)
        )
        XCTAssertFalse(model.setClipboardItemTags(["rejected"], forItem: item.id))
        XCTAssertFalse(model.setClipboardHistoryEntryPinned(true, entry: entry))

        await model.drainClipboardMutationsForApplicationShutdown()
        XCTAssertEqual(model.clipboardMutationTaskOwner.state, .stopped)
    }
}
