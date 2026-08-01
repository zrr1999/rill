import XCTest
@testable import RillCore
@testable import RillRuntime

private actor ConfirmationProbe {
    private var callCount = 0

    func record() {
        callCount += 1
    }

    func snapshot() -> Int {
        callCount
    }
}

private actor FullContextProbe {
    private var callCount = 0

    func capture(_ context: ContextSnapshot) -> ContextSnapshot {
        callCount += 1
        return context
    }

    func snapshot() -> Int {
        callCount
    }
}

private actor ConfirmationDestinationProbe {
    private var calls: [[PrivacyProcessingDestination]] = []

    func record(_ destinations: [PrivacyProcessingDestination]) {
        calls.append(destinations)
    }

    func snapshot() -> [[PrivacyProcessingDestination]] {
        calls
    }
}

private actor PrivacySettingsSequence {
    enum Step: Sendable {
        case settings(PrivacyPolicySettings)
        case failure
    }

    private var steps: [Step]
    private var readCount = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func next() throws -> PrivacyPolicySettings {
        readCount += 1
        guard !steps.isEmpty else { throw SequenceError.exhausted }
        switch steps.removeFirst() {
        case .settings(let settings):
            return settings
        case .failure:
            throw SequenceError.unavailable
        }
    }

    func count() -> Int { readCount }

    private enum SequenceError: Error {
        case exhausted
        case unavailable
    }
}

private actor MutablePrivacySettingsStore {
    private var settings: PrivacyPolicySettings
    private var readCount = 0

    init(_ settings: PrivacyPolicySettings) {
        self.settings = settings
    }

    func read() -> PrivacyPolicySettings {
        readCount += 1
        return settings
    }

    func replace(with settings: PrivacyPolicySettings) {
        self.settings = settings
    }

    func count() -> Int { readCount }
}

private actor PrivacyContextSequence {
    private var contexts: [ContextSnapshot]

    init(_ contexts: [ContextSnapshot]) {
        self.contexts = contexts
    }

    func next() -> ContextSnapshot {
        precondition(!contexts.isEmpty)
        return contexts.removeFirst()
    }
}

final class PrivacyRunGateTests: XCTestCase {
    func testSensitiveCloudBlockDoesNotReadFullContext() async {
        let fullContextProbe = FullContextProbe()
        let minimalContext = makeRunContext(bundleIdentifier: "com.example.vault")
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [
                        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
                    ]
                )
            },
            cloudConfirmationProvider: { _, _, _ in true }
        )

        do {
            _ = try await gate.captureAuthorizedContext(
                privacyContextProvider: { minimalContext },
                contextProvider: { _ in
                    await fullContextProbe.capture(minimalContext)
                },
                workflow: makeRunWorkflow(recognizerID: "remote.speech")
            )
            XCTFail("Expected sensitive cloud processing to be blocked.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let fullContextCallCount = await fullContextProbe.snapshot()
        XCTAssertEqual(fullContextCallCount, 0)
    }

    func testSensitiveApplicationBlocksCloudBeforeConfirmation() async {
        let confirmation = ConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [
                        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
                    ]
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )

        let preview = await gate.evaluate(
            context: makeRunContext(bundleIdentifier: "com.example.vault"),
            workflow: makeRunWorkflow(recognizerID: "remote.speech")
        )
        XCTAssertEqual(preview.status, .blocked)
        XCTAssertTrue(preview.reasons.contains(.sensitiveApplication))
        XCTAssertTrue(preview.reasons.contains(.cloudProcessingBlocked))
        XCTAssertTrue(preview.reasons.contains(.cloudProviderSelected))
        XCTAssertFalse(preview.reasons.contains(.cloudConfirmationRequired))
        var confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)

        do {
            _ = try await gate.authorize(
                context: makeRunContext(bundleIdentifier: "com.example.vault"),
                workflow: makeRunWorkflow(recognizerID: "remote.speech")
            )
            XCTFail("Expected sensitive cloud processing to be blocked.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testCloudRunRequiresApprovalAndUsesRedactedContext() async throws {
        let confirmation = ConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: true)
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )
        var context = makeRunContext(bundleIdentifier: "com.apple.Notes")
        context.focus.secureInput = true
        context.focus.selectedText = "secret selection"

        let preview = await gate.evaluate(
            context: context,
            workflow: makeRunWorkflow(recognizerID: "remote.speech")
        )
        XCTAssertEqual(preview.status, .requiresConfirmation)
        XCTAssertTrue(preview.reasons.contains(.cloudConfirmationRequired))
        XCTAssertEqual(preview.redactedInputCategories, [.focusedSelection, .clipboardText])
        var confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)

        let authorized = try await gate.authorize(
            context: context,
            workflow: makeRunWorkflow(recognizerID: "remote.speech")
        )

        confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 1)
        XCTAssertEqual(authorized.context.focus.selectedText, "")
        XCTAssertEqual(authorized.context.clipboard.plainText, "")
        XCTAssertTrue(authorized.decision.requiresCloudConfirmation)
    }

    func testContextIdentityRetryReusesConfirmationForSameSourceAndPolicy() async throws {
        let confirmation = ConfirmationProbe()
        let sourceContext = makeRunContext(bundleIdentifier: "com.apple.Notes")
        let mismatchedContext = makeRunContext(bundleIdentifier: "com.apple.TextEdit")
        let privacyContexts = PrivacyContextSequence([sourceContext, sourceContext])
        let fullContexts = PrivacyContextSequence([mismatchedContext, sourceContext])
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

        _ = try await gate.captureAuthorizedContext(
            privacyContextProvider: { await privacyContexts.next() },
            contextProvider: { _ in await fullContexts.next() },
            workflow: makeRunWorkflow(recognizerID: "remote.speech")
        )

        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 1)
    }

    func testContextIdentityRetryDoesNotReuseConfirmationForChangedSource() async throws {
        let confirmation = ConfirmationProbe()
        let firstSource = makeRunContext(bundleIdentifier: "com.apple.Notes")
        let secondSource = makeRunContext(bundleIdentifier: "com.apple.TextEdit")
        let privacyContexts = PrivacyContextSequence([firstSource, secondSource])
        let fullContexts = PrivacyContextSequence([secondSource, secondSource])
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

        _ = try await gate.captureAuthorizedContext(
            privacyContextProvider: { await privacyContexts.next() },
            contextProvider: { _ in await fullContexts.next() },
            workflow: makeRunWorkflow(recognizerID: "remote.speech")
        )

        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 2)
    }

    func testContextIdentityRetryBlocksChangedPolicyWithoutReusingConfirmation() async {
        let confirmation = ConfirmationProbe()
        let sourceContext = makeRunContext(bundleIdentifier: "com.apple.Notes")
        let mismatchedContext = makeRunContext(bundleIdentifier: "com.apple.TextEdit")
        let privacyContexts = PrivacyContextSequence([sourceContext, sourceContext])
        let fullContexts = PrivacyContextSequence([mismatchedContext])
        let allowedSettings = PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: true
        )
        let settings = PrivacySettingsSequence([
            .settings(allowedSettings),
            .settings(allowedSettings),
            .settings(PrivacyPolicySettings(
                sensitiveAppRules: [
                    SensitiveAppRule(bundleIdentifier: "com.apple.Notes"),
                ],
                cloudConfirmationRequired: true
            )),
        ])
        let gate = PrivacyRunGate(
            settingsProvider: { try await settings.next() },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )

        do {
            _ = try await gate.captureAuthorizedContext(
                privacyContextProvider: { await privacyContexts.next() },
                contextProvider: { _ in await fullContexts.next() },
                workflow: makeRunWorkflow(recognizerID: "remote.speech")
            )
            XCTFail("A newly blocking retry policy must fail closed.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 1)
    }

    func testDeclinedCloudRunFailsBeforeProviderExecution() async {
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: true)
            },
            cloudConfirmationProvider: { _, _, _ in false }
        )

        do {
            _ = try await gate.authorize(
                context: makeRunContext(),
                workflow: makeRunWorkflow(recognizerID: "remote.speech")
            )
            XCTFail("Expected cloud confirmation to be declined.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudConfirmationDeclined)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLocalRunDoesNotRequestCloudConfirmation() async throws {
        let confirmation = ConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: true)
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return false
            }
        )

        let preview = await gate.evaluate(
            context: makeRunContext(),
            workflow: makeRunWorkflow(recognizerID: "sherpa-onnx.local")
        )
        XCTAssertEqual(preview.status, .ready)
        XCTAssertTrue(preview.reasons.isEmpty)
        var confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)

        _ = try await gate.authorize(
            context: makeRunContext(),
            workflow: makeRunWorkflow(recognizerID: "sherpa-onnx.local")
        )

        confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testSettingsFailureFailsClosed() async {
        struct SettingsFailure: Error {}
        let gate = PrivacyRunGate(
            settingsProvider: { throw SettingsFailure() },
            cloudConfirmationProvider: { _, _, _ in true }
        )

        let preview = await gate.evaluate(
            context: makeRunContext(),
            workflow: makeRunWorkflow(recognizerID: "sherpa-onnx.local")
        )
        XCTAssertEqual(
            preview,
            PrivacyRunEvaluation(
                status: .blocked,
                reasons: [.privacySettingsUnavailable]
            )
        )

        do {
            _ = try await gate.authorize(
                context: makeRunContext(),
                workflow: makeRunWorkflow(recognizerID: "sherpa-onnx.local")
            )
            XCTFail("Expected unavailable privacy settings to block the run.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .settingsUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExcludedClipboardIsRedactedInPreviewAndAuthorization() async throws {
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: false
                )
            },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("Local privacy evaluation must not request confirmation.")
                return false
            }
        )
        var context = makeRunContext()
        context.clipboard.captureTags = [.excludeFromWorkflowCapture]

        let preview = await gate.evaluate(
            context: context,
            workflow: makeRunWorkflow(recognizerID: "context.selection")
        )
        let authorized = try await gate.authorize(
            context: context,
            workflow: makeRunWorkflow(recognizerID: "context.selection")
        )

        XCTAssertEqual(preview.status, .ready)
        XCTAssertEqual(preview.redactedInputCategories, [.clipboardText])
        XCTAssertTrue(preview.reasons.contains(.itemTaggedExcludeFromWorkflowCapture))
        XCTAssertEqual(authorized.context.clipboard.plainText, "")
        XCTAssertEqual(authorized.decision.redactedPromptVariables, [.clipboard])
    }

    func testUnknownFocusBlocksCloudInPreviewAndAuthorization() async {
        let confirmation = ConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: true)
            },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )
        var context = makeRunContext()
        context.focus.applicationName = nil
        context.focus.bundleIdentifier = nil
        let workflow = makeRunWorkflow(recognizerID: "remote.speech")

        let preview = await gate.evaluate(context: context, workflow: workflow)
        XCTAssertEqual(preview.status, .blocked)
        XCTAssertTrue(preview.reasons.contains(.unknownFocusContext))
        XCTAssertTrue(preview.reasons.contains(.cloudProcessingBlocked))

        do {
            _ = try await gate.authorize(context: context, workflow: workflow)
            XCTFail("Unknown focus must block cloud processing.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testRemoteTextDestinationUsesSharedClassifierForPreviewAndAuthorization() async throws {
        let confirmation = ConfirmationDestinationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(sensitiveAppRules: [], cloudConfirmationRequired: true)
            },
            cloudConfirmationProvider: { _, _, destinations in
                await confirmation.record(destinations)
                return true
            }
        )
        let workflow = makeRunWorkflow(
            recognizerID: "sherpa-onnx.local",
            actionIDs: [ExternalOutputActionID.webhookPost]
        )

        let preview = await gate.evaluate(context: makeRunContext(), workflow: workflow)
        XCTAssertEqual(preview.status, .requiresConfirmation)
        var confirmationCalls = await confirmation.snapshot()
        XCTAssertEqual(confirmationCalls, [])

        _ = try await gate.authorize(context: makeRunContext(), workflow: workflow)
        confirmationCalls = await confirmation.snapshot()
        XCTAssertEqual(confirmationCalls, [[.localSpeech, .cloudText]])
    }

    func testUnknownDestinationFailsClosedWithoutConfirmation() async {
        let confirmation = ConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: { PrivacyPolicySettings(sensitiveAppRules: []) },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )
        let workflow = makeRunWorkflow(
            recognizerID: "sherpa-onnx.local",
            actionIDs: ["unknown.CANARY-ACTION"]
        )

        let preview = await gate.evaluate(context: makeRunContext(), workflow: workflow)
        XCTAssertEqual(
            preview,
            PrivacyRunEvaluation(
                status: .blocked,
                reasons: [.processingDestinationUnavailable]
            )
        )
        do {
            _ = try await gate.authorize(context: makeRunContext(), workflow: workflow)
            XCTFail("Unclassified destinations must fail closed.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .processingDestinationUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testPreviewSerializationCannotContainContextOrErrorCanaries() async throws {
        struct CanarySettingsFailure: Error, LocalizedError {
            var errorDescription: String? { "CANARY-SETTINGS-ERROR" }
        }
        let gate = PrivacyRunGate(
            settingsProvider: { throw CanarySettingsFailure() },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("Preview must not request confirmation.")
                return true
            }
        )
        var context = makeRunContext(bundleIdentifier: "com.CANARY.secret")
        context.focus.applicationName = "CANARY-APP"
        context.focus.selectedText = "CANARY-SELECTION"
        context.clipboard.plainText = "CANARY-CLIPBOARD"

        let preview = await gate.evaluate(
            context: context,
            workflow: makeRunWorkflow(recognizerID: "sherpa-onnx.local")
        )
        let json = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)

        XCTAssertEqual(preview.reasons, [.privacySettingsUnavailable])
        XCTAssertFalse(json.contains("CANARY"))
        XCTAssertFalse(json.contains("com."))
        XCTAssertFalse(json.contains("selectedText"))
        XCTAssertFalse(json.contains("clipboard"))
    }

    func testLocalAuthorizationFailsWhenPolicyChangesBeforeReturn() async {
        let sequence = PrivacySettingsSequence([
            .settings(PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )),
            .settings(PrivacyPolicySettings(
                sensitiveAppRules: [
                    SensitiveAppRule(bundleIdentifier: "com.apple.Notes"),
                ],
                cloudConfirmationRequired: false
            )),
        ])
        let gate = PrivacyRunGate(
            settingsProvider: { try await sequence.next() },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("Local authorization must not request confirmation.")
                return true
            }
        )

        do {
            _ = try await gate.authorize(
                context: makeRunContext(),
                workflow: makeRunWorkflow(recognizerID: "context.selection")
            )
            XCTFail("A changed privacy policy must invalidate authorization.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .policyChangedDuringAuthorization)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let readCount = await sequence.count()
        XCTAssertEqual(readCount, 2)
    }

    func testConfirmedCloudAuthorizationFailsWhenPolicyBecomesBlocking() async {
        let confirmation = ConfirmationProbe()
        let sequence = PrivacySettingsSequence([
            .settings(PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: true
            )),
            .settings(PrivacyPolicySettings(
                sensitiveAppRules: [
                    SensitiveAppRule(bundleIdentifier: "com.apple.Notes"),
                ],
                cloudConfirmationRequired: true
            )),
        ])
        let gate = PrivacyRunGate(
            settingsProvider: { try await sequence.next() },
            cloudConfirmationProvider: { _, _, _ in
                await confirmation.record()
                return true
            }
        )

        do {
            _ = try await gate.authorize(
                context: makeRunContext(),
                workflow: makeRunWorkflow(recognizerID: "remote.speech")
            )
            XCTFail("A stricter post-confirmation policy must invalidate authorization.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .policyChangedDuringAuthorization)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let confirmationCount = await confirmation.snapshot()
        let readCount = await sequence.count()
        XCTAssertEqual(confirmationCount, 1)
        XCTAssertEqual(readCount, 2)
    }

    func testSecondSettingsReadFailureFailsClosed() async {
        let sequence = PrivacySettingsSequence([
            .settings(PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )),
            .failure,
        ])
        let gate = PrivacyRunGate(
            settingsProvider: { try await sequence.next() },
            cloudConfirmationProvider: { _, _, _ in true }
        )

        do {
            _ = try await gate.authorize(
                context: makeRunContext(),
                workflow: makeRunWorkflow(recognizerID: "sherpa-onnx.local")
            )
            XCTFail("A failed final settings read must block authorization.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .settingsUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let readCount = await sequence.count()
        XCTAssertEqual(readCount, 2)
    }

    func testFullContextCaptureCannotCommitAuthorizationAfterPolicyChanges() async {
        let context = makeRunContext()
        let store = MutablePrivacySettingsStore(
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        )
        let gate = PrivacyRunGate(
            settingsProvider: { await store.read() },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("Local authorization must not request confirmation.")
                return true
            }
        )

        do {
            _ = try await gate.captureAuthorizedContext(
                privacyContextProvider: { context },
                contextProvider: { _ in
                    await store.replace(with: PrivacyPolicySettings(
                        sensitiveAppRules: [
                            SensitiveAppRule(bundleIdentifier: "com.apple.Notes"),
                        ],
                        cloudConfirmationRequired: false
                    ))
                    return context
                },
                workflow: makeRunWorkflow(recognizerID: "context.selection")
            )
            XCTFail("A policy change during full context capture must fail closed.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .policyChangedDuringAuthorization)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let readCount = await store.count()
        XCTAssertEqual(readCount, 3)
    }
}

private func makeRunContext(bundleIdentifier: String = "com.apple.Notes") -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Test App",
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            focusedRole: nil,
            selectedText: "selected",
            secureInput: false
        ),
        clipboard: ClipboardSnapshot(plainText: "clipboard", changeCount: 1)
    )
}

private func makeRunWorkflow(
    recognizerID: String,
    actionIDs: [String] = []
) -> WorkflowDefinition {
    let usesCloudTextFixture = recognizerID == "remote.speech"
    return WorkflowDefinition(
        name: "Privacy Run",
        pipeline: PipelineDeclaration(
            recognizerID: usesCloudTextFixture ? "sherpa-onnx.local" : recognizerID,
            postProcessSteps: usesCloudTextFixture
                ? [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")]
                : [],
            outputActions: actionIDs.map { OutputActionReference(id: $0) }
        ),
        ui: WorkflowUIConfig(symbolName: "lock", accentColorName: "blue")
    )
}
