import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelLocalPersistenceStatusTests: XCTestCase {
    func testDefaultStatusRemainsReadyForExistingCallSites() {
        XCTAssertEqual(makeHarness().model.localPersistenceStatus, .ready)
    }

    func testInjectedSessionOnlyStatusIsPubliclyReadableAndImmutableAtRuntime() {
        let status = LocalPersistenceStatus.sessionOnly(
            reason: .persistentStorageUnavailable
        )
        let model = makeHarness(localPersistenceStatus: status).model

        XCTAssertEqual(model.localPersistenceStatus, status)
        XCTAssertTrue(model.localPersistenceStatus.isSessionOnly)
    }

    func testMenuStorageActionUsesTypedStorageDestinationBeforeOpeningWindow() {
        let model = makeHarness(
            localPersistenceStatus: .sessionOnly(
                reason: .persistentStorageUnavailable
            )
        ).model
        var openedMainWindowCount = 0
        let menu = MenuBarStatusView(
            model: model,
            openMainWindow: { openedMainWindowCount += 1 }
        )

        menu.openStorageSettings()

        XCTAssertEqual(model.selectedSidebarSection, .records)
        XCTAssertEqual(model.selectedSettingsPane, .data)
        XCTAssertEqual(model.settingsNavigationRequest?.section, .storage)
        XCTAssertEqual(openedMainWindowCount, 1)
    }
}
