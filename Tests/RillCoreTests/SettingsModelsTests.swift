import XCTest
@testable import RillCore

final class SettingsModelsTests: XCTestCase {
    func testWhisperKitDefaultsAllowExplicitDownloadWithoutBackgroundPrewarm() {
        let settings = LocalSpeechSettings()

        XCTAssertTrue(settings.downloadIfNeeded)
        XCTAssertFalse(settings.prewarm)
    }
}
