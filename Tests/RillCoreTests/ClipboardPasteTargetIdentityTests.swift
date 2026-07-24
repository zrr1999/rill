import XCTest
@testable import RillCore

final class ClipboardPasteTargetIdentityTests: XCTestCase {
    func testIdentityRequiresANonzeroProcessIdentifier() {
        XCTAssertNil(
            ClipboardPasteTargetIdentity(
                processIdentifier: 0,
                bundleIdentifier: "com.example.Editor"
            )
        )
        XCTAssertNil(
            ClipboardPasteTargetIdentity(
                processIdentifier: -1,
                bundleIdentifier: "com.example.Editor"
            )
        )
        XCTAssertNil(
            ClipboardPasteTargetIdentity(
                focus: FocusSnapshot(
                    applicationName: nil,
                    bundleIdentifier: "com.example.Editor",
                    processIdentifier: nil,
                    focusedRole: nil,
                    selectedText: "",
                    secureInput: false
                )
            )
        )
    }

    func testIdentityMatchesProcessAndNonemptyBundleExactly() throws {
        let target = try XCTUnwrap(
            ClipboardPasteTargetIdentity(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Editor"
            )
        )

        XCTAssertTrue(target.matches(focus(processIdentifier: 42, bundleIdentifier: "com.example.Editor")))
        XCTAssertFalse(target.matches(focus(processIdentifier: 84, bundleIdentifier: "com.example.Editor")))
        XCTAssertFalse(target.matches(focus(processIdentifier: 42, bundleIdentifier: "com.example.Other")))
        XCTAssertFalse(target.matches(focus(processIdentifier: 42, bundleIdentifier: nil)))
    }

    func testEmptyBundleFallsBackToExactProcessMatching() throws {
        let target = try XCTUnwrap(
            ClipboardPasteTargetIdentity(
                processIdentifier: 42,
                bundleIdentifier: ""
            )
        )

        XCTAssertNil(target.bundleIdentifier)
        XCTAssertTrue(target.matches(focus(processIdentifier: 42, bundleIdentifier: nil)))
        XCTAssertTrue(target.matches(focus(processIdentifier: 42, bundleIdentifier: "com.example.Editor")))
        XCTAssertFalse(target.matches(focus(processIdentifier: 84, bundleIdentifier: nil)))
    }

    private func focus(
        processIdentifier: Int32,
        bundleIdentifier: String?
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: nil,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        )
    }
}
