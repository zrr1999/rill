import AppKit
import XCTest
@testable import RillApp
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

private actor RecordPanelDeliveryProbe {
    struct Snapshot: Sendable {
        var subjects: [RecordReuseSubject] = []
        var targets: [FocusedApplicationTargetIdentity] = []
    }

    private var state = Snapshot()

    func record(_ subject: RecordReuseSubject, target: FocusedApplicationTargetIdentity) {
        state.subjects.append(subject)
        state.targets.append(target)
    }

    func snapshot() -> Snapshot {
        state
    }
}

private struct RecordPanelDigitTestContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

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
    func testMarkedTextPreventsBothPanelDigitDispatchPathsFromPasting() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let store = RecordStore()
        _ = try await store.ingest(.init(payload: .text("history"), provenance: .init(source: .init(kind: .systemClipboard))), into: [])
        let workspace = RecordWorkspaceModel(store: store)
        let probe = RecordPanelDeliveryProbe()
        let controller = RecordPanelController(
            pasteTargetProvider: { target }, pasteTargetRestorer: { _ in true }, reduceMotionProvider: { true })
        let existingWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
        controller.show(model: makeModel(recordWorkspace: workspace), deliverSelection: { subject, target in
            await probe.record(subject, target: target)
            return .delivered
        }, onDeliveryAbort: {})
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.quickPanelModel?.results.isEmpty != false, ContinuousClock.now < deadline { await Task.yield() }
        let window = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && !existingWindowNumbers.contains($0.windowNumber) })
        window.contentView?.layoutSubtreeIfNeeded()
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        _ = window.performKeyEquivalent(with: event)
        window.keyDown(with: event)
        await waitForPasteWork()
        let marked = await probe.snapshot()
        XCTAssertTrue(marked.subjects.isEmpty)
        XCTAssertTrue(controller.isVisible)
        editor.unmarkText()
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        await waitForPasteWork()
        let unmarked = await probe.snapshot()
        XCTAssertEqual(unmarked.subjects.count, 1)
        await controller.shutdown()
    }

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

    func testDigitShortcutPolicyMapsMainKeyboardDigitsInOrder() {
        // ANSI key codes for 1...9 are not contiguous: 5/6 are swapped, 8 is 28.
        let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, keyCode) in digitKeyCodes.enumerated() {
            XCTAssertEqual(
                RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: keyCode, modifierFlags: .command),
                index,
                "keyCode \(keyCode)"
            )
        }
    }

    func testDigitShortcutPolicyRejectsModifiedAndNonDigitKeys() {
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 18, modifierFlags: []))
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 18, modifierFlags: .shift))
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 18, modifierFlags: .option))
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 18, modifierFlags: .control))
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 24, modifierFlags: [])) // =
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 29, modifierFlags: [])) // 0
        XCTAssertNil(RecordPanelDigitShortcutPolicy.visibleRecordIndex(keyCode: 83, modifierFlags: [])) // numpad 1
    }

    func testDigitSelectionDeliversVisibleRecordThroughTheLockedTarget() async throws {
        let target = try makeTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor")
        let store = RecordStore()
        let projection = try await store.ingest(
            RecordDraft(
                payload: .text("digit deliverable"),
                provenance: RecordProvenance(source: RecordSourceIdentity(kind: .user))
            ),
            into: [RecordCollection.inboxID]
        )
        let workspace = RecordWorkspaceModel(store: store)
        await workspace.refresh()
        let probe = RecordPanelDeliveryProbe()
        let controller = RecordPanelController(
            pasteTargetProvider: { target },
            pasteTargetRestorer: { _ in true },
            reduceMotionProvider: { true }
        )

        controller.show(
            model: makeModel(recordWorkspace: workspace),
            deliverSelection: { subject, actionTarget in
                await probe.record(subject, target: actionTarget)
                return .delivered
            },
            onDeliveryAbort: {}
        )
        for _ in 0..<100 where controller.quickPanelModel?.results.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let handler = try XCTUnwrap(controller.digitSelectionHandler)

        // Only one visible record: index 1 is out of bounds and consumed nothing.
        XCTAssertFalse(handler(1))
        XCTAssertTrue(handler(0))
        await waitForPasteWork()

        let result = await probe.snapshot()
        XCTAssertEqual(result.subjects.map(\.recordID), [projection.id])
        XCTAssertEqual(result.targets, [target])
        await controller.shutdown()
    }

    func testWarmPanelReadyToSearchWithTenThousandRecords() async throws {
        guard ProcessInfo.processInfo.environment["RILL_RECORD_STRESS"] == "1" else {
            throw XCTSkip("Set RILL_RECORD_STRESS=1 to measure native panel presentation with 10,000 summaries.")
        }
        let store = RecordStore(persistence: try await LargePanelCatalogFixture.make())
        let workspace = RecordWorkspaceModel(store: store)
        await workspace.refresh()
        let model = makeModel(recordWorkspace: workspace)
        let controller = RecordPanelController(pasteTargetProvider: { nil }, pasteTargetRestorer: { _ in false }, reduceMotionProvider: { true })
        let existingWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
        var timings: [Double] = []
        for iteration in 0..<31 {
            let started = ContinuousClock.now
            controller.show(model: model, deliverSelection: { _, _ in .delivered }, onDeliveryAbort: {})
            let window = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && !existingWindowNumbers.contains($0.windowNumber) })
            window.contentView?.layoutSubtreeIfNeeded()
            let deadline = started.advanced(by: .seconds(2))
            while controller.quickPanelModel?.results.count != 50, ContinuousClock.now < deadline {
                await Task.yield()
            }
            XCTAssertEqual(controller.quickPanelModel?.results.count, 50)
            XCTAssertTrue(window.firstResponder is NSTextView, "The search field must own keyboard input")
            let elapsed = started.duration(to: .now).components
            if iteration > 0 { timings.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) }
            controller.dismiss()
        }
        await controller.shutdown()
        let p95 = timings.sorted()[28]
        print("RECORD_PANEL_STRESS summaries=10000 warm_ready_p95_ms=\(p95 * 1000)")
        XCTAssertLessThanOrEqual(p95, 0.150)
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

    private func makeModel(recordWorkspace: RecordWorkspaceModel) -> AppModel {
        let eventBus = EventBus()
        let resolver = CandidateResolver(eventBus: eventBus)
        let actionRegistry = OutputActionRegistry(actions: [])
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: actionRegistry,
            candidateResolver: resolver,
            eventBus: eventBus
        )
        return AppModel(
            workflows: [],
            eventBus: eventBus,
            sessionCoordinator: coordinator,
            outputActionRegistry: actionRegistry,
            recordWorkspace: recordWorkspace,
            candidateResolver: resolver,
            loadsPersistentSettingsOnInitialization: false,
            writeClipboardTextAction: { _ in },
            deliverNextRecordAction: {},
            permissionSnapshot: PermissionSnapshot(accessibility: .granted, microphone: .granted),
            refreshPermissionsAction: {},
            requestAccessibilityAction: {},
            requestMicrophoneAction: {},
            openAccessibilitySettingsAction: {},
            openMicrophoneSettingsAction: {}, requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {}
        )
    }

    private func waitForPasteWork() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct LargePanelCatalogFixture: RecordCatalogPersistenceStore {
    let catalog: RecordCatalogRead
    static func make() async throws -> Self {
        let seed = try await RecordStore().catalogSnapshot()
        let encoder = JSONEncoder()
        var nodes: [RecordCatalogNode] = []
        func append<T: Encodable>(_ kind: RecordCatalogNode.Kind, _ id: String, _ value: T) throws {
            nodes.append(.init(kind: kind, id: id, value: try encoder.encode(value)))
        }
        for collection in seed.collections { try append(.collection, collection.id.description, collection) }
        for rule in seed.captureRules { try append(.captureRule, rule.id.description, rule) }
        for rule in seed.deliveryRules { try append(.deliveryRule, rule.id.description, rule) }
        var order: [RecordID] = []
        var references: [RecordGraphPersistenceBlobReference] = []
        for index in 0..<10_000 {
            let record = Record(payload: .text("record"), provenance: .init(source: .init(kind: .systemClipboard)), createdAt: Date(timeIntervalSince1970: Double(index)))
            order.append(record.id)
            try append(.record, record.id.description, RecordHeader(record: record, byteCount: 6))
            try append(.metadata, record.id.description, RecordMetadata(recordID: record.id))
            try append(.activity, record.id.description, RecordActivity(recordID: record.id))
            references.append(.init(blobID: UUID(), recordID: record.id, kind: .text, byteCount: 6))
        }
        return Self(catalog: .init(revision: 1, manifest: .init(nextMembershipOrdinal: 1, recordOrder: order.reversed(), collectionOrder: seed.collections.map(\.id)), nodes: nodes, references: references))
    }
    func loadRecordCatalog() async throws -> RecordCatalogRead? { catalog }
    func loadRecordPayload(_ reference: RecordGraphPersistenceBlobReference) async throws -> Data { Data("record".utf8) }
    func commitRecordCatalog(_ mutation: RecordCatalogMutation) async throws -> Int64 { throw RecordStoreError.persistenceUnavailable }
    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot { .empty }
    func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64 { throw RecordStoreError.persistenceUnavailable }
    func removeRecordGraph() async throws -> RecordGraphRemovalResult { throw RecordStoreError.persistenceUnavailable }
}
