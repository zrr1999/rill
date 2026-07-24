import XCTest

@testable import RillCore

final class LocalSpeechSettingsSourceTests: XCTestCase {
  func testSourceFailsClosedUntilSettingsAreAvailable() throws {
    let source = LocalSpeechSettingsSource()

    XCTAssertFalse(source.hasAvailableSettings)
    XCTAssertThrowsError(try source.currentSettings()) { error in
      XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .notReady)
    }

    let settings = LocalSpeechSettings(
      model: "trusted-cantonese",
      language: "yue",
      downloadIfNeeded: false,
      prewarm: true
    )
    source.update(settings)

    XCTAssertTrue(source.hasAvailableSettings)
    XCTAssertEqual(try source.currentSettings(), settings)
  }

  func testUnavailableStateCanRecoverWithOneSynchronousUpdate() throws {
    let source = LocalSpeechSettingsSource(initialSettings: LocalSpeechSettings(model: "first"))

    source.markUnavailable()
    XCTAssertFalse(source.hasAvailableSettings)
    XCTAssertThrowsError(try source.currentSettings()) { error in
      XCTAssertEqual(error as? LocalSpeechSettingsSourceError, .unavailable)
    }

    let recovered = LocalSpeechSettings(model: "second")
    source.update(recovered)

    XCTAssertTrue(source.hasAvailableSettings)
    XCTAssertEqual(try source.currentSettings(), recovered)
  }
}
