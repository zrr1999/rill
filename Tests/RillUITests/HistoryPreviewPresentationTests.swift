import XCTest
@testable import RillCore
@testable import RillUI

final class HistoryPreviewPresentationTests: XCTestCase {
    func testFullModeExposesCompleteTextAndRestrictedModeUsesBoundedDisplayText() {
        let privateText = String(repeating: "private ", count: 20) + "TAIL-CANARY"
        XCTAssertEqual(
            HistoryPreviewPresentation(
                text: privateText,
                mode: .full,
                language: .english
            ),
            .visible(text: privateText, lineLimit: nil)
        )
        let restricted = HistoryPreviewPresentation(
            text: privateText,
            mode: .restricted,
            language: .simplifiedChinese
        )
        guard case .visible(let displayText, let lineLimit) = restricted else {
            return XCTFail("Restricted mode should produce bounded display text.")
        }
        XCTAssertEqual(lineLimit, 3)
        XCTAssertLessThanOrEqual(
            displayText.count,
            HistoryPreviewPresentation.restrictedCharacterLimit
        )
        XCTAssertFalse(displayText.contains("TAIL-CANARY"))
        XCTAssertNotEqual(displayText, privateText)
    }

    func testDisabledModeNeverExposesTextAndUsesExistingLocalizedCopy() {
        XCTAssertEqual(
            HistoryPreviewPresentation(
                text: "private result",
                mode: .disabled,
                language: .english
            ),
            .hidden(message: "Preview hidden by privacy setting")
        )
        XCTAssertEqual(
            HistoryPreviewPresentation(
                text: "private result",
                mode: .disabled,
                language: .simplifiedChinese
            ),
            .hidden(message: "已按隐私设置隐藏预览")
        )
    }

    func testMissingTextProducesNoPreviewInEveryMode() {
        for mode in PrivacyHistoryPreviewMode.allCases {
            XCTAssertNil(
                HistoryPreviewPresentation(
                    text: nil,
                    mode: mode,
                    language: .english
                )
            )
            XCTAssertNil(
                HistoryPreviewPresentation(
                    text: nil,
                    mode: mode,
                    language: .simplifiedChinese
                )
            )
        }
    }
}
