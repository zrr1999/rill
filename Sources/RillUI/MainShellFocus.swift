import AppKit
import SwiftUI
import RillCore

enum SidebarDestination: Hashable {
    case section(SidebarSection)
    case recordCollection(RecordCollectionID)
    case workflow(UUID)
}

enum SidebarRouteFocusClaimOrigin {
    case list
    case programmatic
}

final class SidebarFocusCoordinator {
    typealias RouteFocusClaim = UInt64

    enum FocusRestoration: Equatable {
        case none
        case sidebar
        case detail
    }

    enum RouteFocusRepairPhase: Equatable {
        case routeReconciliation
        case protectNewFocus
    }

    weak var anchorView: NSView?
    weak var detailAnchorView: NSView?
    private var nextRouteFocusClaim: RouteFocusClaim = 0
    private(set) var activeRouteFocusClaim: RouteFocusClaim?
    private var activeRouteFocusClaimOrigin: SidebarRouteFocusClaimOrigin?
    private var activeRouteFocusClaimDestination: SidebarDestination?

    func hasActiveListRouteFocusClaim(for destination: SidebarDestination) -> Bool {
        activeRouteFocusClaim != nil
            && activeRouteFocusClaimOrigin == .list
            && activeRouteFocusClaimDestination == destination
    }

    func claimSidebarFocusForRoute(
        origin: SidebarRouteFocusClaimOrigin,
        destination: SidebarDestination
    ) -> RouteFocusClaim? {
        guard let (window, sidebar) = sidebarContext() else { return nil }

        nextRouteFocusClaim &+= 1
        let claim = nextRouteFocusClaim
        activeRouteFocusClaim = claim
        activeRouteFocusClaimOrigin = origin
        activeRouteFocusClaimDestination = destination
        guard window.makeFirstResponder(sidebar) else {
            completeRouteFocusClaim(claim)
            return nil
        }
        return claim
    }

    @discardableResult
    func restoreFocus(
        routeClaimID: RouteFocusClaim? = nil,
        phase: RouteFocusRepairPhase = .protectNewFocus
    ) -> FocusRestoration {
        if let routeClaimID, activeRouteFocusClaim != routeClaimID {
            return .none
        }
        if let (window, sidebar) = sidebarContext() {
            if Self.isResponder(window.firstResponder, inside: sidebar) {
                return .sidebar
            }
            if phase == .routeReconciliation, routeClaimID != nil {
                // No independent detail interaction can legally occur inside the
                // same sidebar mouse-selection turn. Rehome unconditionally so a
                // departing detail responder cannot masquerade as newer focus.
                return window.makeFirstResponder(sidebar) ? .sidebar : .none
            }
            // A delayed post-route repair must never override a newer, valid user
            // focus in the committed detail (for example Clipboard search). Object
            // identity is deliberately irrelevant: a persistent control can be
            // focused again after the route commits, and that is a new interaction
            // even when it is the same responder seen before the route. Keep the
            // route claim alive for its bounded recheck; only a later detached or
            // empty responder state represents focus loss this coordinator owns.
            if phase == .protectNewFocus,
                Self.isLiveInteractiveResponder(window.firstResponder, in: window)
            {
                return .none
            }
            return window.makeFirstResponder(sidebar) ? .sidebar : .none
        }

        // A collapsed NavigationSplitView has no stable sidebar responder.
        // Repair only a genuine vacuum after the new detail has committed;
        // every live responder, including a field editor, represents newer
        // user/detail ownership and must win. The anchor is intentionally not
        // an accessibility element, so this keyboard fallback cannot move an
        // independent VoiceOver focus.
        guard phase == .protectNewFocus,
            let (window, detailAnchor) = detailContext(),
            Self.isKeyboardFocusVacuum(window.firstResponder, in: window)
        else {
            return .none
        }
        return window.makeFirstResponder(detailAnchor) ? .detail : .none
    }

    func completeRouteFocusClaim(_ claim: RouteFocusClaim) {
        guard activeRouteFocusClaim == claim else { return }
        activeRouteFocusClaim = nil
        activeRouteFocusClaimOrigin = nil
        activeRouteFocusClaimDestination = nil
    }

    func cancelActiveRouteFocusClaim() {
        guard let activeRouteFocusClaim else { return }
        completeRouteFocusClaim(activeRouteFocusClaim)
    }

    private func sidebarContext() -> (window: NSWindow, sidebar: NSTableView)? {
        guard let window = anchorView?.window,
            let contentView = window.contentView,
            let sidebar = Self.sidebarTable(anchor: anchorView, in: contentView),
            sidebar.window === window,
            !sidebar.isHiddenOrHasHiddenAncestor,
            !sidebar.visibleRect.isEmpty
        else {
            return nil
        }
        return (window, sidebar)
    }

    private func detailContext() -> (window: NSWindow, anchor: NSView)? {
        guard let detailAnchorView,
            let window = detailAnchorView.window,
            !detailAnchorView.isHiddenOrHasHiddenAncestor
        else {
            return nil
        }
        return (window, detailAnchorView)
    }

    private static func sidebarTable(anchor: NSView?, in root: NSView) -> NSTableView? {
        var ancestor = anchor
        while let view = ancestor {
            if let table = view as? NSTableView {
                return table
            }
            if let table = view.enclosingScrollView?.documentView as? NSTableView {
                return table
            }
            ancestor = view.superview
        }
        return descendantTables(in: root).min { lhs, rhs in
            let lhsFrame = lhs.convert(lhs.bounds, to: nil)
            let rhsFrame = rhs.convert(rhs.bounds, to: nil)
            if lhsFrame.minX != rhsFrame.minX {
                return lhsFrame.minX < rhsFrame.minX
            }
            return lhsFrame.height > rhsFrame.height
        }
    }

    private static func descendantTables(in root: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let table = root as? NSTableView {
            result.append(table)
        }
        for child in root.subviews {
            result.append(contentsOf: descendantTables(in: child))
        }
        return result
    }

    private static func isResponder(_ responder: NSResponder?, inside view: NSView) -> Bool {
        guard let responder = normalizedResponder(responder) else { return false }
        if responder === view { return true }
        guard let responderView = responder as? NSView else { return false }
        return responderView.isDescendant(of: view)
    }

    private static func normalizedResponder(_ responder: NSResponder?) -> NSResponder? {
        if let fieldEditor = responder as? NSTextView,
            fieldEditor.isFieldEditor,
            let control = fieldEditor.delegate as? NSResponder
        {
            return control
        }
        return responder
    }

    private static func isLiveInteractiveResponder(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> Bool {
        if let fieldEditor = responder as? NSTextView,
            fieldEditor.isFieldEditor,
            let control = fieldEditor.delegate as? NSView
        {
            return control.window === window && !control.isHiddenOrHasHiddenAncestor
        }
        guard let view = responder as? NSView,
            view.window === window,
            !view.isHiddenOrHasHiddenAncestor
        else {
            return false
        }
        return true
    }

    private static func isKeyboardFocusVacuum(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> Bool {
        guard let responder = normalizedResponder(responder) else { return true }
        if responder === window { return true }
        guard let responderView = responder as? NSView else { return false }
        return responderView.window !== window || responderView.isHiddenOrHasHiddenAncestor
    }
}

struct SidebarFocusAnchor: NSViewRepresentable {
    let coordinator: SidebarFocusCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        coordinator.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        coordinator.anchorView = view
    }
}

struct DetailFocusAnchor: NSViewRepresentable {
    let coordinator: SidebarFocusCoordinator

    func makeNSView(context: Context) -> DetailKeyboardFocusAnchorView {
        let view = DetailKeyboardFocusAnchorView(frame: .zero)
        coordinator.detailAnchorView = view
        return view
    }

    func updateNSView(_ view: DetailKeyboardFocusAnchorView, context: Context) {
        coordinator.detailAnchorView = view
    }
}

final class DetailKeyboardFocusAnchorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("main-detail-focus-anchor")
        setAccessibilityElement(false)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        let unsupportedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard event.keyCode == 48, unsupportedModifiers.isEmpty, let window else {
            super.keyDown(with: event)
            return
        }

        let previousResponder = window.firstResponder
        window.recalculateKeyViewLoop()
        if event.modifierFlags.contains(.shift) {
            window.selectPreviousKeyView(self)
        } else {
            window.selectNextKeyView(self)
        }
        if window.firstResponder === previousResponder {
            super.keyDown(with: event)
        }
    }
}

@MainActor
func waitForMainRunLoopDefaultMode() async {
    let waiter = MainRunLoopTurnWaiter()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            waiter.install(continuation)
            scheduleOnMainRunLoopDefaultMode {
                waiter.resume()
            }
        }
    } onCancel: {
        waiter.resume()
    }
}

@MainActor
func scheduleOnMainRunLoopDefaultMode(
    _ operation: @escaping @MainActor @Sendable () -> Void
) {
    RunLoop.main.perform(inModes: [.default]) {
        MainActor.assumeIsolated {
            operation()
        }
    }
}

@MainActor
func scheduleOnMainRunLoopInteractiveModes(
    _ operation: @escaping @MainActor @Sendable () -> Void
) {
    RunLoop.main.perform(inModes: [.eventTracking, .common]) {
        MainActor.assumeIsolated {
            operation()
        }
    }
}

private final class MainRunLoopTurnWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCompleted = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isCompleted {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
