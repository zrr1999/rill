import ApplicationServices
import XCTest
@testable import RillPlatform

final class FunctionKeyCompatibilityTests: XCTestCase {
    func testGlobeKeyCodeVariantStartsAndStopsPushToTalk() {
        var recognizer = PushToTalkGestureRecognizer()

        let press = recognizer.handle(
            type: .flagsChanged,
            keyCode: 179,
            flags: [.maskSecondaryFn]
        )
        let release = recognizer.handle(
            type: .flagsChanged,
            keyCode: 179,
            flags: []
        )

        XCTAssertEqual(press, .swallow(.pushToTalkPressed(.fnHold)))
        XCTAssertEqual(release, .swallow(.pushToTalkReleased(.fnHold)))
    }

    func testUnknownBareFunctionKeyCodeVariantStartsAndStopsPushToTalk() {
        var recognizer = PushToTalkGestureRecognizer()

        let press = recognizer.handle(
            type: .flagsChanged,
            keyCode: 255,
            flags: [.maskSecondaryFn]
        )
        let release = recognizer.handle(
            type: .flagsChanged,
            keyCode: 255,
            flags: []
        )

        XCTAssertEqual(press, .swallow(.pushToTalkPressed(.fnHold)))
        XCTAssertEqual(release, .swallow(.pushToTalkReleased(.fnHold)))
    }

    func testFunctionFamilyPhantomFlagsDoNotStartPushToTalk() {
        for keyCode: CGKeyCode in [79, 123, 126, 115, 117] {
            var recognizer = PushToTalkGestureRecognizer()

            XCTAssertEqual(
                recognizer.handle(
                    type: .flagsChanged,
                    keyCode: keyCode,
                    flags: [.maskSecondaryFn]
                ),
                .passThrough
            )
        }
    }

    func testModifierTransitionsWithFunctionFlagDoNotStartPushToTalk() {
        for keyCode: CGKeyCode in [57, 54, 55, 56, 60, 58, 61, 59, 62] {
            var recognizer = PushToTalkGestureRecognizer()

            XCTAssertEqual(
                recognizer.handle(
                    type: .flagsChanged,
                    keyCode: keyCode,
                    flags: [.maskSecondaryFn]
                ),
                .passThrough
            )
        }
    }

    func testModifiedFunctionChordDoesNotStartAfterModifierRelease() {
        var recognizer = PushToTalkGestureRecognizer()

        let modifiedPress = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn, .maskShift]
        )
        let shiftRelease = recognizer.handle(
            type: .flagsChanged,
            keyCode: 56,
            flags: [.maskSecondaryFn]
        )
        let functionRelease = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: []
        )
        let nextFunctionPress = recognizer.handle(
            type: .flagsChanged,
            keyCode: 63,
            flags: [.maskSecondaryFn]
        )

        XCTAssertEqual(modifiedPress, .passThrough)
        XCTAssertEqual(shiftRelease, .passThrough)
        XCTAssertEqual(functionRelease, .passThrough)
        XCTAssertEqual(nextFunctionPress, .swallow(.pushToTalkPressed(.fnHold)))
    }
}
