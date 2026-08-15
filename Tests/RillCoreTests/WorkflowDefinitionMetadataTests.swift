import XCTest
@testable import RillCore

final class WorkflowDefinitionMetadataTests: XCTestCase {
    func testWorkflowCaptureExclusionDefaultsToEnabled() {
        let workflow = WorkflowDefinition(
            name: "Default Policy",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "system-clipboard.copy")]
            ),
            ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "blue")
        )

        XCTAssertTrue(workflow.excludesOutputFromRecordCapture)
    }

    func testWorkflowCaptureExclusionCanBeDisabledViaMetadata() {
        let workflow = WorkflowDefinition(
            name: "Chainable",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "system-clipboard.copy")]
            ),
            ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "blue"),
            metadata: [WorkflowMetadataKey.excludeOutputFromWorkflowCapture: "false"]
        )

        XCTAssertFalse(workflow.excludesOutputFromRecordCapture)
    }

    func testCursorPlacementIsIgnoredWhenLivePreviewIsDisabled() {
        let workflow = WorkflowDefinition(
            name: "Preview disabled",
            pipeline: PipelineDeclaration(recognizerID: "local-speech", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "blue"),
            metadata: [
                WorkflowMetadataKey.livePreviewEnabled: "false",
                WorkflowMetadataKey.livePreviewPlacement: "cursor",
            ]
        )

        XCTAssertFalse(workflow.livePreviewIsEnabled)
        XCTAssertEqual(workflow.resolvedLivePreviewPlacement, .overlay)
    }

    func testBuiltinPushToTalkRoutingRequiresEveryIdentityAndInvocationCondition() {
        let workflow = WorkflowDefinition(
            name: "Builtin Push to Talk",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(
                recognizerID: "sherpa-onnx.local",
                outputActions: [OutputActionReference(id: "focused-application.insert")]
            ),
            ui: WorkflowUIConfig(symbolName: "mic", accentColorName: "red"),
            metadata: [
                WorkflowMetadataKey.catalog: BuiltinWorkflowRoutingValue.catalog,
                WorkflowMetadataKey.triggerGesture: BuiltinWorkflowRoutingValue.pushToTalkGesture,
                WorkflowMetadataKey.builtinKind: "push-to-talk.dictation",
            ]
        )

        XCTAssertTrue(workflow.usesBuiltinPushToTalkOutputRouting(initiatedBy: .hotkey))
        XCTAssertFalse(workflow.usesBuiltinPushToTalkOutputRouting(initiatedBy: .manual))
        var manualWorkflow = workflow
        manualWorkflow.trigger = .manual
        XCTAssertFalse(manualWorkflow.usesBuiltinPushToTalkOutputRouting(initiatedBy: .hotkey))

        for key in [
            WorkflowMetadataKey.catalog,
            WorkflowMetadataKey.triggerGesture,
            WorkflowMetadataKey.builtinKind,
        ] {
            var missingIdentity = workflow
            missingIdentity.metadata.removeValue(forKey: key)
            XCTAssertFalse(
                missingIdentity.usesBuiltinPushToTalkOutputRouting(initiatedBy: .hotkey),
                "Routing must reject a missing \(key)."
            )
        }
    }

    func testStrictGroupAutomationParserMapsEveryLegacyEventKind() throws {
        let sourceCollectionID = UUID()
        let cases: [(String, RecordCollectionEventKind)] = [
            ("groupItemCreated", .recordCreated),
            ("groupItemEdited", .recordEdited),
            ("groupItemRemoved", .recordRemoved),
        ]

        for (rawEventType, expectedKind) in cases {
            let workflow = makeWorkflow(metadata: [
                WorkflowMetadataKey.legacyEventType: rawEventType,
                WorkflowMetadataKey.legacySourceCollectionID: sourceCollectionID.uuidString,
                WorkflowMetadataKey.legacyExcludePolishTag: "true",
                WorkflowMetadataKey.legacyGroupActionKind:
                    RecordCollectionActionKind.removeRecord.rawValue,
            ])

            let configuration = try XCTUnwrap(
                workflow.parseRecordCollectionAutomationConfiguration()
            )

            XCTAssertEqual(configuration.rule.eventKind, expectedKind)
            XCTAssertEqual(
                configuration.rule.sourceCollectionID,
                RecordCollectionID(sourceCollectionID)
            )
            XCTAssertEqual(
                configuration.rule.conditions,
                [.excludingTag(.polishGenerated)]
            )
            XCTAssertEqual(configuration.actionKind, .removeRecord)
        }
    }

    func testStrictGroupAutomationParserCanDisablePolishExclusionExplicitly() throws {
        let workflow = makeWorkflow(metadata: validGroupMetadata(
            excludePolishTag: "false"
        ))

        let configuration = try XCTUnwrap(
            workflow.parseRecordCollectionAutomationConfiguration()
        )

        XCTAssertEqual(configuration.rule.conditions, [])
    }

    func testStrictGroupAutomationParserReturnsNilForNonGroupWorkflow() throws {
        for eventType in [nil, "manual", "hotkey", "menuBar", "wakeWord"] {
            var metadata: [String: String] = [:]
            if let eventType {
                metadata[WorkflowMetadataKey.legacyEventType] = eventType
            }

            XCTAssertNil(
                try makeWorkflow(metadata: metadata)
                    .parseRecordCollectionAutomationConfiguration()
            )
        }
    }

    func testStrictGroupAutomationParserRejectsMalformedValues() {
        assertGroupParseError(
            metadata: validGroupMetadata(sourceCollectionID: "not-a-uuid"),
            equals: .invalidSourceCollectionID
        )
        assertGroupParseError(
            metadata: validGroupMetadata(excludePolishTag: "TRUE"),
            equals: .invalidExcludePolishTag
        )
        assertGroupParseError(
            metadata: validGroupMetadata(actionKind: "updateItem"),
            equals: .invalidActionKind
        )
        assertGroupParseError(
            metadata: validGroupMetadata(eventType: "groupItemCopied"),
            equals: .invalidEventType
        )
    }

    func testStrictGroupAutomationParserDoesNotDefaultRequiredPolicyFields() {
        let requiredFields: [(String, RecordCollectionAutomationConfigurationError)] = [
            (WorkflowMetadataKey.legacySourceCollectionID, .missingSourceCollectionID),
            (WorkflowMetadataKey.legacyExcludePolishTag, .missingExcludePolishTag),
            (WorkflowMetadataKey.legacyGroupActionKind, .missingActionKind),
        ]

        for (key, expectedError) in requiredFields {
            var metadata = validGroupMetadata()
            metadata.removeValue(forKey: key)
            assertGroupParseError(metadata: metadata, equals: expectedError)
        }
    }

    private func makeWorkflow(metadata: [String: String]) -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Metadata Policy",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "system-clipboard.copy")]
            ),
            ui: WorkflowUIConfig(
                symbolName: "doc.on.clipboard",
                accentColorName: "blue"
            ),
            metadata: metadata
        )
    }

    private func validGroupMetadata(
        eventType: String = "groupItemCreated",
        sourceCollectionID: String = UUID().uuidString,
        excludePolishTag: String = "true",
        actionKind: String = RecordCollectionActionKind.editRecord.rawValue
    ) -> [String: String] {
        [
            WorkflowMetadataKey.legacyEventType: eventType,
            WorkflowMetadataKey.legacySourceCollectionID: sourceCollectionID,
            WorkflowMetadataKey.legacyExcludePolishTag: excludePolishTag,
            WorkflowMetadataKey.legacyGroupActionKind: actionKind,
        ]
    }

    private func assertGroupParseError(
        metadata: [String: String],
        equals expectedError: RecordCollectionAutomationConfigurationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try makeWorkflow(metadata: metadata)
                .parseRecordCollectionAutomationConfiguration(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? RecordCollectionAutomationConfigurationError,
                expectedError,
                file: file,
                line: line
            )
        }
    }
}
