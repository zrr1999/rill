import AppKit
import XCTest
@testable import RillUI

@MainActor
final class ClipboardInputMethodGuardTests: XCTestCase {
    func testReturnHandlingIsDisabledWhileMarkedTextIsActive() {
        XCTAssertFalse(
            ClipboardInputMethodGuard.shouldHandleReturn(
                for: MarkedTextTestView(hasMarkedText: true)
            )
        )
    }

    func testReturnHandlingRemainsEnabledWithoutMarkedText() {
        XCTAssertTrue(
            ClipboardInputMethodGuard.shouldHandleReturn(
                for: MarkedTextTestView(hasMarkedText: false)
            )
        )
        XCTAssertTrue(ClipboardInputMethodGuard.shouldHandleReturn(for: nil))
    }

    func testDeleteHandlingNeverEscapesAnActiveFieldEditor() {
        XCTAssertFalse(
            ClipboardInputMethodGuard.shouldHandleDelete(
                for: MarkedTextTestView(hasMarkedText: true)
            )
        )
        XCTAssertFalse(
            ClipboardInputMethodGuard.shouldHandleDelete(
                for: MarkedTextTestView(hasMarkedText: false)
            )
        )
        XCTAssertTrue(ClipboardInputMethodGuard.shouldHandleDelete(for: nil))
    }

    func testEveryModalStateDisablesParentClipboardKeyboardActions() {
        for state in [
            (hasPresentedSheet: true, hasPendingDeletion: false),
            (hasPresentedSheet: false, hasPendingDeletion: true),
            (hasPresentedSheet: true, hasPendingDeletion: true),
        ] {
            XCTAssertFalse(
                ClipboardViewModalPolicy.allowsParentKeyboardAction(
                    hasPresentedSheet: state.hasPresentedSheet,
                    hasPendingDeletion: state.hasPendingDeletion
                )
            )
        }

        XCTAssertTrue(
            ClipboardViewModalPolicy.allowsParentKeyboardAction(
                hasPresentedSheet: false,
                hasPendingDeletion: false
            )
        )
    }

    func testDeletionRequestCannotReplaceOrBypassAnExistingModal() {
        XCTAssertTrue(
            ClipboardViewModalPolicy.allowsDeletionRequest(
                hasPresentedSheet: false,
                hasPendingDeletion: false
            )
        )
        XCTAssertFalse(
            ClipboardViewModalPolicy.allowsDeletionRequest(
                hasPresentedSheet: true,
                hasPendingDeletion: false
            )
        )
        XCTAssertFalse(
            ClipboardViewModalPolicy.allowsDeletionRequest(
                hasPresentedSheet: false,
                hasPendingDeletion: true
            )
        )
    }
}

private final class MarkedTextTestView: NSTextView {
    private let markedText: Bool

    init(hasMarkedText: Bool) {
        self.markedText = hasMarkedText
        super.init(frame: .zero, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hasMarkedText() -> Bool {
        markedText
    }
}
