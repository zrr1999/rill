import XCTest

@testable import RillCore
@testable import RillUI

final class LocalPersistenceStatusPresentationTests: XCTestCase {
  private let sessionOnly = LocalPersistenceStatus.sessionOnly(
    reason: .persistentStorageUnavailable
  )

  func testReadyPersistenceHasNoGlobalWarningPresentation() {
    for language in AppLanguage.allCases {
      XCTAssertNil(
        LocalPersistenceStatusPresentation.make(
          status: .ready,
          language: language
        )
      )
    }
  }

  func testSessionOnlyPresentationNamesAffectedSurfacesWithoutSensitiveDetails() throws {
    let english = try XCTUnwrap(
      LocalPersistenceStatusPresentation.make(
        status: sessionOnly,
        language: .english
      )
    )
    let simplifiedChinese = try XCTUnwrap(
      LocalPersistenceStatusPresentation.make(
        status: sessionOnly,
        language: .simplifiedChinese
      )
    )

    XCTAssertTrue(english.bannerMessage.contains("History"))
    XCTAssertTrue(english.bannerMessage.contains("records and collections"))
    XCTAssertTrue(english.bannerMessage.contains("settings"))
    XCTAssertTrue(english.bannerMessage.contains("Existing saved data was not reset or deleted"))
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("运行历史"))
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("记录与记录集"))
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("设置"))

    for presentation in [english, simplifiedChinese] {
      XCTAssertFalse(presentation.bannerMessage.contains("/Users/"))
      XCTAssertFalse(presentation.bannerMessage.contains("sqlite"))
      XCTAssertFalse(presentation.bannerMessage.contains("PRIVATE-CONTENT-CANARY"))
      XCTAssertFalse(try XCTUnwrap(presentation.actionTitle).isEmpty)
      XCTAssertFalse(presentation.menuTitle.isEmpty)
    }
  }

  func testRetainedAlternateKeyIsVisibleWithoutClaimingStorageIsUnavailable() throws {
    let status = LocalPersistenceStatus.readyWithNotice(
      .alternateDataProtectionKeyRetained
    )
    let english = try XCTUnwrap(
      LocalPersistenceStatusPresentation.make(status: status, language: .english)
    )
    let simplifiedChinese = try XCTUnwrap(
      LocalPersistenceStatusPresentation.make(
        status: status,
        language: .simplifiedChinese
      )
    )

    XCTAssertTrue(english.bannerMessage.contains("continue to be saved"))
    XCTAssertTrue(english.bannerMessage.contains("No action is required"))
    XCTAssertFalse(english.bannerMessage.contains("session-only"))
    XCTAssertNil(english.actionTitle)
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("继续保存"))
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("无需执行任何操作"))
    XCTAssertNil(simplifiedChinese.actionTitle)
  }

  func testLockedKeychainPresentationProvidesAccurateRecoveryWithoutSensitiveDetails() throws {
    let status = LocalPersistenceStatus.sessionOnly(
      reason: .keychainTemporarilyUnavailable
    )
    let english = try XCTUnwrap(
      LocalPersistenceStatusPresentation.make(
        status: status,
        language: .english
      )
    )
    let simplifiedChinese = try XCTUnwrap(
      LocalPersistenceStatusPresentation.make(
        status: status,
        language: .simplifiedChinese
      )
    )

    XCTAssertTrue(english.bannerMessage.contains("Unlock your Mac"))
    XCTAssertTrue(english.bannerMessage.contains("quit and reopen Rill"))
    XCTAssertTrue(english.bannerMessage.contains("Existing saved data was not reset or deleted"))
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("解锁 Mac"))
    XCTAssertTrue(simplifiedChinese.bannerMessage.contains("退出并重新打开 Rill"))

    for presentation in [english, simplifiedChinese] {
      XCTAssertFalse(presentation.bannerMessage.contains("/Users/"))
      XCTAssertFalse(presentation.bannerMessage.contains("OSStatus"))
      XCTAssertFalse(presentation.bannerMessage.contains("sqlite"))
      XCTAssertFalse(presentation.bannerMessage.contains("PRIVATE-CONTENT-CANARY"))
    }
  }

  func testBannerNeverRequestsFocusAndOnlyExplicitActionTargetsStorageSettings() {
    XCTAssertFalse(LocalPersistenceBannerFocusPolicy.requestsFocusOnAppearance)
    XCTAssertEqual(LocalPersistenceBannerFocusPolicy.actionDestination, .storage)
  }

  func testHistoryFailureReplacesInvalidRetryWithStorageSettingsAction() {
    let ready = HistoryLoadFailurePresentation.make(
      persistenceStatus: .ready,
      language: .english
    )
    let unavailable = HistoryLoadFailurePresentation.make(
      persistenceStatus: sessionOnly,
      language: .english
    )

    XCTAssertEqual(ready.action, .retry)
    XCTAssertEqual(unavailable.action, .viewStorageSettings)
    XCTAssertEqual(unavailable.actionTitle, "View Storage Settings")
    XCTAssertFalse(unavailable.message.lowercased().contains("retry"))
  }

  func testMenuBarSurfacesSessionOnlyStateWithoutHidingActiveOperationStatus() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: true,
      recordCount: 2,
      canDeliverNextRecord: true,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      localPersistenceStatus: sessionOnly
    )

    XCTAssertEqual(state.statusTitle, "Voice run active")
    XCTAssertEqual(
      state.persistenceStatusTitle,
      "Session-only storage"
    )
    XCTAssertEqual(
      state.persistenceStatusDetail,
      "History, clipboard, and settings changes are not being saved."
    )
    XCTAssertEqual(
      state.persistenceStatusSystemImage,
      "externaldrive.badge.exclamationmark"
    )
  }
}
