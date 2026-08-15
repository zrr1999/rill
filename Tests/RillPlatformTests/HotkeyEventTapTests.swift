import ApplicationServices
import RillCore
import XCTest
@testable import RillPlatform

final class HotkeyEventTapTests: XCTestCase {
    func testEventTapHealthAcceptsValidEnabledTapWithoutReenabling() {
        var enableCount = 0
        let checker = HotkeyEventTapHealthChecker<Int>(
            isValid: { _ in true },
            isEnabled: { _ in true },
            enable: { _ in enableCount += 1 }
        )

        XCTAssertTrue(checker.ensureAvailable(1))
        XCTAssertEqual(enableCount, 0)
    }

    func testEventTapHealthReenablesValidDisabledTapAndRechecks() {
        var isEnabled = false
        var enableCount = 0
        let checker = HotkeyEventTapHealthChecker<Int>(
            isValid: { _ in true },
            isEnabled: { _ in isEnabled },
            enable: { _ in
                enableCount += 1
                isEnabled = true
            }
        )

        XCTAssertTrue(checker.ensureAvailable(1))
        XCTAssertEqual(enableCount, 1)
    }

    func testEventTapHealthRejectsValidTapWhenReenableFails() {
        var enableCount = 0
        let checker = HotkeyEventTapHealthChecker<Int>(
            isValid: { _ in true },
            isEnabled: { _ in false },
            enable: { _ in enableCount += 1 }
        )

        XCTAssertFalse(checker.ensureAvailable(1))
        XCTAssertEqual(enableCount, 1)
    }

    func testEventTapHealthRejectsInvalidTapWithoutTryingToEnable() {
        var enableCount = 0
        let checker = HotkeyEventTapHealthChecker<Int>(
            isValid: { _ in false },
            isEnabled: { _ in true },
            enable: { _ in enableCount += 1 }
        )

        XCTAssertFalse(checker.ensureAvailable(1))
        XCTAssertEqual(enableCount, 0)
    }

    func testFunctionKeyFlagsChangedStartsAndStopsPushToTalk() {
        var recognizer = PushToTalkGestureRecognizer()

        let press = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )
        let release = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: []
        )

        XCTAssertEqual(press, .swallow(.pushToTalkPressed(.fnHold)))
        XCTAssertEqual(release, .swallow(.pushToTalkReleased(.fnHold)))
    }

    func testLegacyShortcutStillStartsAndStopsPushToTalk() {
        var recognizer = PushToTalkGestureRecognizer()

        let press = recognizer.handle(
            type: .keyDown,
            keyCode: 49,
            flags: [.maskControl, .maskAlternate, .maskShift]
        )
        let release = recognizer.handle(
            type: .keyUp,
            keyCode: 49,
            flags: []
        )

        XCTAssertEqual(press, .swallow(.pushToTalkPressed(.controlOptionShiftSpace)))
        XCTAssertEqual(release, .swallow(.pushToTalkReleased(.controlOptionShiftSpace)))
    }

    func testEscapePassesThroughWithoutAnActiveLiveAudioRun() {
        let tap = HotkeyEventTap()

        XCTAssertEqual(
            tap.testingHandleLiveAudioEscape(type: .keyDown, keyCode: 53, flags: []),
            .passThrough
        )
        XCTAssertEqual(
            tap.testingHandleLiveAudioEscape(type: .keyUp, keyCode: 53, flags: []),
            .passThrough
        )
    }

    func testEscapeCancelsActiveRunOnceAndSwallowsMatchingRelease() {
        let tap = HotkeyEventTap()
        let runID = UUID()
        tap.setLiveAudioEscapeCancellationRunID(runID)

        XCTAssertEqual(
            tap.testingHandleLiveAudioEscape(
                type: .keyDown,
                keyCode: 53,
                flags: [.maskSecondaryFn]
            ),
            .swallow(runID)
        )
        XCTAssertEqual(
            tap.testingHandleLiveAudioEscape(
                type: .keyDown,
                keyCode: 53,
                flags: [.maskSecondaryFn]
            ),
            .swallow(nil)
        )

        tap.setLiveAudioEscapeCancellationRunID(nil)
        XCTAssertEqual(
            tap.testingHandleLiveAudioEscape(type: .keyUp, keyCode: 53, flags: []),
            .swallow(nil)
        )
    }

    func testModifiedEscapeRemainsAvailableToTheForegroundApplication() {
        let tap = HotkeyEventTap()
        tap.setLiveAudioEscapeCancellationRunID(UUID())

        XCTAssertEqual(
            tap.testingHandleLiveAudioEscape(
                type: .keyDown,
                keyCode: 53,
                flags: [.maskCommand]
            ),
            .passThrough
        )
    }

    func testUnrelatedFlagsPassThrough() {
        var recognizer = PushToTalkGestureRecognizer()

        let result = recognizer.handle(
            type: .flagsChanged,
            keyCode: 55,
            flags: [.maskCommand]
        )

        XCTAssertEqual(result, .passThrough)
    }

    func testFunctionKeyReleaseWithDifferentKeyCodeStillStopsPushToTalk() {
        var recognizer = PushToTalkGestureRecognizer()

        _ = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )
        let release = recognizer.handle(
            type: .flagsChanged,
            keyCode: 56,
            flags: []
        )

        XCTAssertEqual(release, .swallow(.pushToTalkReleased(.fnHold)))
    }

    func testFunctionKeyRemainsActiveAcrossOtherModifierChanges() {
        var recognizer = PushToTalkGestureRecognizer()

        let press = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )
        let modifierWhileHolding = recognizer.handle(
            type: .flagsChanged,
            keyCode: 56,
            flags: [.maskSecondaryFn, .maskShift]
        )
        let release = recognizer.handle(
            type: .flagsChanged,
            keyCode: 56,
            flags: [.maskShift]
        )

        XCTAssertEqual(press, .swallow(.pushToTalkPressed(.fnHold)))
        XCTAssertEqual(modifierWhileHolding, .swallow(nil))
        XCTAssertEqual(release, .swallow(.pushToTalkReleased(.fnHold)))
    }

    func testEventTapInterruptionReleasesFunctionKeyLatchAndIsIdempotent() {
        var recognizer = PushToTalkGestureRecognizer()
        _ = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        let interruptionRelease = recognizer.interrupt()
        let repeatedInterruption = recognizer.interrupt()
        let nextPress = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        XCTAssertEqual(interruptionRelease, .pushToTalkReleased(.fnHold))
        XCTAssertNil(repeatedInterruption)
        XCTAssertEqual(nextPress, .swallow(.pushToTalkPressed(.fnHold)))
    }

    func testEventTapInterruptionReleasesLegacyShortcutLatch() {
        var recognizer = PushToTalkGestureRecognizer()
        _ = recognizer.handle(
            type: .keyDown,
            keyCode: 49,
            flags: [.maskControl, .maskAlternate, .maskShift]
        )

        let interruptionRelease = recognizer.interrupt()
        let lateKeyUp = recognizer.handle(
            type: .keyUp,
            keyCode: 49,
            flags: []
        )

        XCTAssertEqual(
            interruptionRelease,
            .pushToTalkReleased(.controlOptionShiftSpace)
        )
        XCTAssertEqual(lateKeyUp, .passThrough)
    }

    func testEventTapInterruptionPreservesHeldFunctionLatchUntilPhysicalRelease() {
        var recognizer = PushToTalkGestureRecognizer()
        _ = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        let interruptionRelease = recognizer.interrupt(preservingActiveTrigger: true)
        let repeatedInterruption = recognizer.interrupt(preservingActiveTrigger: true)
        let physicalRelease = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: []
        )

        XCTAssertEqual(interruptionRelease, .pushToTalkReleased(.fnHold))
        XCTAssertNil(repeatedInterruption)
        XCTAssertEqual(physicalRelease, .swallow(.pushToTalkReleased(.fnHold)))
    }

    func testEventTapInterruptionPreservesHeldLegacyLatchUntilPhysicalRelease() {
        var recognizer = PushToTalkGestureRecognizer()
        _ = recognizer.handle(
            type: .keyDown,
            keyCode: 49,
            flags: [.maskControl, .maskAlternate, .maskShift]
        )

        let interruptionRelease = recognizer.interrupt(preservingActiveTrigger: true)
        let physicalRelease = recognizer.handle(
            type: .keyUp,
            keyCode: 49,
            flags: []
        )

        XCTAssertEqual(
            interruptionRelease,
            .pushToTalkReleased(.controlOptionShiftSpace)
        )
        XCTAssertEqual(
            physicalRelease,
            .swallow(.pushToTalkReleased(.controlOptionShiftSpace))
        )
    }

    func testRepeatedInterruptionEmitsFinalReleaseWhenPreservedGestureIsNoLongerActive() {
        var recognizer = PushToTalkGestureRecognizer()
        _ = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        let initialRelease = recognizer.interrupt(preservingActiveTrigger: true)
        let finalRelease = recognizer.interrupt(preservingActiveTrigger: false)
        let nextPress = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        XCTAssertEqual(initialRelease, .pushToTalkReleased(.fnHold))
        XCTAssertEqual(finalRelease, .pushToTalkReleased(.fnHold))
        XCTAssertEqual(nextPress, .swallow(.pushToTalkPressed(.fnHold)))
    }

    func testEventTapTeardownPublishesUnavailableAndClearsPushToTalkLatchBeforeReinstall() {
        let tap = HotkeyEventTap()
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )

        let teardownEvent = tap.testingResetRecognizersForEventTapTeardown()
        let replacementPress = tap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        XCTAssertEqual(teardownEvent, .globalInputUnavailable)
        XCTAssertEqual(replacementPress, .swallow(.pushToTalkPressed(.fnHold)))
    }

    func testEventTapTeardownPublishesUnavailableWithoutActiveGestureLatch() {
        let tap = HotkeyEventTap()

        XCTAssertEqual(
            tap.testingResetRecognizersForEventTapTeardown(),
            .globalInputUnavailable
        )
    }

    func testFailedEventTapReenableFinalizesPreservedLatchBeforeRetry() {
        let tap = HotkeyEventTap()
        _ = tap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        let interruptionRelease = tap.testingInterruptPushToTalk(
            preservingActiveTrigger: true
        )
        let teardownEvent = tap.testingResetRecognizersForEventTapTeardown()
        let retryPress = tap.testingHandlePushToTalk(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        XCTAssertEqual(interruptionRelease, .pushToTalkReleased(.fnHold))
        XCTAssertEqual(teardownEvent, .globalInputUnavailable)
        XCTAssertEqual(retryPress, .swallow(.pushToTalkPressed(.fnHold)))
    }

    func testDoubleCommandTapRecognizerEmitsOnceForOneIsolatedPair() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now

        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start,
                releasedAt: start.advanced(by: .milliseconds(20))
            )
        )
        XCTAssertTrue(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(120)),
                releasedAt: start.advanced(by: .milliseconds(140))
            )
        )
        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(220)),
                releasedAt: start.advanced(by: .milliseconds(240))
            ),
            "A completed pair must be consumed instead of overlapping with a third tap."
        )
    }

    func testDoubleCommandTapRecognizerSupportsMixedCommandKeys() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now

        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start,
                releasedAt: start.advanced(by: .milliseconds(20))
            )
        )
        XCTAssertTrue(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(100)),
                releasedAt: start.advanced(by: .milliseconds(120))
            )
        )
    }

    func testDoubleCommandTapRecognizerResetsForUnrelatedKeyEvent() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now
        _ = performCommandTap(
            on: &recognizer,
            keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
            pressedAt: start,
            releasedAt: start.advanced(by: .milliseconds(20))
        )

        XCTAssertFalse(
            recognizer.handle(
                type: .keyDown,
                keyCode: 0,
                flags: [],
                at: start.advanced(by: .milliseconds(80))
            )
        )
        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(120)),
                releasedAt: start.advanced(by: .milliseconds(140))
            )
        )
    }

    func testDoubleCommandTapRecognizerResetsForUnrelatedModifierEvent() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now
        _ = performCommandTap(
            on: &recognizer,
            keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
            pressedAt: start,
            releasedAt: start.advanced(by: .milliseconds(20))
        )

        XCTAssertFalse(
            recognizer.handle(
                type: .flagsChanged,
                keyCode: 56,
                flags: [.maskShift],
                at: start.advanced(by: .milliseconds(80))
            )
        )
        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(120)),
                releasedAt: start.advanced(by: .milliseconds(140))
            )
        )
    }

    func testDoubleCommandTapRecognizerUsesMonotonicTimeout() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now
        _ = performCommandTap(
            on: &recognizer,
            keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
            pressedAt: start,
            releasedAt: start.advanced(by: .milliseconds(20))
        )

        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(380)),
                releasedAt: start.advanced(by: .milliseconds(400))
            )
        )
    }

    func testDoubleCommandTapRecognizerRejectsFunctionModifierChord() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now

        XCTAssertFalse(
            recognizer.handle(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [.maskCommand, .maskSecondaryFn],
                at: start
            )
        )
        XCTAssertFalse(
            recognizer.handle(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [.maskSecondaryFn],
                at: start.advanced(by: .milliseconds(20))
            )
        )
        XCTAssertFalse(
            recognizer.handle(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                flags: [.maskCommand, .maskSecondaryFn],
                at: start.advanced(by: .milliseconds(100))
            )
        )
        XCTAssertFalse(
            recognizer.handle(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                flags: [.maskSecondaryFn],
                at: start.advanced(by: .milliseconds(120))
            )
        )
    }

    func testDoubleCommandTapRecognizerResetsForPointerAndScrollEvents() {
        for unrelatedType in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            var recognizer = DoubleCommandTapRecognizer()
            let start = ContinuousClock().now
            _ = performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start,
                releasedAt: start.advanced(by: .milliseconds(20))
            )

            XCTAssertFalse(
                recognizer.handle(
                    type: unrelatedType,
                    keyCode: 0,
                    flags: [],
                    at: start.advanced(by: .milliseconds(80))
                )
            )
            XCTAssertFalse(
                performCommandTap(
                    on: &recognizer,
                    keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                    pressedAt: start.advanced(by: .milliseconds(120)),
                    releasedAt: start.advanced(by: .milliseconds(140))
                ),
                "\(unrelatedType) must reset the completed first tap."
            )
        }
    }

    func testDoubleCommandTapRecognizerRejectsLongHold() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now

        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start,
                releasedAt: start.advanced(by: .seconds(1))
            )
        )
        XCTAssertFalse(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(1_100)),
                releasedAt: start.advanced(by: .milliseconds(1_120))
            )
        )
    }

    func testDoubleCommandTapRecognizerUsesReleaseToNextPressGap() {
        var recognizer = DoubleCommandTapRecognizer()
        let start = ContinuousClock().now
        _ = performCommandTap(
            on: &recognizer,
            keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
            pressedAt: start,
            releasedAt: start.advanced(by: .milliseconds(20))
        )

        XCTAssertTrue(
            performCommandTap(
                on: &recognizer,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                pressedAt: start.advanced(by: .milliseconds(300)),
                releasedAt: start.advanced(by: .milliseconds(620))
            ),
            "A timely second press remains a tap when its own hold stays bounded."
        )
    }

    func testDisablingPasteInterceptionClearsBypassTokens() {
        let tap = HotkeyEventTap()
        tap.setPasteInterceptEnabled(true)
        tap.skipNextPasteInterception()
        XCTAssertEqual(tap.testingSkippedPasteEventCount(), 1)

        tap.setPasteInterceptEnabled(false)
        XCTAssertEqual(tap.testingSkippedPasteEventCount(), 0)

        tap.skipNextPasteInterception()
        XCTAssertEqual(tap.testingSkippedPasteEventCount(), 0)

        tap.setPasteInterceptEnabled(true)
        XCTAssertEqual(tap.testingSkippedPasteEventCount(), 0)
    }

    func testRecordPanelShortcutDefaultsDisabledButKeepsFunctionPushToTalk() {
        let tap = HotkeyEventTap()
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        tap.setRecordPanelHotkeyBinding(.keyboardShortcut(shortcut))

        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertEqual(
            tap.testingHandleRecordPanelShortcut(
                type: .keyDown,
                keyCode: 8,
                flags: [.maskControl, .maskAlternate]
            ),
            .passThrough
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: []
            ),
            .swallow(.pushToTalkReleased(.fnHold))
        )
    }

    func testShortcutRecordingLeasesSuspendNewPanelAndPushToTalkPressesUntilEveryLeaseEnds() {
        let tap = HotkeyEventTap()
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        tap.setRecordPanelHotkeyBinding(.keyboardShortcut(shortcut))
        tap.setRecordPanelShortcutEnabled(true)

        let firstLease = tap.beginRecordPanelShortcutRecording()
        let secondLease = tap.beginRecordPanelShortcutRecording()

        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertEqual(
            tap.testingHandleRecordPanelShortcut(
                type: .keyDown,
                keyCode: 8,
                flags: [.maskControl, .maskAlternate]
            ),
            .passThrough
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .passThrough
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .keyDown,
                keyCode: 49,
                flags: [.maskControl, .maskAlternate, .maskShift]
            ),
            .passThrough,
            "The reserved legacy chord must reach the app-local recorder for rejection."
        )

        tap.endRecordPanelShortcutRecording(firstLease)
        tap.endRecordPanelShortcutRecording(firstLease)
        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())

        tap.endRecordPanelShortcutRecording(secondLease)
        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertEqual(
            tap.testingHandleRecordPanelShortcut(
                type: .keyDown,
                keyCode: 8,
                flags: [.maskControl, .maskAlternate]
            ),
            .swallow(shouldEmit: true)
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: []
            ),
            .swallow(.pushToTalkReleased(.fnHold))
        )
    }

    func testShortcutRecordingLeasePreservesReleaseForFunctionGestureActiveBeforeLease() {
        let tap = HotkeyEventTap()
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )

        let lease = tap.beginRecordPanelShortcutRecording()

        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: []
            ),
            .swallow(.pushToTalkReleased(.fnHold)),
            "A recorder lease must not strand a capture that already owns Fn."
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .passThrough,
            "After the old gesture releases, the lease must block a new press."
        )
        tap.endRecordPanelShortcutRecording(lease)
    }

    func testShortcutRecordingLeasePreservesReleaseForLegacyGestureActiveBeforeLease() {
        let tap = HotkeyEventTap()
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .keyDown,
                keyCode: 49,
                flags: [.maskControl, .maskAlternate, .maskShift]
            ),
            .swallow(.pushToTalkPressed(.controlOptionShiftSpace))
        )

        let lease = tap.beginRecordPanelShortcutRecording()

        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .keyUp,
                keyCode: 49,
                flags: []
            ),
            .swallow(.pushToTalkReleased(.controlOptionShiftSpace)),
            "A recorder lease must retain the key-up route for an existing legacy gesture."
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .keyDown,
                keyCode: 49,
                flags: [.maskControl, .maskAlternate, .maskShift]
            ),
            .passThrough
        )
        tap.endRecordPanelShortcutRecording(lease)
    }

    func testShortcutRecordingLeaseDoesNotOverrideDisabledCapturePreference() {
        let tap = HotkeyEventTap()
        tap.setRecordPanelShortcutEnabled(true)
        let lease = tap.beginRecordPanelShortcutRecording()

        tap.setRecordPanelShortcutEnabled(false)
        tap.endRecordPanelShortcutRecording(lease)

        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())
    }

    func testCommittedShortcutRecordingLeaseConsumesRepeatsUntilMatchingKeyUp() {
        let tap = HotkeyEventTap(physicalKeyStateProvider: { $0 == 8 })
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        tap.setRecordPanelHotkeyBinding(.keyboardShortcut(shortcut))
        tap.setRecordPanelShortcutEnabled(true)
        let lease = tap.beginRecordPanelShortcutRecording()

        tap.commitRecordPanelShortcutRecording(lease, keyCode: shortcut.keyCode)

        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertTrue(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyDown,
                keyCode: 8
            ),
            "Autorepeat from the physical commit press must stay inside its recorder latch."
        )
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .flagsChanged,
                keyCode: 63
            ),
            "The recorder latch must never consume the Fn flags route."
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .passThrough
        )
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 7
            )
        )
        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())

        XCTAssertTrue(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            )
        )
        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertEqual(
            tap.testingHandleRecordPanelShortcut(
                type: .keyDown,
                keyCode: 8,
                flags: [.maskControl, .maskAlternate]
            ),
            .swallow(shouldEmit: true),
            "Only a later physical press may trigger the newly committed binding."
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )
        _ = tap.testingHandlePushToTalk(type: .flagsChanged, keyCode: 63, flags: [])
    }

    func testCommitAfterKeyUpReleasesRecorderLeaseAndAllowsNextFunctionGesture() {
        let tap = HotkeyEventTap(physicalKeyStateProvider: { _ in false })
        tap.setRecordPanelShortcutEnabled(true)
        let lease = tap.beginRecordPanelShortcutRecording()
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            ),
            "The tap can observe key-up before the main-thread recorder decision."
        )

        tap.commitRecordPanelShortcutRecording(lease, keyCode: 8)

        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            ),
            "A commit that arrives after key-up must not leave a latch behind."
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: []
            ),
            .swallow(.pushToTalkReleased(.fnHold))
        )
    }

    func testEventTapRecoverySecondSampleReleasesCommitThatWentUpWhileTapWasDisabled() {
        let physicalKeyState = SequencedBooleanState([true, true, false])
        let tap = HotkeyEventTap(physicalKeyStateProvider: { _ in
            physicalKeyState.next()
        })
        tap.setRecordPanelShortcutEnabled(true)
        let lease = tap.beginRecordPanelShortcutRecording()
        tap.commitRecordPanelShortcutRecording(lease, keyCode: 8)

        XCTAssertNil(tap.testingPrepareRecognizersForEventTapRecovery())
        XCTAssertFalse(
            tap.testingIsRecordPanelShortcutEnabled(),
            "The initial disabled-tap sample must retain a commit whose key is still held."
        )

        // Model the physical release after the first sample but before the tap
        // becomes available. Production performs this check only after the
        // health checker has successfully re-enabled and revalidated the tap.
        tap.testingCompleteRecognizersForEventTapRecovery()

        XCTAssertEqual(physicalKeyState.sampleCount, 3)
        XCTAssertTrue(
            tap.testingIsRecordPanelShortcutEnabled(),
            "The post-enable sample must retire a commit whose key-up was lost during recovery."
        )
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            )
        )
    }

    func testEventTapRecoverySecondSampleClearsFunctionLatchReleasedWhileTapWasDisabled() {
        let functionGestureState = SequencedBooleanState([true, false])
        let tap = HotkeyEventTap(
            physicalKeyStateProvider: { _ in false },
            pushToTalkGestureStateProvider: { gesture in
                guard gesture == .fnHold else { return false }
                return functionGestureState.next()
            }
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )

        XCTAssertEqual(
            tap.testingPrepareRecognizersForEventTapRecovery(),
            .pushToTalkReleased(.fnHold)
        )
        XCTAssertEqual(functionGestureState.sampleCount, 1)

        // The physical release occurs after the disabled-tap sample. Production
        // reaches this second sample only after the health checker has successfully
        // re-enabled and revalidated the tap.
        tap.testingCompleteRecognizersForEventTapRecovery()

        XCTAssertEqual(functionGestureState.sampleCount, 2)
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold)),
            "A lost key-up must not consume the first Fn press after event-tap recovery."
        )
        _ = tap.testingHandlePushToTalk(type: .flagsChanged, keyCode: 63, flags: [])
    }

    func testEventTapRecoverySecondSampleKeepsStillHeldFunctionLatch() {
        let functionGestureState = SequencedBooleanState([true, true])
        let tap = HotkeyEventTap(
            physicalKeyStateProvider: { _ in false },
            pushToTalkGestureStateProvider: { gesture in
                guard gesture == .fnHold else { return false }
                return functionGestureState.next()
            }
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )
        XCTAssertEqual(
            tap.testingPrepareRecognizersForEventTapRecovery(),
            .pushToTalkReleased(.fnHold)
        )

        tap.testingCompleteRecognizersForEventTapRecovery()

        XCTAssertEqual(functionGestureState.sampleCount, 2)
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(nil),
            "A still-held Fn key must remain part of the interrupted gesture."
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: []
            ),
            .swallow(.pushToTalkReleased(.fnHold))
        )
    }

    func testEventTapRecoveryKeepsHeldCommitLatchedAndBlocksNewFnUntilKeyUp() {
        let tap = HotkeyEventTap(physicalKeyStateProvider: { $0 == 8 })
        tap.setRecordPanelShortcutEnabled(true)
        let lease = tap.beginRecordPanelShortcutRecording()
        tap.commitRecordPanelShortcutRecording(lease, keyCode: 8)

        XCTAssertNil(tap.testingPrepareRecognizersForEventTapRecovery())
        tap.testingCompleteRecognizersForEventTapRecovery()
        XCTAssertFalse(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .flagsChanged,
                keyCode: 63
            )
        )
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .passThrough
        )
        XCTAssertTrue(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            )
        )
        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertEqual(
            tap.testingHandlePushToTalk(
                type: .flagsChanged,
                keyCode: 63,
                flags: [.maskSecondaryFn]
            ),
            .swallow(.pushToTalkPressed(.fnHold))
        )
        _ = tap.testingHandlePushToTalk(type: .flagsChanged, keyCode: 63, flags: [])
    }

    func testEventTapTeardownClearsCommittedLeaseButPreservesActiveRecorderOwner() {
        let tap = HotkeyEventTap(physicalKeyStateProvider: { $0 == 8 })
        tap.setRecordPanelShortcutEnabled(true)
        let activeRecorderLease = tap.beginRecordPanelShortcutRecording()
        let committedLease = tap.beginRecordPanelShortcutRecording()
        tap.commitRecordPanelShortcutRecording(committedLease, keyCode: 8)

        XCTAssertEqual(
            tap.testingResetRecognizersForEventTapTeardown(),
            .globalInputUnavailable
        )

        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            ),
            "Teardown cannot wait for a key-up that the retired tap can no longer observe."
        )
        XCTAssertFalse(
            tap.testingIsRecordPanelShortcutEnabled(),
            "A still-visible recorder remains the owner of its explicit suspension."
        )

        tap.endRecordPanelShortcutRecording(activeRecorderLease)
        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
    }

    func testExplicitRecorderLeaseEndCancelsPendingCommitLatchIdempotently() {
        let tap = HotkeyEventTap(physicalKeyStateProvider: { $0 == 8 })
        tap.setRecordPanelShortcutEnabled(true)
        let lease = tap.beginRecordPanelShortcutRecording()
        tap.commitRecordPanelShortcutRecording(lease, keyCode: 8)

        tap.endRecordPanelShortcutRecording(lease)
        tap.endRecordPanelShortcutRecording(lease)

        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertFalse(
            tap.testingHandleRecordPanelShortcutRecordingCommitKey(
                type: .keyUp,
                keyCode: 8
            )
        )
    }

    func testDisablingRecordPanelShortcutSuppressesAndResetsDoubleCommandRecognition() {
        let tap = HotkeyEventTap()
        let start = ContinuousClock().now
        tap.setRecordPanelShortcutEnabled(true)
        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [.maskCommand],
                at: start
            )
        )
        tap.setRecordPanelShortcutEnabled(false)

        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [],
                at: start.advanced(by: .milliseconds(20))
            )
        )
        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [.maskCommand],
                at: start.advanced(by: .milliseconds(40))
            )
        )
        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [],
                at: start.advanced(by: .milliseconds(60))
            )
        )

        tap.setRecordPanelShortcutEnabled(true)
        XCTAssertTrue(tap.testingIsRecordPanelShortcutEnabled())
        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [.maskCommand],
                at: start.advanced(by: .milliseconds(100))
            )
        )
        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.leftCommandKeyCode,
                flags: [],
                at: start.advanced(by: .milliseconds(120))
            )
        )
        XCTAssertFalse(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                flags: [.maskCommand],
                at: start.advanced(by: .milliseconds(180))
            )
        )
        XCTAssertTrue(
            tap.testingHandleDoubleCommandPanelShortcut(
                type: .flagsChanged,
                keyCode: DoubleCommandTapRecognizer.rightCommandKeyCode,
                flags: [],
                at: start.advanced(by: .milliseconds(200))
            )
        )
    }

    func testRecordPanelShortcutEmitsOnceUntilMatchingKeyUp() {
        var recognizer = RecordPanelShortcutRecognizer()
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        let binding = HotkeyBindingDescriptor.keyboardShortcut(shortcut)
        let flags: CGEventFlags = [.maskControl, .maskAlternate]

        let firstPress = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: flags,
            binding: binding
        )
        let repeatedPress = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: flags,
            binding: binding
        )
        let release = recognizer.handle(
            type: .keyUp,
            keyCode: 8,
            flags: flags,
            binding: binding
        )
        let nextPress = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: flags,
            binding: binding
        )

        XCTAssertEqual(firstPress, .swallow(shouldEmit: true))
        XCTAssertEqual(repeatedPress, .swallow(shouldEmit: false))
        XCTAssertEqual(release, .swallow(shouldEmit: false))
        XCTAssertEqual(nextPress, .swallow(shouldEmit: true))
    }

    func testRecordPanelShortcutKeepsRepeatSwallowedAfterModifierDrift() {
        var recognizer = RecordPanelShortcutRecognizer()
        let binding = HotkeyBindingDescriptor.keyboardShortcut(
            KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        )

        _ = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: [.maskControl, .maskAlternate],
            binding: binding
        )
        let repeatAfterModifierRelease = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: [],
            binding: binding
        )

        XCTAssertEqual(repeatAfterModifierRelease, .swallow(shouldEmit: false))
    }

    func testRecordPanelShortcutRecognizerRejectsUnsafeDirectBinding() {
        var recognizer = RecordPanelShortcutRecognizer()
        let unsafeBinding = HotkeyBindingDescriptor.keyboardShortcut(
            KeyboardShortcut(keyCode: 12, modifiers: [.command])
        )

        let result = recognizer.handle(
            type: .keyDown,
            keyCode: 12,
            flags: [.maskCommand],
            binding: unsafeBinding
        )

        XCTAssertEqual(result, .passThrough)
    }

    func testRecordPanelShortcutResetReopensLatchAfterEventTapRecovery() {
        var recognizer = RecordPanelShortcutRecognizer()
        let binding = HotkeyBindingDescriptor.keyboardShortcut(
            KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        )

        _ = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: [.maskControl, .maskAlternate],
            binding: binding
        )
        recognizer.reset()
        let recoveredPress = recognizer.handle(
            type: .keyDown,
            keyCode: 8,
            flags: [.maskControl, .maskAlternate],
            binding: binding
        )

        XCTAssertEqual(recoveredPress, .swallow(shouldEmit: true))
    }

    private func performCommandTap(
        on recognizer: inout DoubleCommandTapRecognizer,
        keyCode: CGKeyCode,
        pressedAt: ContinuousClock.Instant,
        releasedAt: ContinuousClock.Instant
    ) -> Bool {
        XCTAssertFalse(
            recognizer.handle(
                type: .flagsChanged,
                keyCode: keyCode,
                flags: [.maskCommand],
                at: pressedAt
            )
        )
        return recognizer.handle(
            type: .flagsChanged,
            keyCode: keyCode,
            flags: [],
            at: releasedAt
        )
    }
}

private final class SequencedBooleanState: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Bool]
    private var samples = 0

    init(_ states: [Bool]) {
        self.states = states
    }

    var sampleCount: Int {
        lock.withLock { samples }
    }

    func next() -> Bool {
        lock.withLock {
            samples += 1
            guard !states.isEmpty else { return false }
            return states.removeFirst()
        }
    }
}
