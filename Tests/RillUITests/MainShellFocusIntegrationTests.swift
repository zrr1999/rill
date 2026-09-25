@testable import RillWorkflows
import AppKit
import SwiftUI
import RillCore
import XCTest

@testable import RillUI

private actor SidebarFocusTurnGate {
    private struct ReleaseWaiter {
        let entry: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let onEntry: @Sendable (Int) -> Void
    private var entryCount = 0
    private var releasedThrough = 0
    private var releaseWaiters: [ReleaseWaiter] = []

    init(onEntry: @escaping @Sendable (Int) -> Void) {
        self.onEntry = onEntry
    }

    func wait() async {
        entryCount += 1
        let entry = entryCount
        onEntry(entry)
        guard releasedThrough < entry else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(
                ReleaseWaiter(entry: entry, continuation: continuation)
            )
        }
    }

    func release(through entry: Int) {
        releasedThrough = max(releasedThrough, entry)
        var remaining: [ReleaseWaiter] = []
        for waiter in releaseWaiters {
            if waiter.entry <= releasedThrough {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        releaseWaiters = remaining
    }

    func currentEntryCount() -> Int {
        entryCount
    }
}

private actor MissingRunHistoryBrowser: RunHistoryBrowsing {
    func page(_ request: RunHistoryPageRequest) async throws -> RunHistoryPage {
        let session: RunHistoryReadSession
        switch request {
        case .first(let scope, let retentionCutoff, let contentAccess, _):
            session = try RunHistoryReadSession(
                generation: .initial,
                snapshotWriteOrdinal: 0,
                retentionCutoff: retentionCutoff,
                scope: scope,
                contentAccess: contentAccess
            )
        case .next(let cursor, _):
            session = cursor.session
        }
        return RunHistoryPage(session: session, entries: [], nextCursor: nil)
    }

    func page(
        containing entryID: UUID,
        in session: RunHistoryReadSession,
        limit: Int
    ) async throws -> RunHistoryPage? {
        nil
    }

    func page(
        containing entryID: UUID,
        scope: RunHistoryBrowseScope,
        retentionCutoff: Date?,
        contentAccess: RunHistoryContentAccess,
        limit: Int
    ) async throws -> RunHistoryPage? {
        nil
    }
}

@MainActor
final class MainShellFocusIntegrationTests: XCTestCase {
    func testJevDeepLinkFocusesSecureFieldInsideIndependentSettingsWindow() async throws {
        _ = NSApplication.shared
        let fixture = JevPanelFixture()
        let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
        let model = makeHarness(recordWorkspace: workspace).model
        model.showSettings(.providers, item: .jevCredential)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsWindowView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { tearDown(window) }
        await settle(window)
        // SwiftUI's secure control owns a field editor, not an exposed NSTextField.
        // The other credential field is unavailable in this in-memory harness.
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertTrue(editor.isEditable)
        XCTAssertNil(model.settingsNavigationRequest)
        XCTAssertEqual(model.selectedSidebarSection, .records)
        XCTAssertTrue(editor.visibleRect.height > 0)
        await workspace.shutdown()
    }

    func testGlobalSearchExclusivelyOwnsInteractionAndFocusUntilDismissed() {
        XCTAssertFalse(
            MainShellInteractionPolicy.allowsBackgroundInteraction(
                isGlobalSearchPresented: true
            )
        )
        XCTAssertFalse(
            MainShellInteractionPolicy.allowsSidebarInteraction(
                isGlobalSearchPresented: true
            )
        )
        XCTAssertFalse(
            MainShellInteractionPolicy.allowsDetailInteraction(
                isGlobalSearchPresented: true
            )
        )
        XCTAssertFalse(
            MainShellInteractionPolicy.allowsToolbarInteraction(
                isGlobalSearchPresented: true
            )
        )
        XCTAssertFalse(
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: true,
                detailOwnsFocus: false
            )
        )

        XCTAssertTrue(
            MainShellInteractionPolicy.allowsBackgroundInteraction(
                isGlobalSearchPresented: false
            )
        )
        XCTAssertTrue(
            MainShellInteractionPolicy.allowsSidebarInteraction(
                isGlobalSearchPresented: false
            )
        )
        XCTAssertTrue(
            MainShellInteractionPolicy.allowsDetailInteraction(
                isGlobalSearchPresented: false
            )
        )
        XCTAssertTrue(
            MainShellInteractionPolicy.allowsToolbarInteraction(
                isGlobalSearchPresented: false
            )
        )
        XCTAssertTrue(
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: false,
                detailOwnsFocus: false
            )
        )
        XCTAssertFalse(
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: false,
                detailOwnsFocus: true
            )
        )
    }

    func testRepeatedGlobalSearchPresentationRefocusesWithoutResettingSelection() {
        XCTAssertEqual(
            GlobalSearchPresentationPolicy.transition(
                isPresented: false,
                currentFocusRequest: 8
            ),
            GlobalSearchPresentationTransition(
                shouldInitializeSelection: true,
                focusRequest: 9
            )
        )
        XCTAssertEqual(
            GlobalSearchPresentationPolicy.transition(
                isPresented: true,
                currentFocusRequest: 9
            ),
            GlobalSearchPresentationTransition(
                shouldInitializeSelection: false,
                focusRequest: 10
            ),
            "Repeated Command-F must refocus the existing search without resetting it."
        )
    }

    func testQueuedInteractiveRepairDoesNotStealGlobalSearchFieldFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)
        let recordCollectionRow = try XCTUnwrap(
            nextSelectableRow(after: streamRow, in: sidebar)
        )
        let searchToolbarItem = try XCTUnwrap(
            window.toolbar?.items.first { item in
                item.itemIdentifier.rawValue.contains("rill.global-search")
            }
        )
        let searchToolbarView = try XCTUnwrap(searchToolbarItem.view)

        // Leave the sidebar's post-selection repair queued in an interactive
        // run-loop mode, then present search before that callback runs. Search
        // must synchronously retire the old route claim, and the delayed
        // callback must protect the newer field-editor responder.
        XCTAssertTrue(
            runMainEventTrackingTurn {
                sidebar.selectRowIndexes(
                    IndexSet(integer: recordCollectionRow),
                    byExtendingSelection: false
                )
            }
        )
        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        click(searchToolbarView, in: window)
        XCTAssertTrue(runMainEventTrackingTurn {})
        await settle(window)

        let searchField = try XCTUnwrap(
            descendantTextFields(in: window.contentView).first {
                $0.accessibilityIdentifier() == "global-search.field"
            }
        )
        XCTAssertTrue(isTextEditingResponder(window.firstResponder, for: searchField))
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testKeyboardRepairDoesNotClaimIndependentAccessibilityFocus() {
        XCTAssertNil(
            SidebarAccessibilityFocusPolicy.destinationAfterKeyboardRepair(
                currentSidebarDestination: Optional<String>.none,
                requestedDestination: "clipboard",
                didRestoreKeyboardFocus: true
            ),
            "Repairing AppKit first responder must not pull VoiceOver out of detail content."
        )
        XCTAssertNil(
            SidebarAccessibilityFocusPolicy.destinationAfterKeyboardRepair(
                currentSidebarDestination: "dashboard",
                requestedDestination: "clipboard",
                didRestoreKeyboardFocus: false
            ),
            "A failed keyboard repair must not mutate the independent accessibility channel."
        )
    }

    func testKeyboardRepairAdvancesAccessibilityFocusOnlyWhenSidebarAlreadyOwnsIt() {
        XCTAssertEqual(
            SidebarAccessibilityFocusPolicy.destinationAfterKeyboardRepair(
                currentSidebarDestination: "dashboard",
                requestedDestination: "clipboard",
                didRestoreKeyboardFocus: true
            ),
            "clipboard"
        )
    }

    func testDefaultModeSchedulerDoesNotRunDuringMouseEventTracking() {
        let didRunDefaultOperation = MainActorBooleanProbe()

        XCTAssertTrue(
            runMainEventTrackingTurn {
                XCTAssertEqual(RunLoop.current.currentMode, .eventTracking)
                scheduleOnMainRunLoopDefaultMode {
                    didRunDefaultOperation.value = true
                }
                XCTAssertFalse(didRunDefaultOperation.value)
            }
        )
        XCTAssertFalse(didRunDefaultOperation.value)
        XCTAssertTrue(
            runMainDefaultMode(until: { didRunDefaultOperation.value }),
            "A default-mode callback must remain pending until mouse tracking ends."
        )
    }

    func testAllRecordsThroughCollectionsToActivityPreservesSidebarFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let detailFocusAnchor = try XCTUnwrap(detailFocusAnchor(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let downArrow = try XCTUnwrap(downArrowEvent(for: window))

        sidebar.keyDown(with: downArrow)
        await settle(window)
        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        let firstCollectionID = harness.model.recordWorkspace.selectedCollectionID
        XCTAssertNotNil(firstCollectionID)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))
        XCTAssertFalse(window.firstResponder === detailFocusAnchor)

        sidebar.keyDown(with: downArrow)
        await settle(window)
        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertNotEqual(harness.model.recordWorkspace.selectedCollectionID, firstCollectionID)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        sidebar.keyDown(with: downArrow)
        await settle(window)
        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "Each detail replacement must preserve continued keyboard navigation in the sidebar."
        )
        XCTAssertFalse(window.firstResponder === detailFocusAnchor)
    }

    func testStreamToClipboardSelectionReplacementPreservesSidebarFirstResponder() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)
        let recordCollectionRow = try XCTUnwrap(
            nextSelectableRow(after: streamRow, in: sidebar)
        )

        sidebar.selectRowIndexes(
            IndexSet(integer: recordCollectionRow),
            byExtendingSelection: false
        )
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "Replacing the detail through List selection must keep keyboard focus in the sidebar."
        )
    }

    func testStreamToClipboardEventTrackingRepairsBeforeDefaultModeFallback() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let clipboardFocusWait = expectation(description: "Clipboard focus waits for its turn")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                clipboardFocusWait.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)
        let clipboardRow = try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))
        let didRunTrackingSelection = runMainEventTrackingTurn {
            XCTAssertEqual(RunLoop.current.currentMode, .eventTracking)
            sidebar.selectRowIndexes(
                IndexSet(integer: clipboardRow),
                byExtendingSelection: false
            )
            XCTAssertEqual(harness.model.selectedSidebarSection, .records)
            XCTAssertTrue(
                self.isResponder(window.firstResponder, inside: sidebar),
                "The sidebar must own focus when its mouse selection setter returns."
            )
            XCTAssertTrue(window.makeFirstResponder(nil))
        }
        XCTAssertTrue(didRunTrackingSelection)

        XCTAssertTrue(
            runMainEventTrackingTurn {
                XCTAssertTrue(
                    self.isResponder(window.firstResponder, inside: sidebar),
                    "The interactive-mode repair must close a post-selection responder gap before the default-mode fallback."
                )
            }
        )
        await fulfillment(of: [clipboardFocusWait], timeout: 1)
        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "Blocking the default-mode fallback must not expose a responder gap."
        )

        await focusTurnGate.release(through: 3)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A selection committed during mouse tracking must restore focus once the default run loop resumes."
        )
    }

    func testQueuedInteractiveRepairDoesNotStealNewHostedClipboardDetailFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)
        let recordCollectionRow = try XCTUnwrap(
            nextSelectableRow(after: streamRow, in: sidebar)
        )

        let detailFocusProbe = FocusProbeView(frame: .zero)
        let detailHost = NSHostingView(
            rootView: HostedFocusProbe(probe: detailFocusProbe)
        )
        detailHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        defer { detailHost.removeFromSuperview() }

        XCTAssertTrue(
            runMainEventTrackingTurn {
                sidebar.selectRowIndexes(
                    IndexSet(integer: recordCollectionRow),
                    byExtendingSelection: false
                )
                window.contentView?.addSubview(detailHost)
                detailHost.layoutSubtreeIfNeeded()
                XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))
            }
        )
        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(window.firstResponder === detailFocusProbe)

        // The repair scheduled by the sidebar selection is allowed to run in a
        // later event-tracking turn. It must treat focus acquired after the
        // route commit as newer ownership rather than unconditionally
        // restoring the sidebar.
        XCTAssertTrue(
            runMainEventTrackingTurn {
                XCTAssertTrue(window.firstResponder === detailFocusProbe)
            }
        )
        await settle(window)

        XCTAssertTrue(
            window.firstResponder === detailFocusProbe,
            "A queued interactive repair must preserve focus acquired in the committed detail."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testStreamToClipboardDoesNotClearSidebarFocusWhileWaitingForPostTrackingRepair()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let clipboardFocusWait = expectation(description: "Clipboard focus waits for its turn")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                clipboardFocusWait.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)
        let recordCollectionRow = try XCTUnwrap(
            nextSelectableRow(after: streamRow, in: sidebar)
        )

        XCTAssertTrue(
            runMainEventTrackingTurn {
                sidebar.selectRowIndexes(
                    IndexSet(integer: recordCollectionRow),
                    byExtendingSelection: false
                )
            }
        )
        await fulfillment(of: [clipboardFocusWait], timeout: 1)

        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A post-tracking repair request must not proactively clear a sidebar that still owns focus."
        )

        await focusTurnGate.release(through: 3)
        await settle(window)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))
    }

    func testDelayedSidebarRepairDoesNotStealNewDetailFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let clipboardFocusWait = expectation(description: "Clipboard focus waits for its turn")
        let boundedFocusRecheck = expectation(description: "Clipboard focus reaches bounded recheck")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                clipboardFocusWait.fulfill()
            case 3:
                boundedFocusRecheck.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow

        sidebar.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))),
            byExtendingSelection: false
        )
        await fulfillment(of: [clipboardFocusWait], timeout: 1)

        await focusTurnGate.release(through: 2)
        await fulfillment(of: [boundedFocusRecheck], timeout: 1)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "The first default-mode reconciliation must finish with sidebar focus."
        )

        let newDetailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(newDetailFocusProbe)
        defer { newDetailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(newDetailFocusProbe))

        await focusTurnGate.release(through: 3)
        await settle(window)

        XCTAssertTrue(
            window.firstResponder === newDetailFocusProbe,
            "A late sidebar repair must preserve a newer valid focus in the committed detail."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testFirstDefaultModeRepairDoesNotStealDetailFocusAcquiredWhileWaiting()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let clipboardFocusWait = expectation(description: "Clipboard focus waits for its first turn")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                clipboardFocusWait.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)

        sidebar.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))),
            byExtendingSelection: false
        )
        await fulfillment(of: [clipboardFocusWait], timeout: 1)
        XCTAssertEqual(harness.model.selectedSidebarSection, .records)

        let newDetailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(newDetailFocusProbe)
        defer { newDetailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(newDetailFocusProbe))

        await focusTurnGate.release(through: 2)
        await settle(window)

        XCTAssertTrue(
            window.firstResponder === newDetailFocusProbe,
            "The first default-mode repair must preserve focus acquired after the sidebar route committed."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))

        // The route claim remains valid through one bounded recheck, but that
        // recheck must continue preserving the live responder.
        await focusTurnGate.release(through: 3)
        await settle(window)
        XCTAssertTrue(window.firstResponder === newDetailFocusProbe)
    }

    func testFirstRepairPreservesReactivatedPersistentResponderAndRetainsClaim()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let firstRouteRepair = expectation(description: "Route reaches its first repair")
        let boundedRouteRecheck = expectation(description: "Route reaches its bounded recheck")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                firstRouteRepair.fulfill()
            case 3:
                boundedRouteRecheck.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)

        let persistentDetailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(persistentDetailFocusProbe)
        defer { persistentDetailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(persistentDetailFocusProbe))

        sidebar.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))),
            byExtendingSelection: false
        )
        await fulfillment(of: [firstRouteRepair], timeout: 1)

        // Re-enter the same persistent responder captured before the route.
        // Its identity is unchanged, but this is a newer focus interaction.
        XCTAssertTrue(window.makeFirstResponder(persistentDetailFocusProbe))
        await focusTurnGate.release(through: 2)
        await fulfillment(of: [boundedRouteRecheck], timeout: 1)

        XCTAssertTrue(
            window.firstResponder === persistentDetailFocusProbe,
            "The first protected repair must preserve every live responder, including the same persistent object."
        )

        // Keeping the route claim through the protected repair lets its one
        // bounded recheck repair a real vacuum if that responder then leaves.
        persistentDetailFocusProbe.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(nil))
        await focusTurnGate.release(through: 3)
        await settle(window)

        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "The retained route claim must repair a responder vacuum at the bounded recheck."
        )
    }

    func testBoundedRecheckDoesNotStealReactivatedPersistentDetailResponder()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let firstRouteRepair = expectation(description: "Route reaches its first repair")
        let boundedRouteRecheck = expectation(description: "Route reaches its bounded recheck")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                firstRouteRepair.fulfill()
            case 3:
                boundedRouteRecheck.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)

        let persistentDetailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(persistentDetailFocusProbe)
        defer { persistentDetailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(persistentDetailFocusProbe))

        sidebar.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))),
            byExtendingSelection: false
        )
        await fulfillment(of: [firstRouteRepair], timeout: 1)
        await focusTurnGate.release(through: 2)
        await fulfillment(of: [boundedRouteRecheck], timeout: 1)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        // A persistent banner, toolbar control, or accessibility-selected
        // detail control can be the same AppKit responder object before and
        // after the route. Re-entering it is a new user action even though its
        // object identity matches the responder captured at route start.
        XCTAssertTrue(window.makeFirstResponder(persistentDetailFocusProbe))
        await focusTurnGate.release(through: 3)
        await settle(window)

        XCTAssertTrue(
            window.firstResponder === persistentDetailFocusProbe,
            "The bounded route recheck must preserve a same-object responder explicitly reactivated after the first repair."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testBoundedRecheckRepairsResponderVacuumAfterInitialRepair() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let firstRouteRepair = expectation(description: "Route reaches its first repair")
        let boundedRouteRecheck = expectation(description: "Route reaches its bounded recheck")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                firstRouteRepair.fulfill()
            case 3:
                boundedRouteRecheck.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)

        sidebar.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))),
            byExtendingSelection: false
        )
        await fulfillment(of: [firstRouteRepair], timeout: 1)
        await focusTurnGate.release(through: 2)
        await fulfillment(of: [boundedRouteRecheck], timeout: 1)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        XCTAssertTrue(window.makeFirstResponder(nil))
        await focusTurnGate.release(through: 3)
        await settle(window)

        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "The bounded recheck must still repair a genuine responder vacuum."
        )
    }

    func testCollapsedSidebarProgrammaticRouteRepairsVacuumToDetailAnchor() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let routeFocusWait = expectation(description: "Collapsed route waits for detail repair")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                routeFocusWait.fulfill()
            default:
                break
            }
        }
        harness.model.selectSidebarSection(.stream)
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let sidebarScrollView = try XCTUnwrap(sidebar.enclosingScrollView)
        let departingFocusProbe = FocusProbeView(frame: .zero)
        let departingHost = NSHostingView(
            rootView: HostedFocusProbe(probe: departingFocusProbe)
        )
        departingHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(departingHost)
        departingHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(departingFocusProbe))

        sidebarScrollView.isHidden = true
        harness.model.selectSidebarSection(.workflows)
        await fulfillment(of: [routeFocusWait], timeout: 1)

        departingHost.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(nil))
        await focusTurnGate.release(through: 2)
        await settle(window)

        let detailFocusAnchor = try XCTUnwrap(detailFocusAnchor(in: window))
        XCTAssertEqual(harness.model.selectedSidebarSection, .workflows)
        XCTAssertTrue(
            window.firstResponder === detailFocusAnchor
                || isResponder(window.firstResponder, withinVisualBoundsOf: detailFocusAnchor),
            "A collapsed route must repair a detached responder into the committed detail."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
        XCTAssertFalse(detailFocusAnchor.isAccessibilityElement())
        XCTAssertFalse(detailFocusAnchor.canBecomeKeyView)

        XCTAssertTrue(window.makeFirstResponder(detailFocusAnchor))
        XCTAssertTrue(window.firstResponder === detailFocusAnchor)
        let tab = try XCTUnwrap(tabEvent(for: window))
        detailFocusAnchor.keyDown(with: tab)
        await settle(window)

        XCTAssertFalse(
            window.firstResponder === detailFocusAnchor,
            "The fallback anchor must hand Tab to the detail key-view loop."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
        XCTAssertTrue(
            isResponder(window.firstResponder, withinVisualBoundsOf: detailFocusAnchor),
            "Tab from the fallback anchor must enter the committed detail, not toolbar navigation."
        )
    }

    func testCollapsedSidebarProgrammaticRoutePreservesNewDetailFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let routeFocusWait = expectation(description: "Collapsed route waits for detail repair")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                routeFocusWait.fulfill()
            default:
                break
            }
        }
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let sidebarScrollView = try XCTUnwrap(sidebar.enclosingScrollView)
        let departingFocusProbe = FocusProbeView(frame: .zero)
        let departingHost = NSHostingView(
            rootView: HostedFocusProbe(probe: departingFocusProbe)
        )
        departingHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(departingHost)
        departingHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(departingFocusProbe))

        sidebarScrollView.isHidden = true
        harness.model.selectSidebarSection(.records)
        await fulfillment(of: [routeFocusWait], timeout: 1)
        departingHost.removeFromSuperview()

        let committedFocusProbe = FocusProbeView(frame: .zero)
        let committedHost = NSHostingView(
            rootView: HostedFocusProbe(probe: committedFocusProbe)
        )
        committedHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(committedHost)
        committedHost.layoutSubtreeIfNeeded()
        defer { committedHost.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(committedFocusProbe))

        await focusTurnGate.release(through: 2)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            window.firstResponder === committedFocusProbe,
            "Collapsed-route repair must preserve focus acquired by the committed detail."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
        let detailFocusAnchor = try XCTUnwrap(detailFocusAnchor(in: window))
        XCTAssertFalse(window.firstResponder === detailFocusAnchor)
    }

    func testSidebarCollapseAndReexpandPreservesLiveDetailFocusWithoutRearm()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let sidebarScrollView = try XCTUnwrap(sidebar.enclosingScrollView)
        let detailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(detailFocusProbe)
        defer { detailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))

        sidebarScrollView.isHidden = true
        await settle(window)
        XCTAssertTrue(window.firstResponder === detailFocusProbe)

        sidebarScrollView.isHidden = false
        await settle(window)

        XCTAssertTrue(
            window.firstResponder === detailFocusProbe,
            "Re-expanding navigation must preserve a live detail responder instead of rearming sidebar focus."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testWindowKeyCyclePreservesLiveDetailFocusWithoutSidebarRearm() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        let alternateWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 240, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        alternateWindow.isReleasedWhenClosed = false
        defer {
            tearDown(alternateWindow)
            tearDown(window)
        }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let detailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(detailFocusProbe)
        defer { detailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))

        alternateWindow.makeKeyAndOrderFront(nil)
        await settle(alternateWindow)
        XCTAssertTrue(
            window.firstResponder === detailFocusProbe,
            "Resigning key status must retain the main window's stored responder."
        )

        window.makeKeyAndOrderFront(nil)
        await settle(window)

        XCTAssertTrue(
            window.firstResponder === detailFocusProbe,
            "Becoming key again must restore the stored detail responder without a sidebar repair."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testProgrammaticRouteChangeRehomesDetailFocusInSidebar() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let detailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(detailFocusProbe)
        defer { detailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))
        await settle(window)
        XCTAssertTrue(window.firstResponder === detailFocusProbe)

        harness.model.selectSidebarSection(.stream)
        detailFocusProbe.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(nil))
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A detail-originated route must land in persistent sidebar navigation."
        )
    }

    func testProgrammaticRouteKeepsSidebarFocusWhenDepartingHostDetachesAfterRepair()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let routeCheck = expectation(description: "Programmatic route reaches its focus check")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                routeCheck.fulfill()
            default:
                break
            }
        }
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))

        let departingFocusProbe = FocusProbeView(frame: .zero)
        let departingHost = NSHostingView(
            rootView: HostedFocusProbe(probe: departingFocusProbe)
        )
        departingHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(departingHost)
        departingHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(departingFocusProbe))

        harness.model.selectSidebarSection(.records)
        await fulfillment(of: [routeCheck], timeout: 1)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A programmatic route must claim the sidebar before its departing hosted responder detaches."
        )
        await focusTurnGate.release(through: 2)
        await settle(window)
        let completedEntryCount = await focusTurnGate.currentEntryCount()
        XCTAssertEqual(completedEntryCount, 2)

        // The host outlives the complete repair task. Detaching it afterward
        // must not clear focus because it stopped being first responder when
        // the route synchronously claimed the persistent sidebar.
        departingHost.removeFromSuperview()
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A departing host that detaches after route repair must not create a focus vacuum."
        )
    }

    func testProgrammaticRoutePostClaimRepairPreservesNewHostedDetailFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let routeCheck = expectation(description: "Programmatic route reaches its focus check")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                routeCheck.fulfill()
            default:
                break
            }
        }
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))

        let departingFocusProbe = FocusProbeView(frame: .zero)
        let departingHost = NSHostingView(
            rootView: HostedFocusProbe(probe: departingFocusProbe)
        )
        departingHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(departingHost)
        departingHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(departingFocusProbe))

        harness.model.selectSidebarSection(.records)
        await fulfillment(of: [routeCheck], timeout: 1)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        departingHost.removeFromSuperview()
        let committedFocusProbe = FocusProbeView(frame: .zero)
        let committedHost = NSHostingView(
            rootView: HostedFocusProbe(probe: committedFocusProbe)
        )
        committedHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(committedHost)
        committedHost.layoutSubtreeIfNeeded()
        defer { committedHost.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(committedFocusProbe))

        await focusTurnGate.release(through: 2)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .records)
        XCTAssertTrue(
            window.firstResponder === committedFocusProbe,
            "The post-claim repair must preserve a responder acquired in the committed hosted detail."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
        let completedEntryCount = await focusTurnGate.currentEntryCount()
        XCTAssertEqual(completedEntryCount, 2)
    }

    func testReplacementProgrammaticRouteSupersedesSuspendedProgrammaticClaim()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let clipboardRouteWait = expectation(description: "Clipboard route waits for its focus check")
        let historyRouteWait = expectation(description: "Stream route supersedes the clipboard claim")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                clipboardRouteWait.fulfill()
            case 3:
                historyRouteWait.fulfill()
            default:
                break
            }
        }
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))

        let clipboardFocusProbe = FocusProbeView(frame: .zero)
        let clipboardHost = NSHostingView(
            rootView: HostedFocusProbe(probe: clipboardFocusProbe)
        )
        clipboardHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(clipboardHost)
        clipboardHost.layoutSubtreeIfNeeded()

        XCTAssertTrue(window.makeFirstResponder(clipboardFocusProbe))
        harness.model.selectSidebarSection(.records)
        await fulfillment(of: [clipboardRouteWait], timeout: 1)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        // Model a focus acquired by the committed Clipboard detail while its
        // programmatic route task is still suspended. The next programmatic
        // destination must replace that older claim instead of skipping its
        // own ownership transition.
        XCTAssertTrue(window.makeFirstResponder(clipboardFocusProbe))
        harness.model.selectSidebarSection(.stream)
        await fulfillment(of: [historyRouteWait], timeout: 1)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        await focusTurnGate.release(through: 3)
        await settle(window)
        clipboardHost.removeFromSuperview()
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "The final route must retain sidebar focus after the superseded detail host detaches."
        )
        let completedEntryCount = await focusTurnGate.currentEntryCount()
        XCTAssertEqual(completedEntryCount, 3)
    }

    func testProgrammaticRouteSupersedesPendingListClaimForOlderDestination()
        async throws
    {
        _ = NSApplication.shared
        let harness = makeHarness()
        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let clipboardListWait = expectation(description: "Clipboard List route waits for repair")
        let historyRouteWait = expectation(description: "Stream route supersedes the old List claim")
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                clipboardListWait.fulfill()
            case 3:
                historyRouteWait.fulfill()
            default:
                break
            }
        }
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let streamRow = sidebar.selectedRow
        XCTAssertGreaterThanOrEqual(streamRow, 0)

        sidebar.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(nextSelectableRow(after: streamRow, in: sidebar))),
            byExtendingSelection: false
        )
        await fulfillment(of: [clipboardListWait], timeout: 1)

        let clipboardFocusProbe = FocusProbeView(frame: .zero)
        let clipboardHost = NSHostingView(
            rootView: HostedFocusProbe(probe: clipboardFocusProbe)
        )
        clipboardHost.frame = NSRect(x: 300, y: 80, width: 240, height: 120)
        window.contentView?.addSubview(clipboardHost)
        clipboardHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(clipboardFocusProbe))

        harness.model.selectSidebarSection(.stream)
        await fulfillment(of: [historyRouteWait], timeout: 1)
        XCTAssertTrue(isResponder(window.firstResponder, inside: sidebar))

        await focusTurnGate.release(through: 3)
        await settle(window)
        clipboardHost.removeFromSuperview()
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A List claim for an older destination must not suppress the final programmatic route."
        )
        let completedEntryCount = await focusTurnGate.currentEntryCount()
        XCTAssertEqual(completedEntryCount, 3)
    }

    func testRepeatedProgrammaticRouteDoesNotStealDetailFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let detailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(detailFocusProbe)
        defer { detailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))
        await settle(window)

        harness.model.selectSidebarSection(.workflows)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .workflows)
        XCTAssertTrue(
            window.firstResponder === detailFocusProbe,
            "Selecting the current route must not pull focus out of its detail."
        )
    }

    func testRapidProgrammaticRoutesLandOnFinalSidebarDestination() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        harness.model.selectSidebarSection(.records)
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let detailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(detailFocusProbe)
        defer { detailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))

        harness.model.selectSidebarSection(.stream)
        detailFocusProbe.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(nil))
        await Task.yield()
        harness.model.selectSidebarSection(.records)
        await Task.yield()
        harness.model.selectSidebarSection(.workflows)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .workflows)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "Only the final destination in a rapid route sequence may own sidebar focus."
        )
    }

    func testSettingsRequestLeavesMainWindowSelectionAndResponderIntact() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }
        await settle(window)
        let selectedSection = harness.model.selectedSidebarSection
        let responder = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(responder)
        defer { responder.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(responder))

        harness.model.showSettings(.speech)
        harness.model.showSettings(.privacy)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, selectedSection)
        XCTAssertEqual(harness.model.selectedSettingsPane, .privacy)
        XCTAssertEqual(harness.model.settingsNavigationRequest?.section, .privacy)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertTrue(harness.model.consumeSettingsPresentation())
        XCTAssertFalse(harness.model.consumeSettingsPresentation())
    }

    func testTypedSettingsDestinationAppearsInIndependentWindow() async throws {
        _ = NSApplication.shared
        let harness = makeHarness()
        let mainWindow = makeWindow(model: harness.model)
        defer { tearDown(mainWindow) }
        await settle(mainWindow)
        let destination = harness.model.selectedSidebarSection
        harness.model.showSettings(.speech)
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = NSHostingView(rootView: SettingsWindowView(model: harness.model))
        settingsWindow.makeKeyAndOrderFront(nil)
        defer { tearDown(settingsWindow) }
        await settle(settingsWindow)

        XCTAssertEqual(harness.model.selectedSidebarSection, destination)
        XCTAssertEqual(harness.model.selectedSettingsPane, .voice)
        XCTAssertNil(harness.model.settingsNavigationRequest)
        let responder = try XCTUnwrap(settingsWindow.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: try XCTUnwrap(settingsWindow.contentView)))
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertTrue(mainWindow.isVisible)
    }

    func testSettingsNavigationFocusStaysWithinDisclosureHeader() async throws {
        _ = NSApplication.shared
        let model = makeHarness().model
        model.showSettings(.storage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model, pane: .data))
        window.makeKeyAndOrderFront(nil)
        defer { tearDown(window) }
        await settle(window)

        XCTAssertNil(model.settingsNavigationRequest)
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertGreaterThan(responder.bounds.height, 0)
        XCTAssertLessThan(responder.bounds.height, 80,
            "Settings navigation should focus the disclosure header, not its expanded contents.")
        XCTAssertTrue(window.makeFirstResponder(window))
        model.showSettings(.storage)
        await settle(window)
        XCTAssertNil(model.settingsNavigationRequest)
        let refocused = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertLessThan(refocused.bounds.height, 80)
    }

    func testSettingsDisclosureHeaderActivatesAndReleasesKeyboardFocus() async throws {
        let expansion = SettingsDisclosureTestState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsDisclosureTestView(state: expansion))
        window.makeKeyAndOrderFront(nil)
        defer { tearDown(window) }
        await settle(window)
        let header = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(expansion.isExpanded)
        for expected in [false, true] {
            try pressKey(" ", keyCode: 49, in: window)
            await settle(window)
            XCTAssertEqual(expansion.isExpanded, expected)
            XCTAssertTrue(window.firstResponder === header)
        }
        window.selectNextKeyView(nil)
        await settle(window)
        try pressKey("x", keyCode: 7, in: window)
        await settle(window)
        XCTAssertEqual(expansion.text, "x", "Keyboard traversal should reach the expanded text field.")
        expansion.focusRequest += 1
        await settle(window)
        let restoredHeader = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(restoredHeader.isDescendant(of: try XCTUnwrap(window.contentView)))
        try pressKey(" ", keyCode: 49, in: window)
        await settle(window)
        XCTAssertFalse(expansion.isExpanded)
        expansion.isEnabled = false
        await settle(window)
        try pressKey(" ", keyCode: 49, in: window)
        await settle(window)
        XCTAssertFalse(expansion.isExpanded, "A disabled settings section should not activate.")
        expansion.isEnabled = true
        expansion.focusRequest += 1
        await settle(window)
        try pressKey(" ", keyCode: 49, in: window)
        await settle(window)
        XCTAssertTrue(expansion.isExpanded)
    }

    private func pressKey(
        _ characters: String, keyCode: UInt16, in window: NSWindow
    ) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
    }

    func testTypedHistoryRouteSupersedesPendingPlainSidebarFocusRequest() async throws {
        _ = NSApplication.shared
        let record = WorkflowResultRecord(
            workflow: WorkflowPresentation(fallbackName: "Focused history run"),
            finalText: "Focused history result",
            outcome: .completed,
            trigger: .hotkey
        )
        let harness = makeHarness(
            historyRepository: InMemoryHistoryRepository(records: [record])
        )
        for _ in 0..<100 {
            if harness.model.history.historyRecords.contains(where: { $0.id == record.id }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(harness.model.history.historyRecords.contains(where: { $0.id == record.id }))

        let initialFocusWait = expectation(description: "Initial sidebar focus waits for its turn")
        let plainRecordsFocusWait = expectation(
            description: "Plain records route starts its sidebar focus request"
        )
        let focusTurnGate = SidebarFocusTurnGate { entry in
            switch entry {
            case 1:
                initialFocusWait.fulfill()
            case 2:
                plainRecordsFocusWait.fulfill()
            default:
                break
            }
        }
        harness.model.selectSidebarSection(.workflows)
        let window = makeWindow(
            model: harness.model,
            sidebarFocusTurnWaiter: {
                await focusTurnGate.wait()
            }
        )
        defer { tearDown(window) }
        await fulfillment(of: [initialFocusWait], timeout: 1)
        await focusTurnGate.release(through: 1)
        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))

        harness.model.selectSidebarSection(.records)
        await fulfillment(of: [plainRecordsFocusWait], timeout: 1)
        harness.model.showHistoryEntry(record.id)
        await settle(window)
        let detailFocusProbe = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(detailFocusProbe)
        defer { detailFocusProbe.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(detailFocusProbe))

        await focusTurnGate.release(through: 2)
        await settle(window)

        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertEqual(harness.model.history.historyNavigationRequest?.entryID, record.id)
        XCTAssertTrue(
            window.firstResponder === detailFocusProbe,
            "A typed history destination must cancel the pending sidebar focus request."
        )
        XCTAssertFalse(isResponder(window.firstResponder, inside: sidebar))
    }

    func testExpiredTypedHistoryRouteFallsBackToStableSidebarFocus() async throws {
        _ = NSApplication.shared
        let harness = makeHarness(runHistoryBrowser: MissingRunHistoryBrowser())
        let window = makeWindow(model: harness.model)
        defer { tearDown(window) }

        await settle(window)
        let sidebar = try XCTUnwrap(sidebarTable(in: window))
        let departingDetailFocus = FocusProbeView(frame: .zero)
        window.contentView?.addSubview(departingDetailFocus)
        XCTAssertTrue(window.makeFirstResponder(departingDetailFocus))

        let missingEntryID = UUID()
        harness.model.showHistoryEntry(missingEntryID)
        departingDetailFocus.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(nil))

        for _ in 0..<100 {
            if case .expired(let expiredEntryID) = harness.model.history.runHistoryDeepLinkState,
                expiredEntryID == missingEntryID
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await settle(window)

        guard case .expired(let expiredEntryID) = harness.model.history.runHistoryDeepLinkState,
            expiredEntryID == missingEntryID
        else {
            return XCTFail("The missing typed history destination did not resolve as expired.")
        }
        XCTAssertEqual(harness.model.selectedSidebarSection, .stream)
        XCTAssertTrue(
            isResponder(window.firstResponder, inside: sidebar),
            "A terminal typed-history request must release focus ownership to a stable fallback."
        )
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainShellView(model: model))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow(
        model: AppModel,
        sidebarFocusTurnWaiter: @escaping @MainActor @Sendable () async -> Void
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MainShellView(
                model: model,
                sidebarFocusTurnWaiter: sidebarFocusTurnWaiter
            )
        )
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<4 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func sidebarTable(in window: NSWindow) -> NSTableView? {
        guard let contentView = window.contentView else { return nil }
        return descendantTables(in: contentView).min { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).minX < rhs.convert(rhs.bounds, to: nil).minX
        }
    }

    private func nextSelectableRow(after row: Int, in table: NSTableView) -> Int? {
        // SwiftUI materializes the following Section header as the next
        // AppKit table row. The first collection is the row after that header.
        let candidate = row + 2
        return candidate < table.numberOfRows ? candidate : nil
    }

    private func detailFocusAnchor(in window: NSWindow) -> NSView? {
        descendantView(
            withIdentifier: NSUserInterfaceItemIdentifier("main-detail-focus-anchor"),
            in: window.contentView
        )
    }

    private func descendantView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        in root: NSView?
    ) -> NSView? {
        guard let root else { return nil }
        if root.identifier == identifier { return root }
        for child in root.subviews {
            if let match = descendantView(withIdentifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private func downArrowEvent(for window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            isARepeat: false,
            keyCode: 125
        )
    }

    private func tabEvent(for window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        )
    }

    private func click(_ view: NSView, in window: NSWindow) {
        let location = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        guard
            let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        else {
            return XCTFail("Unable to create toolbar click events.")
        }
        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
    }

    private func descendantTables(in root: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let table = root as? NSTableView {
            result.append(table)
        }
        for child in root.subviews {
            result.append(contentsOf: descendantTables(in: child))
        }
        return result
    }

    private func descendantTextFields(in root: NSView?) -> [NSTextField] {
        guard let root else { return [] }
        var result: [NSTextField] = []
        if let textField = root as? NSTextField {
            result.append(textField)
        }
        for child in root.subviews {
            result.append(contentsOf: descendantTextFields(in: child))
        }
        return result
    }

    private func isTextEditingResponder(
        _ responder: NSResponder?,
        for textField: NSTextField
    ) -> Bool {
        if responder === textField { return true }
        guard let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor else {
            return false
        }
        return fieldEditor.delegate === textField
    }

    private func isResponder(_ responder: NSResponder?, inside view: NSView) -> Bool {
        guard let responder else { return false }
        if responder === view { return true }
        guard let responderView = responder as? NSView else { return false }
        return responderView.isDescendant(of: view)
    }

    private func isResponder(
        _ responder: NSResponder?,
        withinVisualBoundsOf view: NSView
    ) -> Bool {
        let responderView: NSView?
        if let fieldEditor = responder as? NSTextView,
            fieldEditor.isFieldEditor,
            let control = fieldEditor.delegate as? NSView
        {
            responderView = control
        } else {
            responderView = responder as? NSView
        }
        guard let responderView, responderView.window === view.window else { return false }
        let containerFrame = view.convert(view.bounds, to: nil)
        let responderFrame = responderView.convert(responderView.bounds, to: nil)
        return !containerFrame.isEmpty && containerFrame.intersects(responderFrame)
    }

}

@Observable @MainActor
private final class SettingsDisclosureTestState {
    var isExpanded = true
    var isEnabled = true
    var text = ""
    var focusRequest = 0
}

private struct SettingsDisclosureTestView: View {
    @Bindable var state: SettingsDisclosureTestState
    @FocusState private var keyboardFocus: SettingsSection?
    @AccessibilityFocusState private var accessibilityFocus: SettingsSection?

    var body: some View {
        DisclosureGroup("Section", isExpanded: $state.isExpanded) {
            TextField("Value", text: $state.text)
        }
        .disclosureGroupStyle(SettingsDisclosureStyle(section: .storage, keyboardFocus: $keyboardFocus,
            accessibilityFocus: $accessibilityFocus))
        .disabled(!state.isEnabled)
        .padding()
        .task(id: state.focusRequest) { keyboardFocus = .storage }
    }
}

private final class FocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct HostedFocusProbe: NSViewRepresentable {
    let probe: FocusProbeView

    func makeNSView(context: Context) -> FocusProbeView {
        probe
    }

    func updateNSView(_ nsView: FocusProbeView, context: Context) {}
}

@MainActor
private final class MainActorBooleanProbe {
    var value = false
}

@MainActor
private func runMainEventTrackingTurn(
    _ operation: @escaping @MainActor @Sendable () -> Void
) -> Bool {
    let didRun = MainActorBooleanProbe()
    RunLoop.main.perform(inModes: [.eventTracking]) {
        MainActor.assumeIsolated {
            operation()
            didRun.value = true
        }
    }
    let deadline = Date(timeIntervalSinceNow: 0.5)
    repeat {
        _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
    } while !didRun.value && Date() < deadline
    return didRun.value
}

@MainActor
private func runMainDefaultMode(
    until condition: @MainActor () -> Bool
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 0.5)
    repeat {
        _ = RunLoop.main.run(mode: .default, before: deadline)
    } while !condition() && Date() < deadline
    return condition()
}
