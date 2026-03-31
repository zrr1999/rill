import AppKit
import ApplicationServices
import Foundation
import VoxTypeCore
import VoxTypePlatform
import VoxTypeRuntime

public actor StackPasteController {
    private struct MirroredClipboardPreview: Equatable {
        var snapshot: ClipboardSnapshot
    }

    private static let monitorInterval = Duration.milliseconds(750)

    private let hotkeyTap: HotkeyEventTap
    private let pasteboard: PasteboardController
    private let contextProvider: any ContextProvider
    private let deliveryStack: DeliveryStack
    private let sessionCoordinator: SessionCoordinator
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let accessibilityChecker: @Sendable () -> Bool

    private var started = false
    private var storeEventsTask: Task<Void, Never>?
    private var hotkeyEventsTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var preservedClipboard: ClipboardSnapshot?
    private var ownedChangeCount: Int?
    private var mirroredPreview: MirroredClipboardPreview?
    private var latestRouteSnapshot = ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
            group: .defaultGroup,
            count: 0,
            previewText: nil
        ),
        count: 0,
        previewText: nil,
        previewContentKind: nil,
        previewSnapshot: nil
    )
    private var latestRouteContext: ClipboardRouteContext?
    private var isDeliveryInProgress = false
    private var lastObservedPasteboardChangeCount: Int?

    public init(
        hotkeyTap: HotkeyEventTap,
        pasteboard: PasteboardController,
        contextProvider: any ContextProvider,
        deliveryStack: DeliveryStack,
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.hotkeyTap = hotkeyTap
        self.pasteboard = pasteboard
        self.contextProvider = contextProvider
        self.deliveryStack = deliveryStack
        self.sessionCoordinator = sessionCoordinator
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.accessibilityChecker = accessibilityChecker
    }

    public func stop() {
        storeEventsTask?.cancel()
        hotkeyEventsTask?.cancel()
        monitorTask?.cancel()
        storeEventsTask = nil
        hotkeyEventsTask = nil
        monitorTask = nil
    }

    public func start() async {
        guard !started else { return }
        started = true

        let installed = hotkeyTap.install()
        hotkeyTap.setPasteInterceptEnabled(false)
        let initialClipboard = await pasteboard.currentSnapshot()
        lastObservedPasteboardChangeCount = initialClipboard.changeCount
        await recordInstallState(installed: installed)

        let eventStream = await eventBus.stream()
        storeEventsTask = Task {
            for await event in eventStream {
                guard case .clipboardUpdated(_) = event else { continue }
                await self.refreshActiveRouteSnapshotForClipboardUpdate()
            }
        }

        let hotkeyStream = hotkeyTap.stream()
        hotkeyEventsTask = Task {
            for await event in hotkeyStream {
                await self.handleHotkey(event)
            }
        }

        monitorTask = Task {
            while !Task.isCancelled {
                await self.captureExternalClipboardIfNeeded()
                await self.refreshActiveRouteSnapshotIfNeeded()
                try? await Task.sleep(for: Self.monitorInterval)
            }
        }

        await refreshActiveRouteSnapshot(forceContextRefresh: true)
    }

    public func pasteTopOfStack() async {
        guard accessibilityChecker() else {
            hotkeyTap.setPasteInterceptEnabled(false)
            await eventBus.publish(
                .runFailed(
                    runID: nil,
                    workflow: WorkflowPresentation(fallbackName: "Stack Delivery", titleKey: .stackDelivery),
                    message: TextInjectionEngine.InjectionError.accessibilityPermissionRequired.localizedDescription
                )
            )
            return
        }
        guard !isDeliveryInProgress else { return }

        let routeContext = await currentRouteContext()
        latestRouteContext = routeContext
        let routeSnapshot = await deliveryStack.routeSnapshot(for: routeContext)
        isDeliveryInProgress = true
        hotkeyTap.setPasteInterceptEnabled(false)
        defer {
            isDeliveryInProgress = false
            updatePasteInterceptState()
        }

        if routeSnapshot.previewContentKind == .image {
            await handleRouteSnapshot(routeSnapshot, routeContext: routeContext)
            await pasteMirroredClipboardItem(for: routeContext)
        } else {
            await sessionCoordinator.deliverNextClipboardItem(for: routeContext, actionID: "inject.text")
        }
        await refreshActiveRouteSnapshot(forceContextRefresh: true)
    }

    private func recordInstallState(installed: Bool) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                subsystem: .platform,
                level: installed ? .info : .warning,
                event: installed ? "paste-intercept.installed" : "paste-intercept.unavailable",
                message: installed
                    ? "Command-V interception is active when the clipboard route is non-empty"
                    : "Command-V interception could not be installed; manual clipboard paste remains available"
            )
        )
    }

    private func refreshActiveRouteSnapshot(forceContextRefresh: Bool = false) async {
        let routeContext: ClipboardRouteContext
        if !forceContextRefresh, let latestRouteContext {
            routeContext = latestRouteContext
        } else {
            routeContext = await currentRouteContext()
        }
        await refreshActiveRouteSnapshot(using: routeContext)
    }

    private func refreshActiveRouteSnapshotIfNeeded() async {
        let routeContext = await currentRouteContext()
        guard routeContext != latestRouteContext else {
            updatePasteInterceptState()
            return
        }
        await refreshActiveRouteSnapshot(using: routeContext)
    }

    private func refreshActiveRouteSnapshotForClipboardUpdate() async {
        if let latestRouteContext {
            await refreshActiveRouteSnapshot(using: latestRouteContext)
            return
        }

        await refreshActiveRouteSnapshot(forceContextRefresh: true)
    }

    private func refreshActiveRouteSnapshot(using routeContext: ClipboardRouteContext) async {
        let snapshot = await deliveryStack.routeSnapshot(for: routeContext)
        await handleRouteSnapshot(snapshot, routeContext: routeContext)
    }

    private func handleRouteSnapshot(
        _ snapshot: ClipboardRouteSnapshot,
        routeContext: ClipboardRouteContext
    ) async {
        let shouldPublishStackUpdate =
            snapshot.count != latestRouteSnapshot.count
            || snapshot.previewText != latestRouteSnapshot.previewText
        latestRouteContext = routeContext
        latestRouteSnapshot = snapshot
        if shouldPublishStackUpdate {
            await eventBus.publish(
                .stackUpdated(
                    DeliveryStackSnapshot(
                        count: snapshot.count,
                        topPreview: snapshot.previewText
                    )
                )
            )
        }
        updatePasteInterceptState()

        guard snapshot.count > 0, let previewSnapshot = snapshot.previewSnapshot else {
            mirroredPreview = nil
            if preservedClipboard != nil || ownedChangeCount != nil {
                await restorePreservedClipboardIfNeeded()
            }
            return
        }

        let preview = MirroredClipboardPreview(snapshot: previewSnapshot)
        if preservedClipboard == nil {
            preservedClipboard = await pasteboard.currentSnapshot()
        }

        guard mirroredPreview != preview else { return }

        ownedChangeCount = await pasteboard.writeSnapshot(previewSnapshot)
        lastObservedPasteboardChangeCount = ownedChangeCount
        mirroredPreview = preview

        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: .debug,
                    event: "clipboard.preview.mirrored",
                    message: "Mirrored the active clipboard item to the system clipboard.",
                    metadata: [
                        "count": String(snapshot.count),
                        "groupID": snapshot.activeGroup.group.id.uuidString,
                        "groupName": snapshot.activeGroup.group.name,
                    ]
                )
            )
        }
    }

    private func pasteMirroredClipboardItem(for routeContext: ClipboardRouteContext) async {
        let stackWorkflow = WorkflowPresentation(fallbackName: "Stack Delivery", titleKey: .stackDelivery)
        guard let lease = await deliveryStack.beginDeliveryLease(for: routeContext) else { return }

        do {
            try simulatePaste()
            try? await Task.sleep(for: .milliseconds(120))
            await deliveryStack.completeDelivery(leaseID: lease.leaseID)
        } catch {
            await deliveryStack.failDelivery(leaseID: lease.leaseID, error: error.localizedDescription)
            await eventBus.publish(
                .runFailed(
                    runID: nil,
                    workflow: stackWorkflow,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func captureExternalClipboardIfNeeded() async {
        let observedChangeCount = await currentSystemPasteboardChangeCount()
        guard observedChangeCount != lastObservedPasteboardChangeCount else { return }

        let snapshot = await pasteboard.currentSnapshot()
        lastObservedPasteboardChangeCount = snapshot.changeCount

        guard snapshot.hasTransferableContent else { return }
        guard !snapshot.excludesWorkflowCapture else { return }
        let isOwnedChangeCount = await pasteboard.isOwnedChangeCount(snapshot.changeCount)
        guard !isOwnedChangeCount else { return }

        preservedClipboard = snapshot
        let routeContext = await currentRouteContext()
        latestRouteContext = routeContext
        await deliveryStack.captureSystemClipboard(snapshot: snapshot, context: routeContext)
    }

    private func restorePreservedClipboardIfNeeded() async {
        guard let preservedClipboard, let ownedChangeCount else {
            self.preservedClipboard = nil
            self.ownedChangeCount = nil
            mirroredPreview = nil
            return
        }

        let restored = await pasteboard.restore(preservedClipboard, ifChangeCountIs: ownedChangeCount)
        if restored {
            lastObservedPasteboardChangeCount = await currentSystemPasteboardChangeCount()
        }
        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    subsystem: .clipboard,
                    level: restored ? .info : .debug,
                    event: restored ? "clipboard.preview.restored" : "clipboard.preview.restore-skipped",
                    message: restored
                        ? "Restored the clipboard after the active clipboard route became empty."
                        : "Skipped restoring the clipboard because it changed outside VoxType ownership."
                )
            )
        }

        self.preservedClipboard = nil
        self.ownedChangeCount = nil
        mirroredPreview = nil
    }

    private func handleHotkey(_ event: HotkeyEventTap.Event) async {
        switch event {
        case .manualPasteInterceptRequested:
            await pasteTopOfStack()
        case .clipboardPanelRequested:
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
            }
            await eventBus.publish(.clipboardPanelRequested)
        case .pushToTalkPressed, .pushToTalkReleased, .customHotkey(_):
            break
        }
    }

    private func currentRouteContext() async -> ClipboardRouteContext {
        let frontmostApplication = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }

        if let frontmostApplication {
            return ClipboardRouteContext(
                applicationName: frontmostApplication.localizedName,
                bundleIdentifier: frontmostApplication.bundleIdentifier
            )
        }

        let context = await contextProvider.captureContext()
        return ClipboardRouteContext(
            applicationName: context.focus.applicationName,
            bundleIdentifier: context.focus.bundleIdentifier
        )
    }

    private func currentSystemPasteboardChangeCount() async -> Int {
        await MainActor.run {
            NSPasteboard.general.changeCount
        }
    }

    private func simulatePaste() throws {
        let keyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw TextInjectionEngine.InjectionError.unableToCreatePasteEvent
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func updatePasteInterceptState() {
        hotkeyTap.setPasteInterceptEnabled(
            latestRouteSnapshot.count > 0 && accessibilityChecker() && !isDeliveryInProgress
        )
    }
}
