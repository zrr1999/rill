import XCTest
@testable import RillCore
@testable import RillUI

final class ClipboardPersistencePresentationTests: XCTestCase {
    func testAvailablePersistenceHasNoWarningPresentation() {
        XCTAssertNil(
            ClipboardPersistenceWarningPresentation.make(
                availability: .available,
                language: .english
            )
        )
        XCTAssertNil(
            ClipboardPersistenceWarningPresentation.make(
                availability: .available,
                language: .simplifiedChinese
            )
        )
    }

    func testNotConfiguredPresentationIsSessionOnlyAndHasNoInvalidRecoveryAction() throws {
        let english = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .notConfigured,
                language: .english
            )
        )
        let simplifiedChinese = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .notConfigured,
                language: .simplifiedChinese
            )
        )

        XCTAssertTrue(english.message.contains("session will be lost"))
        XCTAssertTrue(simplifiedChinese.message.contains("退出后丢失"))
        for presentation in [english, simplifiedChinese] {
            XCTAssertNil(presentation.retryTitle)
            XCTAssertNil(presentation.resetTitle)
        }
    }

    func testCleanupPendingPresentationReportsLogicalRemovalWithoutClaimingPurge() throws {
        let english = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .cleanupPending,
                language: .english
            )
        )
        let simplifiedChinese = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .cleanupPending,
                language: .simplifiedChinese
            )
        )

        XCTAssertTrue(english.message.contains("data was removed"))
        XCTAssertTrue(english.message.contains("retry cleanup"))
        XCTAssertTrue(simplifiedChinese.message.contains("数据已删除"))
        for presentation in [english, simplifiedChinese] {
            XCTAssertNil(presentation.retryTitle)
            XCTAssertNil(presentation.resetTitle)
        }
    }

    func testLoadUnavailablePresentationExplainsPreservedDataAndConfirmedReset() throws {
        let english = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .loadUnavailable,
                language: .english
            )
        )
        let simplifiedChinese = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .loadUnavailable,
                language: .simplifiedChinese
            )
        )

        XCTAssertEqual(english.title, "Clipboard history storage is unavailable")
        XCTAssertEqual(
            english.message,
            "Changes made in this session will not be saved. Rill did not overwrite your existing data. Repair storage access, or reset storage to permanently delete all saved and session-only clipboard items, groups, and routing."
        )
        XCTAssertNil(english.retryTitle)
        XCTAssertEqual(english.resetTitle, "Reset Storage…")
        XCTAssertEqual(simplifiedChinese.title, "剪贴板历史存储不可用")
        XCTAssertEqual(
            simplifiedChinese.message,
            "本次会话中的修改不会持久化；Rill 未覆盖原有数据。请修复存储访问，或重置存储以永久删除所有已保存及本次会话中的剪贴板条目、分组和路由。"
        )
        XCTAssertNil(simplifiedChinese.retryTitle)
        XCTAssertEqual(simplifiedChinese.resetTitle, "重置存储…")

        for language in AppLanguage.allCases {
            let failed = try XCTUnwrap(
                ClipboardPersistenceWarningPresentation.make(
                    availability: .loadUnavailable,
                    resetFailed: true,
                    language: language
                )
            )
            XCTAssertNotNil(failed.resetTitle)
            XCTAssertFalse(failed.message.contains("PRIVATE-CONTENT-CANARY"))
        }
    }

    func testSaveFailedPresentationExplainsAutomaticAndImmediateRetry() throws {
        let english = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .saveFailed,
                language: .english
            )
        )
        let simplifiedChinese = try XCTUnwrap(
            ClipboardPersistenceWarningPresentation.make(
                availability: .saveFailed,
                language: .simplifiedChinese
            )
        )

        XCTAssertEqual(english.message, "Automatic retry is in progress. You can also retry immediately.")
        XCTAssertEqual(english.retryTitle, "Retry Now")
        XCTAssertNil(english.resetTitle)
        XCTAssertEqual(simplifiedChinese.message, "正在自动重试；你也可以立即重试。")
        XCTAssertEqual(simplifiedChinese.retryTitle, "立即重试")
        XCTAssertNil(simplifiedChinese.resetTitle)
    }

    func testRetryPolicyAllowsOnlyOneSaveFailedRetryBeforeShutdown() {
        XCTAssertTrue(
            ClipboardPersistenceRetryPolicy.canRetry(
                availability: .saveFailed,
                isRetrying: false,
                hasBegunApplicationShutdown: false
            )
        )
        XCTAssertFalse(
            ClipboardPersistenceRetryPolicy.canRetry(
                availability: .available,
                isRetrying: false,
                hasBegunApplicationShutdown: false
            )
        )
        XCTAssertFalse(
            ClipboardPersistenceRetryPolicy.canRetry(
                availability: .loadUnavailable,
                isRetrying: false,
                hasBegunApplicationShutdown: false
            )
        )
        XCTAssertFalse(
            ClipboardPersistenceRetryPolicy.canRetry(
                availability: .saveFailed,
                isRetrying: true,
                hasBegunApplicationShutdown: false
            )
        )
        XCTAssertFalse(
            ClipboardPersistenceRetryPolicy.canRetry(
                availability: .saveFailed,
                isRetrying: false,
                hasBegunApplicationShutdown: true
            )
        )
    }

    func testResetPolicyAllowsOnlyOneUnavailableResetBeforeShutdown() {
        XCTAssertTrue(
            ClipboardPersistenceResetPolicy.canReset(
                availability: .loadUnavailable,
                isResetting: false,
                hasBegunApplicationShutdown: false
            )
        )
        for availability in [
            ClipboardPersistenceAvailability.available,
            .notConfigured,
            .cleanupPending,
            .saveFailed,
        ] {
            XCTAssertFalse(
                ClipboardPersistenceResetPolicy.canReset(
                    availability: availability,
                    isResetting: false,
                    hasBegunApplicationShutdown: false
                )
            )
        }
        XCTAssertFalse(
            ClipboardPersistenceResetPolicy.canReset(
                availability: .loadUnavailable,
                isResetting: true,
                hasBegunApplicationShutdown: false
            )
        )
        XCTAssertFalse(
            ClipboardPersistenceResetPolicy.canReset(
                availability: .loadUnavailable,
                isResetting: false,
                hasBegunApplicationShutdown: true
            )
        )
    }

    func testResetConfirmationIsBilingualExplicitDestructiveAndContentFree() {
        let english = ClipboardPersistenceResetConfirmationPresentation.make(language: .english)
        let simplifiedChinese = ClipboardPersistenceResetConfirmationPresentation.make(
            language: .simplifiedChinese
        )

        XCTAssertTrue(english.message.contains("permanently deletes"))
        XCTAssertTrue(english.message.contains("cannot be undone"))
        XCTAssertTrue(simplifiedChinese.message.contains("永久删除"))
        XCTAssertTrue(simplifiedChinese.message.contains("无法撤销"))
        for presentation in [english, simplifiedChinese] {
            XCTAssertFalse(presentation.title.contains("PRIVATE-CONTENT-CANARY"))
            XCTAssertFalse(presentation.message.contains("PRIVATE-CONTENT-CANARY"))
            XCTAssertFalse(presentation.actionTitle.contains("PRIVATE-CONTENT-CANARY"))
        }
    }

    func testStorageRejectionsHaveBilingualContentFreePresentation() throws {
        let reasons: [ClipboardStorageRejectionReason] = [
            .itemTooLarge,
            .imageRepresentationInvalid,
            .activeItemLimitReached,
            .activeItemInUse,
            .historyItemLimitReached,
            .totalByteLimitReached,
            .itemEncodingFailed,
            .metadataLimitReached,
        ]

        XCTAssertNil(
            ClipboardStorageWarningPresentation.make(
                reason: nil,
                language: .english
            )
        )
        for reason in reasons {
            for language in AppLanguage.allCases {
                let presentation = try XCTUnwrap(
                    ClipboardStorageWarningPresentation.make(
                        reason: reason,
                        language: language
                    )
                )
                XCTAssertFalse(presentation.title.isEmpty)
                XCTAssertFalse(presentation.message.isEmpty)
                XCTAssertFalse(presentation.title.contains("PRIVATE-CONTENT-CANARY"))
                XCTAssertFalse(presentation.message.contains("PRIVATE-CONTENT-CANARY"))
            }
        }

        let legacy = try XCTUnwrap(
            ClipboardStorageWarningPresentation.make(
                reason: .activeItemLimitReached,
                context: .legacyOverCapacity,
                language: .english
            )
        )
        let persisted = try XCTUnwrap(
            ClipboardStorageWarningPresentation.make(
                reason: .totalByteLimitReached,
                context: .persistedStateRejected,
                language: .simplifiedChinese
            )
        )
        XCTAssertTrue(legacy.message.contains("Existing active items were preserved"))
        XCTAssertTrue(persisted.message.contains("未加载或覆盖"))
    }
}
