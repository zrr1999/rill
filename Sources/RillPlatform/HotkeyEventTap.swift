import ApplicationServices
import Foundation
import RillCore

struct HotkeyEventTapHealthChecker<Handle> {
    let isValid: (Handle) -> Bool
    let isEnabled: (Handle) -> Bool
    let enable: (Handle) -> Void

    func ensureAvailable(_ handle: Handle) -> Bool {
        guard isValid(handle) else { return false }
        if !isEnabled(handle) {
            enable(handle)
        }
        return isValid(handle) && isEnabled(handle)
    }
}

private extension HotkeyEventTapHealthChecker where Handle == CFMachPort {
    static var system: Self {
        Self(
            isValid: { CFMachPortIsValid($0) },
            isEnabled: { CGEvent.tapIsEnabled(tap: $0) },
            enable: { CGEvent.tapEnable(tap: $0, enable: true) }
        )
    }
}

public final class HotkeyEventTap: @unchecked Sendable {
    public enum PushToTalkGesture: String, Sendable, Equatable {
        case fnHold = "fn-hold"
        case controlOptionShiftSpace = "control-option-shift-space"
    }

    public enum Event: Sendable, Equatable {
        case manualPasteInterceptRequested
        case clipboardPanelRequested
        case pushToTalkPressed(PushToTalkGesture)
        case pushToTalkReleased(PushToTalkGesture)
        case liveAudioCancellationRequested(UUID)
        case globalInputUnavailable
        case customHotkey(String)
    }

    private static let pasteKeyCode: CGKeyCode = 9
    static let escapeKeyCode: CGKeyCode = 53
    static let legacyPushToTalkKeyCode: CGKeyCode = 49
    static let legacyPushToTalkModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    static let functionKeyCode: CGKeyCode = 63
    static let globeKeyCode: CGKeyCode = 179
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let tap = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var eventTapThread: Thread?
    private var retainedSelfPointer: UnsafeMutableRawPointer?
    private var pasteInterceptEnabled = false
    private var skippedPasteEvents = 0
    private var clipboardPanelShortcutEnabled = false
    private var clipboardPanelShortcutRecordingSuspensions: Set<UUID> = []
    private var clipboardPanelShortcutRecordingCommitKeyCodes: [UUID: CGKeyCode] = [:]
    private var clipboardPanelHotkeyBinding: HotkeyBindingDescriptor = .doubleCommand
    private var doubleCommandTapRecognizer = DoubleCommandTapRecognizer()
    private var clipboardPanelShortcutRecognizer = ClipboardPanelShortcutRecognizer()
    private var pushToTalkRecognizer = PushToTalkGestureRecognizer()
    private var liveAudioEscapeRecognizer = LiveAudioEscapeRecognizer()
    private let monotonicClock = ContinuousClock()
    private let eventTapHealthChecker: HotkeyEventTapHealthChecker<CFMachPort>
    private let physicalKeyStateProvider: @Sendable (CGKeyCode) -> Bool
    private let pushToTalkGestureStateProvider: @Sendable (PushToTalkGesture) -> Bool

    public init() {
        eventTapHealthChecker = .system
        physicalKeyStateProvider = {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        }
        pushToTalkGestureStateProvider = Self.systemPushToTalkGestureIsActive
    }

    init(
        physicalKeyStateProvider: @escaping @Sendable (CGKeyCode) -> Bool,
        pushToTalkGestureStateProvider: @escaping @Sendable (PushToTalkGesture) -> Bool =
            HotkeyEventTap.systemPushToTalkGestureIsActive
    ) {
        eventTapHealthChecker = .system
        self.physicalKeyStateProvider = physicalKeyStateProvider
        self.pushToTalkGestureStateProvider = pushToTalkGestureStateProvider
    }

    init(
        eventTapHealthChecker: HotkeyEventTapHealthChecker<CFMachPort>,
        physicalKeyStateProvider: @escaping @Sendable (CGKeyCode) -> Bool = {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        },
        pushToTalkGestureStateProvider: @escaping @Sendable (PushToTalkGesture) -> Bool =
            HotkeyEventTap.systemPushToTalkGestureIsActive
    ) {
        self.eventTapHealthChecker = eventTapHealthChecker
        self.physicalKeyStateProvider = physicalKeyStateProvider
        self.pushToTalkGestureStateProvider = pushToTalkGestureStateProvider
    }

    deinit {
        uninstall()
    }

    public func stream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            withLock {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self, id] _ in
                self?.removeContinuation(id)
            }
        }
    }

    /// Enables global Escape cancellation only while one live-audio run owns
    /// the nonactivating recording surface. Idle Escape events keep flowing to
    /// the foreground application unchanged.
    public func setLiveAudioEscapeCancellationRunID(_ runID: UUID?) {
        withLock {
            liveAudioEscapeRecognizer.setActiveRunID(runID)
        }
    }

    public func setPasteInterceptEnabled(_ enabled: Bool) {
        withLock {
            pasteInterceptEnabled = enabled
            if !enabled {
                // A bypass token is only meaningful while interception is active. If
                // interception is disabled before the synthetic paste arrives, that
                // event passes through naturally and must not leave a token that can
                // suppress a later user-initiated paste.
                skippedPasteEvents = 0
            }
        }
    }

    public func skipNextPasteInterception(count: Int = 1) {
        guard count > 0 else { return }
        withLock {
            guard pasteInterceptEnabled else { return }
            skippedPasteEvents += count
        }
    }

    func testingIsPasteInterceptEnabled() -> Bool {
        isPasteInterceptEnabled
    }

    func testingSkippedPasteEventCount() -> Int {
        withLock { skippedPasteEvents }
    }

    public func setClipboardPanelHotkeyBinding(_ binding: HotkeyBindingDescriptor) {
        withLock {
            switch binding {
            case .doubleCommand:
                clipboardPanelHotkeyBinding = binding
            case .keyboardShortcut(let shortcut) where GlobalHotkeyPolicy.accepts(shortcut):
                clipboardPanelHotkeyBinding = binding
            case .keyboardShortcut:
                clipboardPanelHotkeyBinding = .doubleCommand
            }
            clipboardPanelShortcutRecognizer.reset()
            doubleCommandTapRecognizer.reset()
        }
    }

    /// Enables only the clipboard-panel shortcut route. The shared event tap and
    /// push-to-talk recognizer remain active so turning clipboard capture off does
    /// not disable voice input.
    public func setClipboardPanelShortcutEnabled(_ enabled: Bool) {
        withLock {
            clipboardPanelShortcutEnabled = enabled
            if !enabled {
                clipboardPanelShortcutRecognizer.reset()
                doubleCommandTapRecognizer.reset()
            }
        }
    }

    /// Temporarily gives an in-app shortcut recorder ownership of new global
    /// shortcut presses. A push-to-talk gesture that was already active keeps
    /// its release route so opening the recorder can never strand a capture.
    public func beginClipboardPanelShortcutRecording() -> UUID {
        let suspensionID = UUID()
        withLock {
            clipboardPanelShortcutRecordingSuspensions.insert(suspensionID)
            clipboardPanelShortcutRecordingCommitKeyCodes.removeValue(forKey: suspensionID)
            clipboardPanelShortcutRecognizer.reset()
            doubleCommandTapRecognizer.reset()
        }
        return suspensionID
    }

    /// Releases one recorder lease. Repeated or stale releases are harmless,
    /// and the capture preference remains the authoritative feature-level gate.
    public func endClipboardPanelShortcutRecording(_ suspensionID: UUID) {
        withLock {
            guard clipboardPanelShortcutRecordingSuspensions.remove(suspensionID) != nil else {
                return
            }
            clipboardPanelShortcutRecordingCommitKeyCodes.removeValue(forKey: suspensionID)
            clipboardPanelShortcutRecognizer.reset()
            doubleCommandTapRecognizer.reset()
        }
    }

    /// Transfers a recorder lease to the event tap until the physical commit
    /// key is released. Repeats and the matching key-up are consumed by this
    /// latch, and new push-to-talk presses remain suspended until it retires.
    public func commitClipboardPanelShortcutRecording(
        _ suspensionID: UUID,
        keyCode: UInt16
    ) {
        withLock {
            guard clipboardPanelShortcutRecordingSuspensions.contains(suspensionID) else {
                return
            }
            let commitKeyCode = CGKeyCode(keyCode)
            if physicalKeyStateProvider(commitKeyCode) {
                clipboardPanelShortcutRecordingCommitKeyCodes[suspensionID] = commitKeyCode
            } else {
                // The event tap can observe a fast key-up before the main thread
                // commits the recorder decision. Retire that lease immediately;
                // no later key-up exists to release a commit latch safely.
                clipboardPanelShortcutRecordingSuspensions.remove(suspensionID)
                clipboardPanelShortcutRecordingCommitKeyCodes.removeValue(forKey: suspensionID)
            }
            clipboardPanelShortcutRecognizer.reset()
            doubleCommandTapRecognizer.reset()
        }
    }

    public func isPushToTalkGestureActive(_ gesture: PushToTalkGesture) -> Bool {
        pushToTalkGestureStateProvider(gesture)
    }

    private static func systemPushToTalkGestureIsActive(_ gesture: PushToTalkGesture) -> Bool {
        switch gesture {
        case .fnHold:
            return CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        case .controlOptionShiftSpace:
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let relevantFlags = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            return relevantFlags == Self.legacyPushToTalkModifiers
                && CGEventSource.keyState(.combinedSessionState, key: Self.legacyPushToTalkKeyCode)
        }
    }
}

extension HotkeyEventTap {
    @discardableResult
    public func install() -> Bool {
        if let existingTap = withLock({ eventTap }) {
            let isAvailable = eventTapHealthChecker.ensureAvailable(existingTap)
            if !isAvailable {
                requestEventTapTeardown(expectedTap: existingTap)
            }
            return isAvailable
        }

        let installationSemaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runEventTapLoop(installationSemaphore: installationSemaphore)
        }
        thread.name = "dev.rill.hotkey-event-tap"
        withLock {
            eventTapThread = thread
        }
        thread.start()
        installationSemaphore.wait()
        guard let installedTap = withLock({ eventTap }) else { return false }
        let isAvailable = eventTapHealthChecker.ensureAvailable(installedTap)
        if !isAvailable {
            requestEventTapTeardown(expectedTap: installedTap)
        }
        return isAvailable
    }

    public func uninstall() {
        let teardownState = withLock { () -> (CFMachPort?, CFRunLoop?, Thread?) in
            (eventTap, eventTapRunLoop, eventTapThread)
        }
        guard let tap = teardownState.0 else {
            return
        }
        guard let runLoop = teardownState.1 else {
            teardownEventTap(on: nil, expectedTap: tap)
            return
        }

        if Thread.current == teardownState.2 {
            teardownEventTap(on: runLoop, expectedTap: tap)
            return
        }

        let teardownSemaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.teardownEventTap(on: runLoop, expectedTap: tap)
            teardownSemaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        if teardownSemaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            // The run loop can exit after the state snapshot but before the
            // scheduled block runs. Fall back to idempotent direct teardown
            // instead of waiting forever on a stopped run loop.
            teardownEventTap(on: nil, expectedTap: tap)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runEventTapLoop(installationSemaphore: DispatchSemaphore) {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            let retainedPointer = Unmanaged.passRetained(self).toOpaque()
            let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.keyUp.rawValue)
                | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: Self.callback,
                userInfo: retainedPointer
            ) else {
                Unmanaged<HotkeyEventTap>.fromOpaque(retainedPointer).release()
                withLock {
                    eventTapThread = nil
                }
                installationSemaphore.signal()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            withLock {
                eventTap = tap
                runLoopSource = source
                eventTapRunLoop = runLoop
                retainedSelfPointer = retainedPointer
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            let isAvailable = eventTapHealthChecker.ensureAvailable(tap)
            if !isAvailable {
                teardownEventTap(on: runLoop, expectedTap: tap)
            }
            installationSemaphore.signal()
            guard isAvailable else { return }
            defer {
                teardownEventTap(on: runLoop, expectedTap: tap)
            }
            CFRunLoopRun()
        }
    }

    private func requestEventTapTeardown(expectedTap: CFMachPort) {
        let teardownState = withLock { () -> (CFRunLoop?, Thread?) in
            (eventTapRunLoop, eventTapThread)
        }
        guard let runLoop = teardownState.0 else {
            teardownEventTap(on: nil, expectedTap: expectedTap)
            return
        }
        if Thread.current == teardownState.1 || teardownState.1?.isFinished == true {
            teardownEventTap(on: runLoop, expectedTap: expectedTap)
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.teardownEventTap(on: runLoop, expectedTap: expectedTap)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func teardownEventTap(on runLoop: CFRunLoop?, expectedTap: CFMachPort) {
        let state = withLock {
            () -> (CFMachPort, CFRunLoopSource?, UnsafeMutableRawPointer?)? in
            guard let currentTap = eventTap, currentTap === expectedTap else { return nil }
            resetRecognizersForEventTapTeardown()
            let state = (currentTap, runLoopSource, retainedSelfPointer)
            eventTap = nil
            runLoopSource = nil
            eventTapRunLoop = nil
            eventTapThread = nil
            retainedSelfPointer = nil
            return state
        }
        guard let state else { return }
        let tap = state.0
        if let runLoop, let source = state.1 {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        // Invalidating the Mach port also invalidates its run-loop source, so
        // the bounded direct fallback does not need to remove that source from
        // a run loop that may already have stopped on another thread.
        CFMachPortInvalidate(tap)
        emit(.globalInputUnavailable)
        if let pointer = state.2 {
            Unmanaged<HotkeyEventTap>.fromOpaque(pointer).release()
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private func resetRecognizersForEventTapTeardown() {
        // A committed recorder lease can only finish by observing its key-up.
        // Once this tap is gone, retaining that lease would disable the panel
        // route forever after reinstall. Keep still-active UI recorder leases,
        // whose owner can end them explicitly, but retire every committed one.
        releaseCommittedClipboardPanelShortcutRecordingSuspensions { _ in true }
        doubleCommandTapRecognizer.reset()
        clipboardPanelShortcutRecognizer.reset()
        skippedPasteEvents = 0
        liveAudioEscapeRecognizer.reset()
        _ = pushToTalkRecognizer.interrupt()
    }

    private func prepareRecognizersForEventTapRecovery() -> Event? {
        // A timeout can consume the physical key-up. Release only commits whose
        // key is already up; a still-held key keeps its latch so autorepeat cannot
        // trigger the newly installed panel binding after the tap is re-enabled.
        // A second check after re-enabling closes the interval between this sample
        // and `CGEvent.tapEnable`, where a release would otherwise remain unseen.
        releaseCommittedClipboardPanelShortcutRecordingSuspensions {
            !physicalKeyStateProvider($0)
        }
        clipboardPanelShortcutRecognizer.reset()
        doubleCommandTapRecognizer.reset()
        skippedPasteEvents = 0
        liveAudioEscapeRecognizer.resetLatch()
        let activeGesture = pushToTalkRecognizer.activeGesture
        let shouldPreserveActiveTrigger = activeGesture.map {
            isPushToTalkGestureActive($0)
        } ?? false
        return pushToTalkRecognizer.interrupt(
            preservingActiveTrigger: shouldPreserveActiveTrigger
        )
    }

    private func completeRecognizersForEventTapRecovery() {
        // The tap is enabled before this sample. Commits and an interrupted
        // push-to-talk gesture that went up during re-enable can no longer receive
        // their physical release, so retire those latches now. The interruption
        // already published the push-to-talk release; clearing that latch here must
        // remain silent. Still-held inputs stay latched until the recovered tap
        // observes their future key-up.
        releaseCommittedClipboardPanelShortcutRecordingSuspensions {
            !physicalKeyStateProvider($0)
        }
        guard let interruptedGesture = pushToTalkRecognizer.interruptedActiveGesture else { return }
        guard !isPushToTalkGestureActive(interruptedGesture) else { return }
        pushToTalkRecognizer.clearInterruptedActiveTrigger()
    }

    private func releaseCommittedClipboardPanelShortcutRecordingSuspensions(
        where shouldRelease: (CGKeyCode) -> Bool
    ) {
        let releasableSuspensions = clipboardPanelShortcutRecordingCommitKeyCodes
            .compactMap { suspensionID, keyCode in
                shouldRelease(keyCode) ? suspensionID : nil
            }
        for suspensionID in releasableSuspensions {
            clipboardPanelShortcutRecordingCommitKeyCodes.removeValue(
                forKey: suspensionID
            )
            clipboardPanelShortcutRecordingSuspensions.remove(suspensionID)
        }
    }
}

extension HotkeyEventTap {
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let recovery = withLock { () -> (Event?, CFMachPort?) in
                return (
                    prepareRecognizersForEventTapRecovery(),
                    eventTap
                )
            }
            // A release can be lost while the tap is disabled. First publish a
            // recoverable release for a latched gesture; if re-enabling fails,
            // teardown publishes globalInputUnavailable so pending, hold, and
            // toggle recordings all fail closed without a future key-up event.
            if let releaseEvent = recovery.0 {
                emit(releaseEvent)
            }
            if let tap = recovery.1 {
                if eventTapHealthChecker.ensureAvailable(tap) {
                    withLock {
                        guard eventTap === tap else { return }
                        completeRecognizersForEventTapRecovery()
                    }
                } else {
                    requestEventTapTeardown(expectedTap: tap)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if handleClipboardPanelShortcutRecordingCommitKey(
            type: type,
            keyCode: keyCode
        ) {
            return nil
        }
        let shouldOpenClipboardPanel = handleDoubleCommandPanelShortcut(
            type: type,
            keyCode: keyCode,
            flags: event.flags,
            at: monotonicClock.now
        )
        if shouldOpenClipboardPanel {
            emit(.clipboardPanelRequested)
        }

        let escapeHandling = handleLiveAudioEscape(
            type: type,
            keyCode: keyCode,
            flags: event.flags
        )
        switch escapeHandling {
        case .passThrough:
            break
        case .swallow(let runID):
            if let runID {
                emit(.liveAudioCancellationRequested(runID))
            }
            return nil
        }

        let pushToTalkHandling = handlePushToTalk(type: type, keyCode: keyCode, flags: event.flags)
        switch pushToTalkHandling {
        case .passThrough:
            break
        case .swallow(let emittedEvent):
            if let emittedEvent {
                emit(emittedEvent)
            }
            return nil
        }

        let clipboardPanelHandling = handleClipboardPanelShortcut(
            type: type,
            keyCode: keyCode,
            flags: event.flags
        )
        switch clipboardPanelHandling {
        case .passThrough:
            break
        case .swallow(let shouldEmit):
            if shouldEmit {
                emit(.clipboardPanelRequested)
            }
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        guard keyCode == Self.pasteKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        guard event.flags.contains(.maskCommand), isPasteInterceptEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if shouldAllowBypassedPasteEvent() {
            return Unmanaged.passUnretained(event)
        }

        emit(.manualPasteInterceptRequested)
        return nil
    }

    private var isPasteInterceptEnabled: Bool {
        withLock {
            pasteInterceptEnabled
        }
    }

    private func handleLiveAudioEscape(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> LiveAudioEscapeRecognizerOutput {
        withLock {
            liveAudioEscapeRecognizer.handle(type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func handleDoubleCommandPanelShortcut(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        withLock {
            guard isClipboardPanelShortcutRouteEnabled,
                  clipboardPanelHotkeyBinding == .doubleCommand
            else {
                doubleCommandTapRecognizer.reset()
                return false
            }
            return doubleCommandTapRecognizer.handle(
                type: type,
                keyCode: keyCode,
                flags: flags,
                at: instant
            )
        }
    }

    private func handlePushToTalk(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> PushToTalkGestureRecognizerOutput {
        withLock {
            if !clipboardPanelShortcutRecordingSuspensions.isEmpty,
               pushToTalkRecognizer.activeGesture == nil {
                // The app-local recorder must receive ordinary key events so
                // it can reject reserved voice chords with its normal feedback.
                // Only an already-latched voice gesture may continue through
                // this gate, because its release is required to stop capture.
                return .passThrough
            }
            return pushToTalkRecognizer.handle(type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func handleClipboardPanelShortcut(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> ClipboardPanelShortcutRecognizerOutput {
        withLock {
            guard isClipboardPanelShortcutRouteEnabled else {
                clipboardPanelShortcutRecognizer.reset()
                return .passThrough
            }
            return clipboardPanelShortcutRecognizer.handle(
                type: type,
                keyCode: keyCode,
                flags: flags,
                binding: clipboardPanelHotkeyBinding
            )
        }
    }

    private func handleClipboardPanelShortcutRecordingCommitKey(
        type: CGEventType,
        keyCode: CGKeyCode
    ) -> Bool {
        withLock {
            guard type == .keyDown || type == .keyUp else { return false }
            let matchingSuspensions = clipboardPanelShortcutRecordingCommitKeyCodes
                .compactMap { suspensionID, commitKeyCode in
                    commitKeyCode == keyCode ? suspensionID : nil
                }
            guard !matchingSuspensions.isEmpty else { return false }

            if type == .keyUp {
                for suspensionID in matchingSuspensions {
                    clipboardPanelShortcutRecordingCommitKeyCodes.removeValue(
                        forKey: suspensionID
                    )
                    clipboardPanelShortcutRecordingSuspensions.remove(suspensionID)
                }
                clipboardPanelShortcutRecognizer.reset()
                doubleCommandTapRecognizer.reset()
            }
            return true
        }
    }

    private func emit(_ event: Event) {
        let activeContinuations = withLock {
            Array(continuations.values)
        }
        for continuation in activeContinuations {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        withLock {
            continuations.removeValue(forKey: id)
        }
    }

    private func shouldAllowBypassedPasteEvent() -> Bool {
        withLock {
            guard skippedPasteEvents > 0 else { return false }
            skippedPasteEvents -= 1
            return true
        }
    }

    func testingIsClipboardPanelShortcutEnabled() -> Bool {
        withLock { isClipboardPanelShortcutRouteEnabled }
    }

    func testingHandleDoubleCommandPanelShortcut(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        handleDoubleCommandPanelShortcut(
            type: type,
            keyCode: keyCode,
            flags: flags,
            at: instant
        )
    }

    func testingHandlePushToTalk(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> PushToTalkGestureRecognizerOutput {
        handlePushToTalk(type: type, keyCode: keyCode, flags: flags)
    }

    func testingHandleLiveAudioEscape(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> LiveAudioEscapeRecognizerOutput {
        handleLiveAudioEscape(type: type, keyCode: keyCode, flags: flags)
    }

    func testingHandleClipboardPanelShortcut(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> ClipboardPanelShortcutRecognizerOutput {
        handleClipboardPanelShortcut(type: type, keyCode: keyCode, flags: flags)
    }

    func testingHandleClipboardPanelShortcutRecordingCommitKey(
        type: CGEventType,
        keyCode: CGKeyCode
    ) -> Bool {
        handleClipboardPanelShortcutRecordingCommitKey(type: type, keyCode: keyCode)
    }

    func testingEmit(_ event: Event) {
        emit(event)
    }

    func testingInterruptPushToTalk(
        preservingActiveTrigger: Bool
    ) -> Event? {
        withLock {
            pushToTalkRecognizer.interrupt(
                preservingActiveTrigger: preservingActiveTrigger
            )
        }
    }

    func testingResetRecognizersForEventTapTeardown() -> Event {
        withLock {
            resetRecognizersForEventTapTeardown()
        }
        return .globalInputUnavailable
    }

    func testingPrepareRecognizersForEventTapRecovery() -> Event? {
        withLock {
            prepareRecognizersForEventTapRecovery()
        }
    }

    func testingCompleteRecognizersForEventTapRecovery() {
        withLock {
            completeRecognizersForEventTapRecovery()
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var isClipboardPanelShortcutRouteEnabled: Bool {
        clipboardPanelShortcutEnabled && clipboardPanelShortcutRecordingSuspensions.isEmpty
    }
}
