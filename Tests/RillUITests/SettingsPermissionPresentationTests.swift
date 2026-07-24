import XCTest
@testable import RillCore
@testable import RillUI

final class SettingsPermissionPresentationTests: XCTestCase {
    func testOptionalDeniedPermissionIsNeutralAndHasNoForcedAction() {
        let presentation = SettingsPermissionPresentation.make(
            state: .denied,
            isRequired: false,
            optionalDetail: "Optional for the current output mode.",
            language: .english
        )

        XCTAssertEqual(presentation.detail, "Optional for the current output mode.")
        XCTAssertEqual(presentation.tone, .secondary)
        XCTAssertEqual(presentation.action, .none)
    }

    func testOptionalUnknownPermissionIsNeutralAndHasNoForcedAction() {
        let presentation = SettingsPermissionPresentation.make(
            state: .unknown,
            isRequired: false,
            optionalDetail: "当前输出模式下可选。",
            language: .simplifiedChinese
        )

        XCTAssertEqual(presentation.detail, "当前输出模式下可选。")
        XCTAssertEqual(presentation.tone, .secondary)
        XCTAssertEqual(presentation.action, .none)
    }

    func testRequiredUnknownPermissionOffersRequest() {
        let presentation = SettingsPermissionPresentation.make(
            state: .unknown,
            isRequired: true,
            optionalDetail: nil,
            language: .english
        )

        XCTAssertEqual(presentation.detail, "Unknown")
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.action, .request)
    }

    func testRequiredDeniedPermissionOffersSettings() {
        let presentation = SettingsPermissionPresentation.make(
            state: .denied,
            isRequired: true,
            optionalDetail: nil,
            language: .english
        )

        XCTAssertEqual(presentation.detail, "Denied")
        XCTAssertEqual(presentation.tone, .error)
        XCTAssertEqual(presentation.action, .openSettings)
    }
}
