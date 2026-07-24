import XCTest
@testable import RillCore
@testable import RillRuntime

private actor ClipboardRunAuthorizationProbe {
    struct Snapshot: Equatable {
        var settingsReads = 0
        var privacyContextCaptures = 0
        var authorizedContextCaptures = 0
        var confirmationDestinations: [[PrivacyProcessingDestination]] = []
    }

    private var snapshot = Snapshot()

    func readSettings() -> PrivacyPolicySettings {
        snapshot.settingsReads += 1
        return PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: true
        )
    }

    func capturePrivacyContext(_ context: ContextSnapshot) -> ContextSnapshot {
        snapshot.privacyContextCaptures += 1
        return context
    }

    func captureAuthorizedContext(_ context: ContextSnapshot) -> ContextSnapshot {
        snapshot.authorizedContextCaptures += 1
        return context
    }

    func confirm(_ destinations: [PrivacyProcessingDestination]) -> Bool {
        snapshot.confirmationDestinations.append(destinations)
        return true
    }

    func current() -> Snapshot { snapshot }
}

private actor ClipboardCoordinatorExecutionProbe {
    struct Snapshot: Equatable {
        var transformations = 0
        var actions = 0
    }

    private var snapshot = Snapshot()

    func recordTransformation() { snapshot.transformations += 1 }
    func recordAction() { snapshot.actions += 1 }
    func current() -> Snapshot { snapshot }
}

private struct ClipboardCoordinatorContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct ClipboardCoordinatorTransformer: TextTransformer {
    let id = "clipboard.authorization.transformer"
    let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace]
    let probe: ClipboardCoordinatorExecutionProbe

    func transform(
        text: String,
        step: PostProcessStep,
        context: TransformContext
    ) async throws -> String {
        await probe.recordTransformation()
        return text
    }
}

private actor ClipboardCoordinatorTransformGate {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private struct SuspendedClipboardCoordinatorTransformer: TextTransformer {
    let id = "clipboard.authorization.transformer"
    let supportedKinds: [PostProcessStepKind] = [.normalizeWhitespace]
    let probe: ClipboardCoordinatorExecutionProbe
    let gate: ClipboardCoordinatorTransformGate

    func transform(
        text: String,
        step: PostProcessStep,
        context: TransformContext
    ) async throws -> String {
        await probe.recordTransformation()
        await gate.suspend()
        return text
    }
}

private struct ClipboardCoordinatorAction: OutputAction {
    let id = "clipboard.authorization.action"
    let probe: ClipboardCoordinatorExecutionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.recordAction()
        return .pushedToStack
    }
}

private struct ClipboardCoordinatorHarness {
    let coordinator: SessionCoordinator
    let deliveryStack: DeliveryStack
    let item: ClipboardHistoryItem
    let workflow: WorkflowDefinition
    let executionProbe: ClipboardCoordinatorExecutionProbe
    let receiptRepository: InMemoryWorkflowRunReceiptRepository
}

final class ClipboardItemRunAuthorizationTests: XCTestCase {
    func testInvocationIsNonserializableAndBindsContentFreeSubject() {
        let subject = makeClipboardRunSubject()
        let invocation = WorkflowRunInvocation.clipboardItem(
            subject: subject,
            operation: .replace
        )

        XCTAssertFalse(WorkflowRunInvocation.self is any Codable.Type)
        XCTAssertEqual(
            invocation,
            .clipboardItem(subject: subject, operation: .replace)
        )
    }

    func testClipboardDestinationClassificationSkipsRecognizerAndFailsClosedForUnknownComponents() {
        let invocation = WorkflowRunInvocation.clipboardItem(
            subject: makeClipboardRunSubject(),
            operation: .replay
        )
        let deepgramLocal = makeClipboardRunWorkflow(
            recognizerID: "deepgram.prerecorded",
            actionIDs: ["stack.push"]
        )
        let deepgramWebhook = makeClipboardRunWorkflow(
            recognizerID: "deepgram.prerecorded",
            actionIDs: [ExternalOutputActionID.webhookPost]
        )
        let localLLM = makeClipboardRunWorkflow(
            recognizerID: "sherpa-onnx.local",
            steps: [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")],
            actionIDs: ["stack.push"]
        )
        let unknown = makeClipboardRunWorkflow(
            recognizerID: "deepgram.prerecorded",
            actionIDs: ["unknown.destination"]
        )

        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.classify(
                deepgramLocal,
                invocation: invocation
            ),
            .classified([])
        )
        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.classify(deepgramLocal),
            .classified([.cloudSpeech])
        )
        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.classify(
                deepgramWebhook,
                invocation: invocation
            ),
            .classified([.cloudText])
        )
        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.classify(
                localLLM,
                invocation: invocation
            ),
            .classified([.cloudText])
        )
        XCTAssertEqual(
            WorkflowPrivacyDestinationClassifier.classify(unknown, invocation: invocation),
            .unavailable
        )
    }

    func testDeepgramClipboardReplayUsesNoRecognitionOptionsAndNoCloudConfirmation() async throws {
        let probe = ClipboardRunAuthorizationProbe()
        let context = makeClipboardRunContext()
        let gate = makeClipboardRunGate(probe: probe)
        let subject = makeClipboardRunSubject()
        let workflow = makeClipboardRunWorkflow(
            recognizerID: "deepgram.prerecorded",
            actionIDs: ["stack.push"]
        )

        let authorized = try await gate.captureAuthorizedClipboardItemRunContext(
            subject: subject,
            operation: .replay,
            privacyContextProvider: {
                await probe.capturePrivacyContext(context)
            },
            contextProvider: { _ in
                await probe.captureAuthorizedContext(context)
            },
            workflow: workflow
        )

        let snapshot = await probe.current()
        XCTAssertEqual(snapshot.confirmationDestinations, [])
        XCTAssertEqual(snapshot.privacyContextCaptures, 1)
        XCTAssertEqual(snapshot.authorizedContextCaptures, 1)
        XCTAssertEqual(authorized.recognitionOptions, .empty)
        XCTAssertEqual(
            authorized.invocation,
            .clipboardItem(subject: subject, operation: .replay)
        )
    }

    func testClipboardReplayConfirmsActualWebhookAndLanguageModelCloudTextDestinations() async throws {
        let workflows = [
            makeClipboardRunWorkflow(
                recognizerID: "deepgram.prerecorded",
                actionIDs: [ExternalOutputActionID.webhookPost]
            ),
            makeClipboardRunWorkflow(
                recognizerID: "sherpa-onnx.local",
                steps: [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")],
                actionIDs: ["stack.push"]
            ),
        ]

        for workflow in workflows {
            let probe = ClipboardRunAuthorizationProbe()
            let context = makeClipboardRunContext()
            let subject = makeClipboardRunSubject()
            let gate = makeClipboardRunGate(probe: probe)

            _ = try await gate.captureAuthorizedClipboardItemRunContext(
                subject: subject,
                operation: .replay,
                privacyContextProvider: {
                    await probe.capturePrivacyContext(context)
                },
                contextProvider: { _ in
                    await probe.captureAuthorizedContext(context)
                },
                workflow: workflow
            )

            let snapshot = await probe.current()
            XCTAssertEqual(snapshot.confirmationDestinations, [[.cloudText]])
        }
    }

    func testUnsupportedExcludedAndNontextSubjectsFailBeforePolicyOrContextCapture() async {
        let cases: [(
            subject: ClipboardItemDryRunSubject,
            operation: ClipboardItemDryRunOperation,
            expected: PrivacyRunGate.GateError
        )] = [
            (makeClipboardRunSubject(), .use, .clipboardItemOperationUnsupported),
            (
                makeClipboardRunSubject(contentKind: .image),
                .replay,
                .clipboardItemContentUnsupported
            ),
            (
                makeClipboardRunSubject(hasTransferableContent: false),
                .replay,
                .clipboardItemContentUnavailable
            ),
            (
                makeClipboardRunSubject(captureTags: [.excludeFromWorkflowCapture]),
                .replay,
                .clipboardItemExcludedFromWorkflowCapture
            ),
        ]

        for testCase in cases {
            let probe = ClipboardRunAuthorizationProbe()
            let context = makeClipboardRunContext()
            let gate = makeClipboardRunGate(probe: probe)
            do {
                _ = try await gate.captureAuthorizedClipboardItemRunContext(
                    subject: testCase.subject,
                    operation: testCase.operation,
                    privacyContextProvider: {
                        await probe.capturePrivacyContext(context)
                    },
                    contextProvider: { _ in
                        await probe.captureAuthorizedContext(context)
                    },
                    workflow: makeClipboardRunWorkflow()
                )
                XCTFail("Expected clipboard authorization to fail closed")
            } catch let error as PrivacyRunGate.GateError {
                XCTAssertEqual(error, testCase.expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let snapshot = await probe.current()
            XCTAssertEqual(snapshot, ClipboardRunAuthorizationProbe.Snapshot())
        }
    }

    func testReplaceAuthorizationRequiresExactlyOneClosedReplacementAction() async {
        let cases: [([String], PrivacyRunGate.GateError)] = [
            (["inject.text"], .clipboardItemSourceReplacementUnavailable),
            (
                ["clipboard.copy", "stack.push"],
                .clipboardItemSourceReplacementAmbiguous
            ),
        ]

        for (actionIDs, expectedError) in cases {
            let probe = ClipboardRunAuthorizationProbe()
            let context = makeClipboardRunContext()
            let gate = makeClipboardRunGate(probe: probe)
            do {
                _ = try await gate.captureAuthorizedClipboardItemRunContext(
                    subject: makeClipboardRunSubject(),
                    operation: .replace,
                    privacyContextProvider: {
                        await probe.capturePrivacyContext(context)
                    },
                    contextProvider: { _ in
                        await probe.captureAuthorizedContext(context)
                    },
                    workflow: makeClipboardRunWorkflow(actionIDs: actionIDs)
                )
                XCTFail("Invalid replacement cardinality must fail closed.")
            } catch let error as PrivacyRunGate.GateError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("Unexpected replacement-plan error: \(error)")
            }

            let snapshot = await probe.current()
            XCTAssertEqual(snapshot, ClipboardRunAuthorizationProbe.Snapshot())
        }


        let acceptedProbe = ClipboardRunAuthorizationProbe()
        let acceptedContext = makeClipboardRunContext()
        let subject = makeClipboardRunSubject()
        let authorized = try? await makeClipboardRunGate(probe: acceptedProbe)
            .captureAuthorizedClipboardItemRunContext(
                subject: subject,
                operation: .replace,
                privacyContextProvider: { acceptedContext },
                contextProvider: { _ in acceptedContext },
                workflow: makeClipboardRunWorkflow(actionIDs: ["stack.push"])
            )
        XCTAssertEqual(
            authorized?.invocation,
            .clipboardItem(subject: subject, operation: .replace)
        )
    }

    func testDryRunPrivacyPreviewAndLiveAuthorizationShareClipboardInvocationClassification() async throws {
        let subject = makeClipboardRunSubject()
        let operation = ClipboardItemDryRunOperation.replay
        let invocation = WorkflowRunInvocation.clipboardItem(
            subject: subject,
            operation: operation
        )
        let context = makeClipboardRunContext()
        let service = ClipboardItemDryRunService()

        let localProbe = ClipboardRunAuthorizationProbe()
        let localGate = makeClipboardRunGate(probe: localProbe)
        let localWorkflow = makeClipboardRunWorkflow(
            recognizerID: "deepgram.prerecorded",
            actionIDs: ["stack.push"]
        )
        let localEvaluation = await localGate.evaluate(
            context: context,
            workflow: localWorkflow,
            invocation: invocation
        )
        let localReceipt = service.preview(
            subject: subject,
            operation: operation,
            workflow: localWorkflow,
            privacyEvaluation: localEvaluation
        )
        _ = try await localGate.captureAuthorizedClipboardItemRunContext(
            subject: subject,
            operation: operation,
            privacyContextProvider: { context },
            contextProvider: { _ in context },
            workflow: localWorkflow
        )
        let localSnapshot = await localProbe.current()

        XCTAssertEqual(localEvaluation.status, .ready)
        XCTAssertEqual(localReceipt.status, .ready)
        XCTAssertFalse(localReceipt.processingDestinations.contains(.cloudService))
        XCTAssertFalse(localReceipt.processingDestinations.contains(.remoteEndpoint))
        XCTAssertEqual(localSnapshot.confirmationDestinations, [])

        let remoteProbe = ClipboardRunAuthorizationProbe()
        let remoteGate = makeClipboardRunGate(probe: remoteProbe)
        let remoteWorkflow = makeClipboardRunWorkflow(
            recognizerID: "deepgram.prerecorded",
            actionIDs: [ExternalOutputActionID.webhookPost],
            actionConfiguration: [
                ExternalOutputActionConfigurationKey.webhookURL: "https://example.invalid/hook",
            ]
        )
        let remoteEvaluation = await remoteGate.evaluate(
            context: context,
            workflow: remoteWorkflow,
            invocation: invocation
        )
        let remoteReceipt = service.preview(
            subject: subject,
            operation: operation,
            workflow: remoteWorkflow,
            privacyEvaluation: remoteEvaluation
        )
        _ = try await remoteGate.captureAuthorizedClipboardItemRunContext(
            subject: subject,
            operation: operation,
            privacyContextProvider: { context },
            contextProvider: { _ in context },
            workflow: remoteWorkflow
        )
        let remoteSnapshot = await remoteProbe.current()

        XCTAssertEqual(remoteEvaluation.status, .requiresConfirmation)
        XCTAssertEqual(remoteReceipt.status, .requiresConfirmation)
        XCTAssertTrue(remoteReceipt.processingDestinations.contains(.remoteEndpoint))
        XCTAssertFalse(remoteReceipt.processingDestinations.contains(.cloudService))
        XCTAssertEqual(remoteSnapshot.confirmationDestinations, [[.cloudText]])
    }

    func testCoordinatorBlocksCaptureTagDriftBeforeReplayTransformOrAction() async throws {
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1)
        )
        let subject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: harness.item.contentKind,
            captureTags: harness.item.captureTags,
            hasTransferableContent: harness.item.supportsDirectPaste
        )
        await harness.deliveryStack.updateItemText(
            harness.item.id,
            text: harness.item.text,
            captureTags: [.excludeFromWorkflowCapture]
        )

        await harness.coordinator.replayClipboardItem(
            itemID: harness.item.id,
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: harness.workflow,
                contextSnapshot: .empty,
                recognitionOptions: .empty,
                invocation: .clipboardItem(subject: subject, operation: .replay)
            )
        )

        try await assertClipboardReplayWasBlocked(
            harness,
            expectedSkipReason: .itemChanged
        )
    }

    func testCoordinatorBlocksSameKindTextDriftBeforeReplayTransformOrAction() async throws {
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1)
        )
        let subject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: harness.item.contentKind,
            captureTags: harness.item.captureTags,
            hasTransferableContent: harness.item.supportsDirectPaste
        )
        await harness.deliveryStack.updateItemText(
            harness.item.id,
            text: "changed after authorization",
            captureTags: harness.item.captureTags
        )

        await harness.coordinator.replayClipboardItem(
            itemID: harness.item.id,
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: harness.workflow,
                contextSnapshot: .empty,
                recognitionOptions: .empty,
                invocation: .clipboardItem(subject: subject, operation: .replay)
            )
        )

        try await assertClipboardReplayWasBlocked(
            harness,
            expectedSkipReason: .itemChanged
        )
    }

    func testCoordinatorBlocksContentKindDriftBeforeReplayTransformOrAction() async throws {
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(
                plainText: "",
                imagePNGData: Data([0x01, 0x02, 0x03]),
                changeCount: 1
            )
        )
        let staleTextSubject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: .text,
            captureTags: harness.item.captureTags,
            hasTransferableContent: true
        )

        await harness.coordinator.replayClipboardItem(
            itemID: harness.item.id,
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: harness.workflow,
                contextSnapshot: .empty,
                recognitionOptions: .empty,
                invocation: .clipboardItem(
                    subject: staleTextSubject,
                    operation: .replay
                )
            )
        )

        try await assertClipboardReplayWasBlocked(
            harness,
            expectedSkipReason: .itemChanged
        )
    }

    func testCoordinatorBlocksReplayReplaceOperationMismatchBeforeTransformOrAction() async throws {
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1)
        )
        let subject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: harness.item.contentKind,
            captureTags: harness.item.captureTags,
            hasTransferableContent: harness.item.supportsDirectPaste
        )

        await harness.coordinator.replayClipboardItem(
            itemID: harness.item.id,
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: harness.workflow,
                contextSnapshot: .empty,
                recognitionOptions: .empty,
                invocation: .clipboardItem(subject: subject, operation: .replay)
            ),
            replacingSourceItem: true
        )

        try await assertClipboardReplayWasBlocked(harness)
    }

    func testCoordinatorClassifiesPostTransformItemDriftWithoutRunningActions() async throws {
        let gate = ClipboardCoordinatorTransformGate()
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1),
            transformGate: gate
        )
        let subject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: harness.item.contentKind,
            captureTags: harness.item.captureTags,
            hasTransferableContent: harness.item.supportsDirectPaste
        )

        let run = Task {
            await harness.coordinator.replayClipboardItem(
                itemID: harness.item.id,
                authorizedContext: AuthorizedWorkflowRunContext(
                    workflow: harness.workflow,
                    contextSnapshot: .empty,
                    recognitionOptions: .empty,
                    invocation: .clipboardItem(
                        subject: subject,
                        operation: .replay
                    )
                )
            )
        }
        await gate.waitUntilStarted()
        await harness.deliveryStack.updateItemText(
            harness.item.id,
            text: "changed during transform",
            captureTags: harness.item.captureTags
        )
        await gate.resume()
        await run.value

        let execution = await harness.executionProbe.current()
        let receipts = try await harness.receiptRepository.receipts(matching: .all)
        let state = await harness.coordinator.currentState()
        XCTAssertEqual(execution.transformations, 1)
        XCTAssertEqual(execution.actions, 0)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(
            receipts.first?.termination,
            .skipped(reason: .itemChanged)
        )
        XCTAssertEqual(state, .idle)
    }

    func testCoordinatorConsumesCopiedClipboardAuthorizationExactlyOnce() async throws {
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1)
        )
        let subject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: harness.item.contentKind,
            captureTags: harness.item.captureTags,
            hasTransferableContent: harness.item.supportsDirectPaste
        )
        let authorized = AuthorizedWorkflowRunContext(
            workflow: harness.workflow,
            contextSnapshot: .empty,
            recognitionOptions: .empty,
            invocation: .clipboardItem(subject: subject, operation: .replay)
        )
        let copiedAuthorization = authorized

        await harness.coordinator.replayClipboardItem(
            itemID: harness.item.id,
            authorizedContext: authorized
        )
        await harness.coordinator.replayClipboardItem(
            itemID: harness.item.id,
            authorizedContext: copiedAuthorization
        )

        let execution = await harness.executionProbe.current()
        let receipts = try await harness.receiptRepository.receipts(matching: .all)
        let state = await harness.coordinator.currentState()
        XCTAssertEqual(execution.transformations, 1)
        XCTAssertEqual(execution.actions, 1)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(
            receipts.filter { $0.termination == .completed }.count,
            1
        )
        XCTAssertEqual(
            receipts.filter { $0.termination == .skipped(reason: .privacyBlocked) }.count,
            1
        )
        XCTAssertEqual(state, .idle)
    }

    func testCoordinatorOrdinaryRunRejectsClipboardInvocationAsPrivacyBlockedAttempt() async throws {
        let harness = try await makeClipboardCoordinatorHarness(
            snapshot: ClipboardSnapshot(plainText: "stored", changeCount: 1)
        )
        let runID = UUID()
        let subject = ClipboardItemDryRunSubject(
            itemID: harness.item.id,
            itemVersion: harness.item.version,
            groupID: harness.item.groupID,
            contentKind: harness.item.contentKind,
            captureTags: harness.item.captureTags,
            hasTransferableContent: harness.item.supportsDirectPaste
        )

        await harness.coordinator.run(
            runID: runID,
            authorizedContext: AuthorizedWorkflowRunContext(
                workflow: harness.workflow,
                contextSnapshot: .empty,
                recognitionOptions: .empty,
                invocation: .clipboardItem(subject: subject, operation: .replay)
            )
        )

        let execution = await harness.executionProbe.current()
        let receipts = try await harness.receiptRepository.receipts(
            matching: .init(runID: runID)
        )
        let state = await harness.coordinator.currentState()
        XCTAssertEqual(execution, ClipboardCoordinatorExecutionProbe.Snapshot())
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.termination, .skipped(reason: .privacyBlocked))
        XCTAssertEqual(receipts.first?.actionDetails, [])
        XCTAssertEqual(state, .idle)
    }

    private func assertClipboardReplayWasBlocked(
        _ harness: ClipboardCoordinatorHarness,
        expectedSkipReason: WorkflowRunSkipCode = .privacyBlocked
    ) async throws {
        let execution = await harness.executionProbe.current()
        let receipts = try await harness.receiptRepository.receipts(matching: .all)
        let state = await harness.coordinator.currentState()
        XCTAssertEqual(execution, ClipboardCoordinatorExecutionProbe.Snapshot())
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(
            receipts.first?.termination,
            .skipped(reason: expectedSkipReason)
        )
        XCTAssertEqual(receipts.first?.actionDetails, [])
        XCTAssertEqual(state, .idle)
    }
}

private func makeClipboardRunGate(
    probe: ClipboardRunAuthorizationProbe
) -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: { await probe.readSettings() },
        cloudConfirmationProvider: { _, _, destinations in
            await probe.confirm(destinations)
        }
    )
}

private func makeClipboardRunSubject(
    contentKind: ClipboardContentKind = .text,
    captureTags: [ClipboardCaptureTag] = [],
    hasTransferableContent: Bool = true
) -> ClipboardItemDryRunSubject {
    ClipboardItemDryRunSubject(
        itemID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        itemVersion: ClipboardItemVersion(
            generationID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            revision: 1
        ),
        groupID: ClipboardGroup.defaultGroupID,
        contentKind: contentKind,
        captureTags: captureTags,
        hasTransferableContent: hasTransferableContent
    )
}

private func makeClipboardRunContext() -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 42,
            focusedRole: "AXTextArea",
            selectedText: "selected",
            secureInput: false
        ),
        clipboard: ClipboardSnapshot(plainText: "clipboard", changeCount: 7)
    )
}

private func makeClipboardRunWorkflow(
    recognizerID: String = "sherpa-onnx.local",
    steps: [PostProcessStep] = [],
    actionIDs: [String] = ["stack.push"],
    actionConfiguration: [String: String] = [:]
) -> WorkflowDefinition {
    WorkflowDefinition(
        name: "Clipboard run",
        pipeline: PipelineDeclaration(
            recognizerID: recognizerID,
            postProcessSteps: steps,
            outputActions: actionIDs.map {
                OutputActionReference(id: $0, configuration: actionConfiguration)
            }
        ),
        ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "blue")
    )
}

private func makeClipboardCoordinatorHarness(
    snapshot: ClipboardSnapshot,
    transformGate: ClipboardCoordinatorTransformGate? = nil
) async throws -> ClipboardCoordinatorHarness {
    let eventBus = EventBus()
    let deliveryStack = DeliveryStack(eventBus: eventBus)
    await deliveryStack.captureSystemClipboard(
        snapshot: snapshot,
        context: ClipboardRouteContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        ),
        disposition: .historyAndWorkflows
    )
    let clipboardSnapshot = await deliveryStack.clipboardSnapshot()
    let item = try XCTUnwrap(clipboardSnapshot.items.first)
    let executionProbe = ClipboardCoordinatorExecutionProbe()
    let receiptRepository = InMemoryWorkflowRunReceiptRepository()
    let receiptRecorder = WorkflowRunReceiptRecorder(
        repository: receiptRepository,
        eventBus: eventBus
    )
    let workflow = makeClipboardRunWorkflow(
        recognizerID: "missing.replay.recognizer",
        steps: [PostProcessStep(kind: .normalizeWhitespace)],
        actionIDs: ["clipboard.authorization.action"]
    )
    let transformer: any TextTransformer = if let transformGate {
        SuspendedClipboardCoordinatorTransformer(
            probe: executionProbe,
            gate: transformGate
        )
    } else {
        ClipboardCoordinatorTransformer(probe: executionProbe)
    }
    let coordinator = SessionCoordinator(
        contextProvider: ClipboardCoordinatorContextProvider(),
        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(
            transformers: [transformer]
        ),
        actionRegistry: OutputActionRegistry(
            actions: [ClipboardCoordinatorAction(probe: executionProbe)]
        ),
        candidateResolver: CandidateResolver(eventBus: eventBus),
        deliveryStack: deliveryStack,
        eventBus: eventBus,
        runReceiptRecorder: receiptRecorder
    )
    return ClipboardCoordinatorHarness(
        coordinator: coordinator,
        deliveryStack: deliveryStack,
        item: item,
        workflow: workflow,
        executionProbe: executionProbe,
        receiptRepository: receiptRepository
    )
}
