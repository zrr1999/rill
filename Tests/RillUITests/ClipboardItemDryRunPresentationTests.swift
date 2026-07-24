import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

final class ClipboardItemDryRunPresentationTests: XCTestCase {
    func testEveryClosedDryRunValueHasBilingualPresentation() {
        for language in AppLanguage.allCases {
            for operation in ClipboardItemDryRunOperation.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunOperation(operation, language: language),
                    rawValue: operation.rawValue
                )
            }
            for status in ClipboardItemDryRunStatus.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunStatusTitle(status, language: language),
                    rawValue: status.rawValue
                )
            }
            for reason in ClipboardItemDryRunReason.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunReason(reason, language: language),
                    rawValue: reason.rawValue
                )
            }
            for read in ClipboardItemDryRunReadCategory.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunRead(read, language: language),
                    rawValue: read.rawValue
                )
            }
            for effect in ClipboardItemDryRunEffect.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunEffect(effect, language: language),
                    rawValue: effect.rawValue
                )
            }
            for replacement in ClipboardItemDryRunSourceReplacementPlan.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunReplacement(replacement, language: language),
                    rawValue: replacement.rawValue
                )
            }
            for issue in ClipboardItemDryRunIssueKind.allCases {
                assertLocalized(
                    UIStrings.clipboardItemDryRunIssue(
                        ClipboardItemDryRunIssue(kind: issue),
                        language: language
                    ),
                    rawValue: issue.rawValue
                )
            }
        }
    }

    func testPresentationIsContentFreeAndCoversEverySection() {
        let workflowID = UUID(uuidString: "CA11CA11-CA11-CA11-CA11-CA11CA11CA11")!
        let receipt = ClipboardItemDryRunReceipt(
            workflowID: workflowID,
            operation: .replace,
            status: .requiresConfirmation,
            reads: [
                ClipboardItemDryRunRead(category: .sourceItemText, usage: .required),
            ],
            transforms: [
                WorkflowExplanationTransform(
                    kind: .whitespaceNormalization,
                    availability: .available,
                    usage: .required,
                    processingDestination: .onDevice
                ),
            ],
            actionEffects: [
                ClipboardItemDryRunActionEffect(
                    sourceActionIndex: 0,
                    effect: .webhookRequest,
                    configurationState: .configured,
                    processingDestination: .remoteEndpoint
                ),
            ],
            processingDestinations: [.onDevice, .remoteEndpoint],
            sourceReplacementPlan: .exactlyOne,
            privacyReasons: [.cloudConfirmationRequired],
            redactedInputCategories: [.clipboardText],
            issues: [
                ClipboardItemDryRunIssue(
                    kind: .privacyConfirmationRequired,
                    component: .privacyPolicy
                ),
            ]
        )

        for language in AppLanguage.allCases {
            let presentation = ClipboardItemDryRunPresentation.make(
                receipt: receipt,
                language: language
            )
            let description = String(describing: presentation)

            XCTAssertEqual(presentation.reads.count, 1)
            XCTAssertEqual(presentation.transforms.count, 1)
            XCTAssertEqual(presentation.effects.count, 1)
            XCTAssertEqual(presentation.destinations.count, 2)
            XCTAssertEqual(presentation.replacement.count, 1)
            XCTAssertFalse(presentation.privacyConditions.isEmpty)
            XCTAssertEqual(presentation.issues.count, 1)
            XCTAssertFalse(description.contains(workflowID.uuidString))
            XCTAssertFalse(description.contains("CA11CA11"))
            XCTAssertFalse(description.contains("https://"))
            XCTAssertFalse(description.contains("Bearer"))
        }
    }

    func testCorrelationRejectsEveryMismatchedIdentityField() {
        let item = ClipboardHistoryItem(
            id: UUID(),
            version: ClipboardItemVersion(generationID: UUID(), revision: 4),
            groupID: ClipboardGroup.defaultGroupID,
            text: "CANARY-ITEM-CONTENT",
            sourceKind: .system
        )
        let subject = ClipboardItemDryRunSubject(
            itemID: item.id,
            itemVersion: item.version,
            groupID: item.groupID,
            contentKind: item.contentKind,
            captureTags: item.captureTags,
            hasTransferableContent: item.supportsDirectPaste
        )
        let request = ClipboardItemDryRunLoadRequest(
            id: UUID(),
            itemID: item.id,
            expectedItemVersion: item.version,
            operation: .use,
            workflowID: nil
        )
        let receipt = ClipboardItemDryRunReceipt(
            workflowID: nil,
            operation: .use,
            status: .ready,
            reads: [],
            actionEffects: [],
            processingDestinations: []
        )
        let prepared = PreparedClipboardItemDryRun(subject: subject, receipt: receipt)

        XCTAssertTrue(
            ClipboardItemDryRunCorrelation.validates(
                prepared,
                request: request,
                currentItem: item
            )
        )

        let staleRequest = ClipboardItemDryRunLoadRequest(
            id: request.id,
            itemID: item.id,
            expectedItemVersion: item.version.advanced(),
            operation: .use,
            workflowID: nil
        )
        XCTAssertFalse(
            ClipboardItemDryRunCorrelation.validates(
                prepared,
                request: staleRequest,
                currentItem: item
            )
        )

        var duplicatedTagsItem = item
        duplicatedTagsItem.captureTags = [
            .excludeFromWorkflowCapture,
            .excludeFromWorkflowCapture,
        ]
        let normalizedSubject = ClipboardItemDryRunSubject(
            itemID: duplicatedTagsItem.id,
            itemVersion: duplicatedTagsItem.version,
            groupID: duplicatedTagsItem.groupID,
            contentKind: duplicatedTagsItem.contentKind,
            captureTags: duplicatedTagsItem.captureTags,
            hasTransferableContent: duplicatedTagsItem.supportsDirectPaste
        )
        XCTAssertTrue(
            ClipboardItemDryRunCorrelation.validates(
                PreparedClipboardItemDryRun(subject: normalizedSubject, receipt: receipt),
                request: request,
                currentItem: duplicatedTagsItem
            )
        )

        var changedItem = item
        changedItem.advanceVersion()
        XCTAssertFalse(
            ClipboardItemDryRunCorrelation.validates(
                prepared,
                request: request,
                currentItem: changedItem
            )
        )

        let wrongReceipt = ClipboardItemDryRunReceipt(
            workflowID: nil,
            operation: .replay,
            status: .ready,
            reads: [],
            actionEffects: [],
            processingDestinations: []
        )
        XCTAssertFalse(
            ClipboardItemDryRunCorrelation.validates(
                PreparedClipboardItemDryRun(subject: subject, receipt: wrongReceipt),
                request: request,
                currentItem: item
            )
        )
    }

    private func assertLocalized(_ value: String, rawValue: String) {
        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(value, rawValue)
    }
}
