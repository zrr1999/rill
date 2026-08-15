import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
extension AppModelTests {
    func testSystemClipboardCaptureControlsForwardActionsAndReflectControllerState() {
        let harness = makeHarness()
        var enablementRequests: [Bool] = []
        var preferenceRevisions: [UInt64] = []
        var ignoreNextRequestCount = 0
        harness.model.installSystemClipboardCaptureControlActions(
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
        XCTAssertFalse(harness.model.systemClipboardCaptureEnabled)

        harness.model.updateSystemClipboardCaptureControlState(
            SystemClipboardCaptureControlSnapshot(revision: 1, state: .paused)
        )
        XCTAssertTrue(harness.model.isClipboardCapturePaused)
        harness.model.ignoreNextExternalClipboardChange()
        XCTAssertEqual(ignoreNextRequestCount, 0)

        harness.model.toggleClipboardCaptureEnabled()
        XCTAssertEqual(enablementRequests, [true, false, true])
        XCTAssertEqual(preferenceRevisions, [0, 1, 2])
        XCTAssertTrue(harness.model.systemClipboardCaptureEnabled)
        harness.model.updateSystemClipboardCaptureControlState(
            SystemClipboardCaptureControlSnapshot(revision: 2, state: .ignoringNextExternalChange)
        )
        XCTAssertTrue(harness.model.isIgnoringNextExternalClipboardChange)
        harness.model.ignoreNextExternalClipboardChange()
        XCTAssertEqual(ignoreNextRequestCount, 0)

        harness.model.updateSystemClipboardCaptureControlState(
            SystemClipboardCaptureControlSnapshot(revision: 3, state: .active)
        )
        harness.model.ignoreNextExternalClipboardChange()
        XCTAssertEqual(ignoreNextRequestCount, 1)

        harness.model.updateSystemClipboardCaptureControlState(
            SystemClipboardCaptureControlSnapshot(revision: 2, state: .paused)
        )
        XCTAssertEqual(harness.model.systemClipboardCaptureControlSnapshot.state, .active)

        harness.model.updateSystemClipboardCaptureControlState(
            SystemClipboardCaptureControlSnapshot(revision: 4, state: .resuming)
        )
        harness.model.toggleClipboardCaptureEnabled()
        XCTAssertEqual(enablementRequests, [true, false, true, false])
        XCTAssertEqual(preferenceRevisions, [0, 1, 2, 3])
    }
}
