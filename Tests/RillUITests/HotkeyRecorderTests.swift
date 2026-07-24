import AppKit
import XCTest
@testable import RillCore
@testable import RillUI

final class HotkeyRecorderTests: XCTestCase {
    func testEscapeCancelsRecording() {
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(
                keyCode: 53,
                modifiers: [.command, .option]
            ),
            .cancel
        )
    }

    func testTabCancelsRecordingAndMovesFocusInRequestedDirection() {
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(keyCode: 48, modifiers: []),
            .moveFocus(forward: true)
        )
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(keyCode: 48, modifiers: [.shift]),
            .moveFocus(forward: false)
        )
    }

    func testModifierOnlyKeyDoesNotEndRecording() {
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(keyCode: 55, modifiers: [.command]),
            .ignore
        )
    }

    func testUnsafeOrUnmodifiedKeyIsRejected() {
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(keyCode: 12, modifiers: []),
            .reject
        )
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(keyCode: 12, modifiers: [.command]),
            .reject
        )
        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(
                keyCode: 49,
                modifiers: [.control, .option, .shift]
            ),
            .reject,
            "The legacy voice chord must remain reserved when it reaches the local recorder."
        )
    }

    func testAcceptedChordCommitsExactShortcut() {
        let shortcut = KeyboardShortcut(
            keyCode: 8,
            modifiers: [.control, .option]
        )

        XCTAssertEqual(
            HotkeyRecorderInputPolicy.decision(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.modifiers
            ),
            .record(shortcut)
        )
    }

    @MainActor
    func testFocusMoveRestoresPreviousResponderBeforeUsingActualFirstResponder() {
        let previousResponder = NSResponder()
        let restoredFirstResponder = NSResponder()
        var operations: [String] = []
        var moveOrigin: NSResponder?

        HotkeyCaptureFocusMove.perform(
            restoring: previousResponder,
            restore: { responder in
                operations.append("restore")
                XCTAssertTrue(responder === previousResponder)
                return true
            },
            currentFirstResponder: {
                operations.append("read-current")
                return restoredFirstResponder
            },
            move: { responder in
                operations.append("move")
                moveOrigin = responder
            }
        )

        XCTAssertEqual(operations, ["restore", "read-current", "move"])
        XCTAssertTrue(moveOrigin === restoredFirstResponder)
        XCTAssertFalse(moveOrigin === previousResponder)
    }

    @MainActor
    func testCaptureViewConsumesRejectedMenuEquivalentAndKeepsRecording() throws {
        let harness = makeCaptureHarness()
        var decisions: [HotkeyRecorderInputDecision] = []
        harness.capture.onDecision = { decisions.append($0) }
        harness.capture.onFocusLost = {}
        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)
        XCTAssertTrue(harness.window.firstResponder === harness.capture)

        let rejectedCommandQ = try keyEvent(
            in: harness.window,
            keyCode: 12,
            modifiers: [.command],
            characters: "q"
        )
        XCTAssertTrue(harness.window.performKeyEquivalent(with: rejectedCommandQ))
        XCTAssertEqual(decisions, [.reject])
        XCTAssertTrue(
            harness.window.firstResponder === harness.capture,
            "A rejected menu equivalent must beep and keep the recorder active."
        )

        let acceptedShortcut = KeyboardShortcut(
            keyCode: 8,
            modifiers: [.control, .option]
        )
        let acceptedEvent = try keyEvent(
            in: harness.window,
            keyCode: acceptedShortcut.keyCode,
            modifiers: [.control, .option],
            characters: "c"
        )
        XCTAssertTrue(harness.window.performKeyEquivalent(with: acceptedEvent))
        XCTAssertEqual(decisions, [.reject, .record(acceptedShortcut)])
        XCTAssertTrue(harness.window.firstResponder === harness.previousResponder)
    }

    @MainActor
    func testCaptureViewKeyEquivalentPreservesEscapeAndTabSemantics() throws {
        let harness = makeCaptureHarness()
        var decisions: [HotkeyRecorderInputDecision] = []
        harness.capture.onDecision = { decisions.append($0) }
        harness.capture.onFocusLost = {}

        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)
        XCTAssertTrue(
            harness.capture.performKeyEquivalent(
                with: try keyEvent(
                    in: harness.window,
                    keyCode: 53,
                    modifiers: [],
                    characters: "\u{1b}"
                )
            )
        )

        XCTAssertTrue(harness.window.makeFirstResponder(harness.previousResponder))
        harness.capture.updateCaptureState(isActive: true, focusRequest: 2)
        XCTAssertTrue(
            harness.capture.performKeyEquivalent(
                with: try keyEvent(
                    in: harness.window,
                    keyCode: 48,
                    modifiers: [],
                    characters: "\t"
                )
            )
        )

        XCTAssertTrue(harness.window.makeFirstResponder(harness.previousResponder))
        harness.capture.updateCaptureState(isActive: true, focusRequest: 3)
        XCTAssertTrue(
            harness.capture.performKeyEquivalent(
                with: try keyEvent(
                    in: harness.window,
                    keyCode: 48,
                    modifiers: [.shift],
                    characters: "\t"
                )
            )
        )

        XCTAssertEqual(
            decisions,
            [.cancel, .moveFocus(forward: true), .moveFocus(forward: false)]
        )
    }

    @MainActor
    func testDetachedPreviousResponderUsesLiveWindowFallback() throws {
        let harness = makeCaptureHarness()
        var decisions: [HotkeyRecorderInputDecision] = []
        harness.capture.onDecision = { decisions.append($0) }
        harness.capture.onFocusLost = {}
        harness.window.initialFirstResponder = harness.selectedResponder

        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)
        XCTAssertTrue(harness.window.firstResponder === harness.capture)
        harness.previousResponder.removeFromSuperview()

        XCTAssertTrue(
            harness.capture.performKeyEquivalent(
                with: try keyEvent(
                    in: harness.window,
                    keyCode: 53,
                    modifiers: [],
                    characters: "\u{1b}"
                )
            )
        )

        XCTAssertEqual(decisions, [.cancel])
        XCTAssertTrue(
            harness.window.firstResponder === harness.selectedResponder,
            "A detached weak responder must fall back to a live window responder."
        )
    }

    @MainActor
    func testApplicationAndWindowDeactivationDefersRestoreUntilBothRecover() {
        let harness = makeCaptureHarness()
        var focusLossCount = 0
        harness.capture.onFocusLost = {
            focusLossCount += 1
            // Model the representable receiving the SwiftUI state change while
            // AppKit is still delivering the deactivation notifications.
            harness.capture.updateCaptureState(isActive: false, focusRequest: 1)
        }

        harness.window.becomeKey()
        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)
        XCTAssertTrue(harness.window.firstResponder === harness.capture)

        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApplication.shared
        )
        harness.window.resignKey()

        XCTAssertEqual(focusLossCount, 1)
        XCTAssertTrue(
            harness.window.firstResponder === harness.capture,
            "Deactivation must not restore focus before the app and window recover."
        )

        harness.window.becomeKey()
        XCTAssertTrue(
            harness.window.firstResponder === harness.capture,
            "Window recovery alone must wait for application activation."
        )

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
        XCTAssertTrue(harness.window.firstResponder === harness.previousResponder)
        XCTAssertEqual(focusLossCount, 1)
    }

    @MainActor
    func testApplicationResignsBeforeCaptureActivationUpdateFailsClosed() {
        let harness = makeCaptureHarness()
        var focusLossCount = 0
        harness.capture.applicationIsActiveProvider = { false }
        harness.capture.onFocusLost = { focusLossCount += 1 }

        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApplication.shared
        )
        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)

        XCTAssertEqual(focusLossCount, 1)
        XCTAssertTrue(harness.window.firstResponder === harness.previousResponder)
    }

    @MainActor
    func testWindowResignsBeforeCaptureActivationUpdateFailsClosed() {
        let harness = makeCaptureHarness()
        var focusLossCount = 0
        harness.capture.windowIsKeyProvider = { _ in false }
        harness.capture.onFocusLost = { focusLossCount += 1 }

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: harness.window
        )
        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)

        XCTAssertEqual(focusLossCount, 1)
        XCTAssertTrue(harness.window.firstResponder === harness.previousResponder)
    }

    @MainActor
    func testWindowThenApplicationDeactivationRestoresInReverseRecoveryOrder() {
        let harness = makeCaptureHarness()
        var focusLossCount = 0
        harness.capture.onFocusLost = {
            focusLossCount += 1
            harness.capture.updateCaptureState(isActive: false, focusRequest: 1)
        }

        harness.window.becomeKey()
        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)
        XCTAssertTrue(harness.window.firstResponder === harness.capture)

        // Use NSWindow's lifecycle methods so AppKit delivers the real key
        // notifications and responder ordering rather than posting both sides.
        harness.window.resignKey()
        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApplication.shared
        )

        XCTAssertEqual(focusLossCount, 1)
        XCTAssertTrue(harness.window.firstResponder === harness.capture)

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
        XCTAssertTrue(
            harness.window.firstResponder === harness.capture,
            "Application recovery alone must retain the pending window reason."
        )

        harness.window.becomeKey()
        XCTAssertTrue(harness.window.firstResponder === harness.previousResponder)
        XCTAssertEqual(focusLossCount, 1)
    }

    @MainActor
    func testUserResponderChangeCancelsWithoutRestoringOldFocusLater() {
        let harness = makeCaptureHarness()
        var focusLossCount = 0
        harness.capture.onFocusLost = {
            focusLossCount += 1
            harness.capture.updateCaptureState(isActive: false, focusRequest: 1)
        }

        harness.window.becomeKey()
        harness.capture.updateCaptureState(isActive: true, focusRequest: 1)
        XCTAssertTrue(harness.window.firstResponder === harness.capture)
        XCTAssertTrue(harness.window.makeFirstResponder(harness.selectedResponder))

        XCTAssertEqual(focusLossCount, 1)
        XCTAssertTrue(harness.window.firstResponder === harness.selectedResponder)

        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApplication.shared
        )
        harness.window.resignKey()
        harness.window.becomeKey()
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )

        XCTAssertTrue(
            harness.window.firstResponder === harness.selectedResponder,
            "A user-selected responder must not be replaced during later activation."
        )
        XCTAssertFalse(harness.window.firstResponder === harness.previousResponder)
        XCTAssertEqual(focusLossCount, 1)
    }

    @MainActor
    private func makeCaptureHarness() -> (
        window: NSWindow,
        capture: HotkeyCaptureView,
        previousResponder: HotkeyRecorderTestResponder,
        selectedResponder: HotkeyRecorderTestResponder
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentLayoutRect)
        let previousResponder = HotkeyRecorderTestResponder(
            frame: NSRect(x: 20, y: 20, width: 100, height: 30)
        )
        let selectedResponder = HotkeyRecorderTestResponder(
            frame: NSRect(x: 140, y: 20, width: 100, height: 30)
        )
        let capture = HotkeyCaptureView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        capture.applicationIsActiveProvider = { true }
        capture.windowIsKeyProvider = { _ in true }
        contentView.addSubview(previousResponder)
        contentView.addSubview(selectedResponder)
        contentView.addSubview(capture)
        window.contentView = contentView
        XCTAssertTrue(window.makeFirstResponder(previousResponder))
        return (window, capture, previousResponder, selectedResponder)
    }

    @MainActor
    private func keyEvent(
        in window: NSWindow,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

}

@MainActor
private final class HotkeyRecorderTestResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}
