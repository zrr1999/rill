import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor GroupAuthorizationDescriptorProbe: ClipboardGroupEventSink {
    private var descriptors: [ClipboardGroupEventDescriptor] = []

    func submit(
        _ descriptor: ClipboardGroupEventDescriptor
    ) async -> ClipboardGroupEventSubmissionResult {
        descriptors.append(descriptor)
        return .accepted
    }

    func snapshot() -> [ClipboardGroupEventDescriptor] {
        descriptors
    }
}

private actor GroupAuthorizationConfirmationProbe {
    private var count = 0

    func record() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

final class ClipboardGroupRunAuthorizationTests: XCTestCase {
    func testDeliveryStackResolvesSourceIdentityOnlyForExactItemIncarnation() async throws {
        let descriptorProbe = GroupAuthorizationDescriptorProbe()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardGroupEventSink: descriptorProbe
        )
        let itemID = UUID()
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "private-source-body",
                sourceApplicationName: "Vault",
                sourceBundleIdentifier: "com.example.vault",
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        let descriptors = await descriptorProbe.snapshot()
        let descriptor = try XCTUnwrap(descriptors.first)

        let resolvedSource = await stack.clipboardGroupRunAuthorizationSource(
            matching: descriptor
        )
        let source = try XCTUnwrap(resolvedSource)
        XCTAssertEqual(source.subject.itemID, itemID)
        XCTAssertEqual(source.subject.itemVersion, descriptor.itemVersion)
        XCTAssertEqual(source.itemSource.sourceApplicationName, "Vault")
        XCTAssertEqual(source.itemSource.sourceBundleIdentifier, "com.example.vault")
        XCTAssertEqual(source.privacyContext.focus.bundleIdentifier, "com.example.vault")
        XCTAssertEqual(source.privacyContext.clipboard.plainText, "")
        let initiallyMatches = await stack.matchesClipboardGroupRunAuthorizationSource(
            source
        )
        XCTAssertTrue(initiallyMatches)

        await stack.updateItemText(itemID, text: "changed", captureTags: [])

        let staleSource = await stack.clipboardGroupRunAuthorizationSource(
            matching: descriptor
        )
        let stillMatches = await stack.matchesClipboardGroupRunAuthorizationSource(source)
        XCTAssertNil(staleSource)
        XCTAssertFalse(stillMatches)
    }

    func testInteractiveReplayBlocksCloudFromSensitiveSourceBeforeTargetCapture() async throws {
        let itemSource = try await makeItemSource(
            applicationName: "Vault",
            bundleIdentifier: "com.example.vault"
        )
        let confirmation = GroupAuthorizationConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [
                        SensitiveAppRule(
                            bundleIdentifier: "com.example.vault",
                            applicationName: "Vault",
                            blocksClipboardHistory: false,
                            blocksWorkflowCapture: false,
                            blocksSelectedText: false,
                            blocksCloudProcessing: true
                        )
                    ],
                    cloudConfirmationRequired: false
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )
        let targetContext = ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: "Editor",
                bundleIdentifier: "com.example.editor",
                processIdentifier: 42,
                focusedRole: "AXTextArea",
                selectedText: "",
                secureInput: false
            ),
            clipboard: ClipboardSnapshot(plainText: "", changeCount: 1)
        )
        let workflow = WorkflowDefinition(
            name: "Cloud rewrite",
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [PostProcessStep(kind: .llmRewrite)],
                outputActions: [OutputActionReference(id: "stack.push")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange")
        )

        do {
            _ = try await gate.captureAuthorizedClipboardItemRunContext(
                source: itemSource,
                operation: .replay,
                privacyContextProvider: {
                    XCTFail("A blocked source must stop before target context capture.")
                    return targetContext
                },
                contextProvider: { _ in
                    XCTFail("A blocked source must stop before full target capture.")
                    return targetContext
                },
                workflow: workflow
            )
            XCTFail("The source application cloud block must be authoritative.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected source privacy error: \(error)")
        }

        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testSensitiveSourceBlocksCloudWithoutConsultingFrontmostApplication() async throws {
        let source = try await makeSource(
            applicationName: "Vault",
            bundleIdentifier: "com.example.vault"
        )
        let confirmation = GroupAuthorizationConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [
                        SensitiveAppRule(
                            bundleIdentifier: "com.example.vault",
                            applicationName: "Vault",
                            blocksClipboardHistory: false,
                            blocksWorkflowCapture: false,
                            blocksSelectedText: false,
                            blocksCloudProcessing: true
                        )
                    ],
                    cloudConfirmationRequired: false
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )

        let evaluation = await gate.evaluateNonInteractiveClipboardGroupRun(
            source: source,
            workflow: makeGroupWorkflow(usesCloudText: true)
        )

        XCTAssertEqual(evaluation, .blocked(reason: .cloudProcessingBlocked))
        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testConfirmationRequiredIsRejectedWithoutCallingConfirmationProvider() async throws {
        let source = try await makeSource(
            applicationName: "Editor",
            bundleIdentifier: "com.example.editor"
        )
        let confirmation = GroupAuthorizationConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: true
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )

        let evaluation = await gate.evaluateNonInteractiveClipboardGroupRun(
            source: source,
            workflow: makeGroupWorkflow(usesCloudText: true)
        )

        XCTAssertEqual(evaluation, .blocked(reason: .cloudConfirmationRequired))
        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testKnownLocalSourceCanPassPreflightButDoesNotReceiveCapability() async throws {
        let source = try await makeSource(
            applicationName: "Editor",
            bundleIdentifier: "com.example.editor"
        )
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: true
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("A non-interactive preflight must never request confirmation.")
                return false
            }
        )

        let evaluation = await gate.evaluateNonInteractiveClipboardGroupRun(
            source: source,
            workflow: makeGroupWorkflow(usesCloudText: false)
        )

        XCTAssertEqual(evaluation, .ready(processingDestinations: []))
    }

    func testUnknownSourceAndUnsafeActionPlanFailClosed() async throws {
        let unknownSource = try await makeSource(
            applicationName: nil,
            bundleIdentifier: nil
        )
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: false
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("A non-interactive preflight must never request confirmation.")
                return false
            }
        )

        let unknownEvaluation = await gate.evaluateNonInteractiveClipboardGroupRun(
            source: unknownSource,
            workflow: makeGroupWorkflow(usesCloudText: false)
        )
        var unsafeWorkflow = makeGroupWorkflow(usesCloudText: false)
        unsafeWorkflow.pipeline.outputActions = [OutputActionReference(id: "clipboard.copy")]
        let actionEvaluation = await gate.evaluateNonInteractiveClipboardGroupRun(
            source: unknownSource,
            workflow: unsafeWorkflow
        )

        XCTAssertEqual(unknownEvaluation, .blocked(reason: .workflowCaptureBlocked))
        XCTAssertEqual(actionEvaluation, .blocked(reason: .actionPlanUnsupported))
    }

    private func makeSource(
        applicationName: String?,
        bundleIdentifier: String?
    ) async throws -> ClipboardGroupRunAuthorizationSource {
        let descriptorProbe = GroupAuthorizationDescriptorProbe()
        let stack = DeliveryStack(
            eventBus: EventBus(),
            clipboardGroupEventSink: descriptorProbe
        )
        await stack.push(
            DeliveryItem(
                workflowID: UUID(),
                text: "private-source-body",
                sourceApplicationName: applicationName,
                sourceBundleIdentifier: bundleIdentifier,
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        let descriptors = await descriptorProbe.snapshot()
        let descriptor = try XCTUnwrap(descriptors.first)
        let source = await stack.clipboardGroupRunAuthorizationSource(
            matching: descriptor
        )
        return try XCTUnwrap(source)
    }

    private func makeItemSource(
        applicationName: String?,
        bundleIdentifier: String?
    ) async throws -> ClipboardItemRunAuthorizationSource {
        let stack = DeliveryStack(eventBus: EventBus())
        let itemID = UUID()
        await stack.push(
            DeliveryItem(
                id: itemID,
                workflowID: UUID(),
                text: "private-source-body",
                sourceApplicationName: applicationName,
                sourceBundleIdentifier: bundleIdentifier,
                targetGroupID: ClipboardGroup.voiceGroupID
            )
        )
        let storedItem = await stack.item(id: itemID)
        let item = try XCTUnwrap(storedItem)
        let source = await stack.clipboardItemRunAuthorizationSource(
            itemID: itemID,
            expectedItemVersion: item.version
        )
        return try XCTUnwrap(source)
    }

    private func makeGroupWorkflow(usesCloudText: Bool) -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Group Rewrite",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                postProcessSteps: [
                    PostProcessStep(
                        kind: usesCloudText ? .llmRewrite : .normalizeWhitespace
                    )
                ],
                outputActions: [OutputActionReference(id: "stack.push")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: [
                WorkflowMetadataKey.legacyEventType: "groupItemCreated",
                WorkflowMetadataKey.legacySourceGroupID:
                    ClipboardGroup.voiceGroupID.uuidString,
                WorkflowMetadataKey.legacyExcludePolishTag: "true",
                WorkflowMetadataKey.legacyGroupActionKind:
                    ClipboardGroupActionKind.editItem.rawValue,
            ]
        )
    }
}
