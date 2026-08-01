import XCTest
@testable import RillCore

final class PrivacyModelsTests: XCTestCase {
    func testCloudProcessingAuthorizationIsScopedToWorkflowAndProviderConfiguration() throws {
        let workflow = WorkflowDefinition(
            id: UUID(uuidString: "D74E1D72-32B2-4499-8A4F-A9F967A1BEE8")!,
            name: "Voice Assistant",
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                postProcessSteps: [PostProcessStep(kind: .llmRewrite)],
                outputActions: [OutputActionReference(id: "speech.speak")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "teal")
        )
        let authorization = try CloudProcessingAuthorization(
            workflow: workflow,
            processingDestinations: [.localSpeech, .cloudText],
            providerIdentities: ["openai.responses|https://api.openai.com/v1|gpt-5-mini"]
        )

        XCTAssertTrue(
            authorization.authorizes(
                workflow: workflow,
                processingDestinations: [.cloudText, .localSpeech],
                providerIdentities: ["openai.responses|https://api.openai.com/v1|gpt-5-mini"]
            )
        )
        XCTAssertFalse(
            authorization.authorizes(
                workflow: workflow,
                processingDestinations: [.cloudText, .localSpeech],
                providerIdentities: ["openai.responses|https://api.openai.com/v1|gpt-5.4"]
            )
        )

        var changedWorkflow = workflow
        changedWorkflow.plan.process.steps.append(
            WorkflowProcessStep(kind: .normalizeWhitespace)
        )
        XCTAssertFalse(
            authorization.authorizes(
                workflow: changedWorkflow,
                processingDestinations: [.localSpeech, .cloudText],
                providerIdentities: ["openai.responses|https://api.openai.com/v1|gpt-5-mini"]
            )
        )
    }

    func testLegacyPrivacyPolicySettingsDecodeWithoutCloudAuthorizations() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "sensitiveAppRules": [],
            "cloudConfirmationRequired": true,
            "historyPreviewMode": "restricted",
            "secureInputConservativeMode": true,
        ])

        let settings = try JSONDecoder().decode(PrivacyPolicySettings.self, from: legacy)

        XCTAssertTrue(settings.cloudProcessingAuthorizations.isEmpty)
    }

    func testPrivacySettingsSourceFailsClosedUntilSettingsAreAvailable() throws {
        let source = PrivacyPolicySettingsSource()

        XCTAssertFalse(source.hasAvailableSettings)
        XCTAssertThrowsError(try source.currentSettings()) { error in
            XCTAssertEqual(error as? PrivacyPolicySettingsSourceError, .notReady)
        }

        var settings = PrivacyPolicySettings.defaults
        settings.cloudConfirmationRequired = false
        source.update(settings)
        XCTAssertTrue(source.hasAvailableSettings)
        XCTAssertEqual(try source.currentSettings(), settings)

        source.markUnavailable(reason: "corrupt snapshot")
        XCTAssertFalse(source.hasAvailableSettings)
        XCTAssertThrowsError(try source.currentSettings()) { error in
            XCTAssertEqual(
                error as? PrivacyPolicySettingsSourceError,
                .unavailable("corrupt snapshot")
            )
        }
    }

    func testSensitiveAppRuleValidationTrimsOptionalNameAndRequiresBundleIdentifier() throws {
        let rule = try SensitiveAppRule(
            bundleIdentifier: "  com.example.Vault  ",
            applicationName: "   "
        ).normalizedAndValidated()

        XCTAssertEqual(rule.bundleIdentifier, "com.example.Vault")
        XCTAssertNil(rule.applicationName)
        XCTAssertThrowsError(
            try SensitiveAppRule(bundleIdentifier: "Vault").normalizedAndValidated()
        ) { error in
            XCTAssertEqual(error as? SensitiveAppRuleValidationError, .invalidBundleIdentifier)
        }
        XCTAssertThrowsError(
            try SensitiveAppRule(bundleIdentifier: "com.example.保险库").normalizedAndValidated()
        ) { error in
            XCTAssertEqual(error as? SensitiveAppRuleValidationError, .invalidBundleIdentifier)
        }
        XCTAssertThrowsError(
            try SensitiveAppRule(bundleIdentifier: "  ").normalizedAndValidated()
        ) { error in
            XCTAssertEqual(error as? SensitiveAppRuleValidationError, .missingBundleIdentifier)
        }
    }

    func testMergingRecommendedRulesPreservesOverridesAndAddsCustomRules() throws {
        var disabledRecommended = try XCTUnwrap(SensitiveAppRule.recommendedDefaults.first)
        disabledRecommended.enabled = false
        disabledRecommended.blocksCloudProcessing = false
        let custom = SensitiveAppRule(
            bundleIdentifier: "com.example.bank",
            applicationName: "Example Bank"
        )

        let merged = try SensitiveAppRule.mergingRecommendedDefaults(
            with: [disabledRecommended, custom]
        )

        XCTAssertEqual(
            Array(merged.prefix(SensitiveAppRule.recommendedDefaults.count)).map(\.id),
            SensitiveAppRule.recommendedDefaults.map(\.id)
        )
        XCTAssertEqual(merged.first?.enabled, false)
        XCTAssertEqual(merged.first?.blocksCloudProcessing, false)
        XCTAssertEqual(merged.last?.bundleIdentifier, "com.example.bank")
    }

    func testMergingSensitiveAppRulesRejectsCaseInsensitiveBundleDuplicates() {
        XCTAssertThrowsError(
            try SensitiveAppRule.mergingRecommendedDefaults(with: [
                SensitiveAppRule(bundleIdentifier: "com.example.Vault"),
                SensitiveAppRule(bundleIdentifier: "COM.EXAMPLE.VAULT"),
            ])
        ) { error in
            XCTAssertEqual(error as? SensitiveAppRuleValidationError, .duplicateBundleIdentifier)
        }
    }

    func testRestoringRecommendedRulesKeepsCustomRules() throws {
        var changedRecommended = try XCTUnwrap(SensitiveAppRule.recommendedDefaults.first)
        changedRecommended.enabled = false
        let custom = SensitiveAppRule(bundleIdentifier: "com.example.private")

        let restored = try SensitiveAppRule.restoringRecommendedDefaults(
            whileKeepingCustomRules: [changedRecommended, custom]
        )

        XCTAssertEqual(restored.first, SensitiveAppRule.recommendedDefaults.first)
        XCTAssertTrue(restored.contains { $0.bundleIdentifier == "com.example.private" })
    }

    func testSensitiveAppRuleRedactsSelectedAndClipboardContext() {
        let context = makeContext(
            applicationName: "Vault",
            bundleIdentifier: "com.example.vault",
            selectedText: "selected secret",
            clipboardText: "clipboard secret"
        )
        let settings = PrivacyPolicySettings(
            sensitiveAppRules: [
                SensitiveAppRule(
                    bundleIdentifier: "com.example.vault",
                    applicationName: "Vault"
                )
            ],
            cloudConfirmationRequired: false
        )

        let decision = PrivacyPolicy.evaluate(context: context, settings: settings)

        XCTAssertTrue(decision.decisions.contains(.redactContext))
        XCTAssertTrue(decision.decisions.contains(.skipClipboardCapture))
        XCTAssertTrue(decision.decisions.contains(.skipWorkflowCapture))
        XCTAssertTrue(decision.reasons.contains(.sensitiveApplication))
        XCTAssertEqual(decision.redactedContext?.focus.selectedText, "")
        XCTAssertEqual(decision.redactedContext?.clipboard.plainText, "")
        XCTAssertTrue(decision.redactedPromptVariables.contains(.selected))
        XCTAssertTrue(decision.redactedPromptVariables.contains(.clipboard))
        XCTAssertFalse(decision.metadata.values.contains { $0.contains("secret") })
    }

    func testPromptRenderingUsesPrivacyDecisionRedactions() throws {
        let context = PromptVariableContext(
            text: "dictation",
            selectedText: "selected secret",
            clipboardText: "clipboard secret",
            applicationName: "Vault",
            bundleIdentifier: "com.example.vault"
        )
        let decision = PrivacyPolicyDecision(
            decisions: [.redactContext],
            reasons: [.sensitiveApplication],
            redactedPromptVariables: [.selected, .clipboard]
        )

        let result = try PromptVariableRenderer.render(
            prompt: "{text}; selected={selected}; clipboard={clipboard}; app={app}",
            context: context,
            privacyDecision: decision
        )

        XCTAssertEqual(result.renderedPrompt, "dictation; selected=; clipboard=; app=Vault")
        XCTAssertEqual(result.redactedVariables, [.selected, .clipboard])
        XCTAssertEqual(result.missingVariables, [.selected, .clipboard])
    }

    func testUnclassifiedRemoteRecognizerRequiresConfirmation() {
        let decision = PrivacyPolicy.evaluate(
            context: makeContext(),
            workflow: makeWorkflow(recognizerID: "remote.speech"),
            settings: PrivacyPolicySettings(sensitiveAppRules: [])
        )

        XCTAssertTrue(decision.requiresCloudConfirmation)
        XCTAssertTrue(decision.reasons.contains(.cloudProviderSelected))
        XCTAssertFalse(decision.blocksCloudProcessing)
    }

    func testSensitiveCloudRuleBlocksCloudProcessing() {
        let context = makeContext(
            applicationName: "Vault",
            bundleIdentifier: "com.example.vault"
        )
        let settings = PrivacyPolicySettings(
            sensitiveAppRules: [
                SensitiveAppRule(
                    bundleIdentifier: "com.example.vault",
                    applicationName: "Vault"
                )
            ]
        )

        let decision = PrivacyPolicy.evaluate(
            context: context,
            processingDestinations: [.cloudText],
            settings: settings
        )

        XCTAssertTrue(decision.requiresCloudConfirmation)
        XCTAssertTrue(decision.blocksCloudProcessing)
        XCTAssertTrue(decision.decisions.contains(.blockCloudProcessing))
    }

    func testExcludeFromWorkflowCaptureTagSkipsWorkflowOnly() {
        let decision = PrivacyPolicy.evaluate(
            context: makeContext(captureTags: [.excludeFromWorkflowCapture]),
            settings: PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        )

        XCTAssertTrue(decision.decisions.contains(.skipWorkflowCapture))
        XCTAssertTrue(decision.reasons.contains(.itemTaggedExcludeFromWorkflowCapture))
        XCTAssertTrue(decision.allowsClipboardCapture)
        XCTAssertEqual(decision.redactedPromptVariables, [.clipboard])
        XCTAssertEqual(decision.redactedContext?.clipboard.plainText, "")
    }

    func testUnknownFocusBlocksCloudButRemainsAdvisoryForLocalProcessing() {
        let context = makeContext(applicationName: nil, bundleIdentifier: nil)
        let settings = PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: true
        )

        let cloud = PrivacyPolicy.evaluate(
            context: context,
            workflow: makeWorkflow(recognizerID: "remote.speech"),
            settings: settings
        )
        let local = PrivacyPolicy.evaluate(
            context: context,
            workflow: makeWorkflow(recognizerID: "sherpa-onnx.local"),
            settings: settings
        )

        XCTAssertTrue(cloud.blocksCloudProcessing)
        XCTAssertTrue(cloud.reasons.contains(.unknownFocusContext))
        XCTAssertFalse(local.blocksCloudProcessing)
        XCTAssertTrue(local.reasons.contains(.unknownFocusContext))
        XCTAssertFalse(local.allowsClipboardCapture)
        XCTAssertFalse(local.allowsWorkflowCapture)
        XCTAssertEqual(local.redactedPromptVariables, [.selected, .clipboard])
        XCTAssertEqual(local.redactedContext?.focus.selectedText, "")
        XCTAssertEqual(local.redactedContext?.clipboard.plainText, "")
    }

    func testSensitiveRuleWithoutRedactionFlagsDoesNotClaimContextRedaction() {
        let decision = PrivacyPolicy.evaluate(
            context: makeContext(
                applicationName: "Vault",
                bundleIdentifier: "com.example.vault"
            ),
            settings: PrivacyPolicySettings(
                sensitiveAppRules: [
                    SensitiveAppRule(
                        bundleIdentifier: "com.example.vault",
                        blocksClipboardHistory: false,
                        blocksWorkflowCapture: false,
                        blocksSelectedText: false,
                        blocksCloudProcessing: false
                    ),
                ],
                cloudConfirmationRequired: false
            )
        )

        XCTAssertEqual(decision.decisions, [.allow])
        XCTAssertEqual(decision.reasons, [.sensitiveApplication])
        XCTAssertNil(decision.redactedContext)
        XCTAssertTrue(decision.redactedPromptVariables.isEmpty)
    }

    func testSecureInputRedactsContextAndSkipsClipboardAndWorkflowCapture() {
        let decision = PrivacyPolicy.evaluate(
            context: makeContext(
                selectedText: "password field",
                clipboardText: "ordinary clipboard",
                secureInput: true
            ),
            settings: PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        )

        XCTAssertTrue(decision.decisions.contains(.redactContext))
        XCTAssertFalse(decision.allowsClipboardCapture)
        XCTAssertFalse(decision.allowsWorkflowCapture)
        XCTAssertTrue(decision.reasons.contains(.secureInput))
        XCTAssertEqual(decision.redactedContext?.focus.selectedText, "")
        XCTAssertEqual(decision.redactedContext?.clipboard.plainText, "")
        XCTAssertEqual(decision.redactedPromptVariables, [.selected, .clipboard])
    }

    func testProtectedClipboardsSkipAllCaptureAndRedactEveryPayloadKind() {
        for protection in ClipboardProtection.allCases {
            let decision = PrivacyPolicy.evaluate(
                context: makeContext(
                    clipboardText: "secret text",
                    clipboardImage: Data([0x01, 0x02]),
                    clipboardFiles: [URL(fileURLWithPath: "/tmp/secret.txt")],
                    protections: [protection]
                ),
                settings: PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: false
                )
            )

            XCTAssertFalse(decision.allowsClipboardCapture, "\(protection)")
            XCTAssertFalse(decision.allowsWorkflowCapture, "\(protection)")
            XCTAssertEqual(decision.redactedContext?.clipboard.plainText, "", "\(protection)")
            XCTAssertNil(decision.redactedContext?.clipboard.imagePNGData, "\(protection)")
            XCTAssertEqual(decision.redactedContext?.clipboard.fileURLs, [], "\(protection)")
            XCTAssertEqual(decision.redactedPromptVariables, [.clipboard], "\(protection)")
        }
    }
}

private func makeContext(
    applicationName: String? = "Notes",
    bundleIdentifier: String? = "com.apple.Notes",
    selectedText: String = "selected text",
    clipboardText: String = "clipboard text",
    clipboardImage: Data? = nil,
    clipboardFiles: [URL] = [],
    secureInput: Bool = false,
    captureTags: [ClipboardCaptureTag] = [],
    protections: [ClipboardProtection] = []
) -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            focusedRole: nil,
            selectedText: selectedText,
            secureInput: secureInput
        ),
        clipboard: ClipboardSnapshot(
            plainText: clipboardText,
            imagePNGData: clipboardImage,
            fileURLs: clipboardFiles,
            changeCount: 1,
            captureTags: captureTags,
            protections: protections
        )
    )
}

private func makeWorkflow(recognizerID: String) -> WorkflowDefinition {
    WorkflowDefinition(
        name: "Privacy Test Workflow",
        pipeline: PipelineDeclaration(
            recognizerID: recognizerID,
            outputActions: [OutputActionReference(id: "clipboard.capture")]
        ),
        ui: WorkflowUIConfig(symbolName: "lock", accentColorName: "blue")
    )
}
