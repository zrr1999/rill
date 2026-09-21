import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class UIRefinementTests: XCTestCase {
    func testDeliveryTitleUsesOnlySuppliedTargetAndHandlesUnavailableName() {
        XCTAssertEqual(RecordDeliveryTitle.make(applicationName: " Notes ", language: .english), "Insert into Notes")
        XCTAssertEqual(RecordDeliveryTitle.make(applicationName: "备忘录", language: .simplifiedChinese), "插入到 备忘录")
        for name: String? in [nil, "", "  "] {
            XCTAssertEqual(RecordDeliveryTitle.make(applicationName: name, language: .english),
                           L10n.recordText(.insertInPreviousApp, language: .english))
        }
    }

    func testPresentationCopyIsLocalizedAndNeverFallsBackToKey() {
        for key in L10n.PresentationKey.allCases {
            for language in AppLanguage.allCases {
                let value = L10n.presentation(key, language: language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key.rawValue)
            }
        }
    }
}
