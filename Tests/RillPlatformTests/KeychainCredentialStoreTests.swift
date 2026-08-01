import Security
import XCTest
@testable import RillCore
@testable import RillPlatform

final class KeychainCredentialStoreTests: XCTestCase {
    func testDataProtectionQueryIsLocalAndNonSynchronizable() {
        let store = KeychainCredentialStore(
            service: "dev.zrr.Rill.tests",
            useDataProtectionKeychain: true
        )

        let query = store.baseQuery(for: .openAIAPIKey, useDataProtectionKeychain: true)

        XCTAssertTrue(store.usesDataProtectionKeychain)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertEqual(query[kSecAttrService] as? String, "dev.zrr.Rill.tests")
        XCTAssertEqual(query[kSecAttrAccount] as? String, SecureCredentialKey.openAIAPIKey.rawValue)
    }

    func testOpenAIUsesItsOwnKeychainAccount() {
        let store = KeychainCredentialStore(
            service: "dev.zrr.Rill.tests",
            useDataProtectionKeychain: true
        )

        let query = store.baseQuery(for: .openAIAPIKey, useDataProtectionKeychain: true)

        XCTAssertEqual(
            query[kSecAttrAccount] as? String,
            SecureCredentialKey.openAIAPIKey.rawValue
        )
        XCTAssertNotEqual(
            query[kSecAttrAccount] as? String,
            SecureCredentialKey.legacyWhisperKitModelToken.rawValue
        )
    }

    func testLegacyQueryDoesNotChangeTheOriginalKeychainNamespace() {
        let store = KeychainCredentialStore(
            service: "dev.zrr.Rill.tests",
            useDataProtectionKeychain: false
        )

        let query = store.baseQuery(for: .legacyWhisperKitModelToken, useDataProtectionKeychain: false)

        XCTAssertFalse(store.usesDataProtectionKeychain)
        XCTAssertNil(query[kSecUseDataProtectionKeychain])
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
    }
}
