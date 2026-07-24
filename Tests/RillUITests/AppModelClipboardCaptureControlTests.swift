import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
extension AppModelTests {
    func testClipboardCaptureControlsForwardActionsAndReflectControllerState() {
        let harness = makeHarness()
        var enablementRequests: [Bool] = []
        var preferenceRevisions: [UInt64] = []
        var ignoreNextRequestCount = 0
        harness.model.installClipboardCaptureControlActions(
            setEnabled: { enabled, revision in
                enablementRequests.append(enabled)
                preferenceRevisions.append(revision)
            },
            ignoreNextExternalChange: { ignoreNextRequestCount += 1 }
        )
        XCTAssertEqual(enablementRequests, [true])
        XCTAssertEqual(preferenceRevisions, [0])

        harness.model.toggleClipboardCaptureEnabled()
        XCTAssertEqual(enablementRequests, [true, false])
        XCTAssertEqual(preferenceRevisions, [0, 1])
        XCTAssertFalse(harness.model.clipboardCaptureEnabled)

        harness.model.updateClipboardCaptureControlState(
            ClipboardCaptureControlSnapshot(revision: 1, state: .paused)
        )
        XCTAssertTrue(harness.model.isClipboardCapturePaused)
        harness.model.ignoreNextExternalClipboardChange()
        XCTAssertEqual(ignoreNextRequestCount, 0)

        harness.model.toggleClipboardCaptureEnabled()
        XCTAssertEqual(enablementRequests, [true, false, true])
        XCTAssertEqual(preferenceRevisions, [0, 1, 2])
        XCTAssertTrue(harness.model.clipboardCaptureEnabled)
        harness.model.updateClipboardCaptureControlState(
            ClipboardCaptureControlSnapshot(revision: 2, state: .ignoringNextExternalChange)
        )
        XCTAssertTrue(harness.model.isIgnoringNextExternalClipboardChange)
        harness.model.ignoreNextExternalClipboardChange()
        XCTAssertEqual(ignoreNextRequestCount, 0)

        harness.model.updateClipboardCaptureControlState(
            ClipboardCaptureControlSnapshot(revision: 3, state: .active)
        )
        harness.model.ignoreNextExternalClipboardChange()
        XCTAssertEqual(ignoreNextRequestCount, 1)

        harness.model.updateClipboardCaptureControlState(
            ClipboardCaptureControlSnapshot(revision: 2, state: .paused)
        )
        XCTAssertEqual(harness.model.clipboardCaptureControlSnapshot.state, .active)

        harness.model.updateClipboardCaptureControlState(
            ClipboardCaptureControlSnapshot(revision: 4, state: .resuming)
        )
        harness.model.toggleClipboardCaptureEnabled()
        XCTAssertEqual(enablementRequests, [true, false, true, false])
        XCTAssertEqual(preferenceRevisions, [0, 1, 2, 3])
    }
}
