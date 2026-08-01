import Foundation
import XCTest
@testable import RillCore

final class WorkflowPlanTests: XCTestCase {
    func testWorkflowDefinitionEncodesPlanWithoutLegacyPipeline() throws {
        let workflow = makeVoiceWorkflow()

        let data = try JSONEncoder().encode(workflow)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: data)

        XCTAssertNotNil(object["plan"])
        XCTAssertNil(object["pipeline"])
        XCTAssertEqual(decoded, workflow)
    }

    func testLegacyPipelineDecodesIntoThreePhasePlan() throws {
        let workflow = makeVoiceWorkflow()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(workflow)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "plan")
        object["pipeline"] = [
            "recognizerID": "legacy.recognizer",
            "postProcessSteps": [],
            "outputActions": [
                ["id": "clipboard.copy", "configuration": [:]],
            ],
            "uncertaintyPolicy": [
                "mode": "off",
                "confidenceThreshold": 0,
                "timeoutSeconds": 0,
            ],
            "deliveryPolicy": ["strategy": "clipboardOnly"],
        ]

        let decoded = try JSONDecoder().decode(
            WorkflowDefinition.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.plan.setup.speechRoute?.recognizerID, "legacy.recognizer")
        XCTAssertEqual(
            decoded.plan.process.steps.map(\.kind),
            [.recognizeSpeech, .applyVocabulary]
        )
        XCTAssertEqual(decoded.plan.output.actions.map(\.id), ["clipboard.copy"])
    }

    func testValidatorRejectsRecognitionOutsideFirstPosition() {
        var workflow = makeVoiceWorkflow()
        workflow.plan.process.steps = [
            WorkflowProcessStep(kind: .applyVocabulary),
            WorkflowProcessStep(kind: .recognizeSpeech),
        ]

        XCTAssertThrowsError(
            try WorkflowPlanValidator.validate(workflow.plan, input: .audio)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowPlanValidationError,
                .recognitionMustBeFirst
            )
        }
    }

    func testValidatorAllowsTextOnlyPlanAndRejectsEmptyOutput() throws {
        var plan = WorkflowPlan(
            setup: WorkflowSetupPhase(),
            process: WorkflowProcessPhase(
                steps: [WorkflowProcessStep(kind: .applyVocabulary)]
            ),
            output: WorkflowOutputPhase(
                actions: [OutputActionReference(id: "clipboard.copy")]
            )
        )

        XCTAssertNoThrow(try WorkflowPlanValidator.validate(plan, input: .text))
        plan.output.actions = []
        XCTAssertThrowsError(
            try WorkflowPlanValidator.validate(plan, input: .text)
        ) { error in
            XCTAssertEqual(error as? WorkflowPlanValidationError, .missingOutput)
        }
    }

    func testBindingConditionsAreAndWithinBindingAndOrAcrossBindings() {
        let collectionID = UUID()
        let hotwordID = UUID()
        let collection = VocabularyCollection(
            id: collectionID,
            name: "Scoped",
            entries: [
                VocabularyEntry(
                    id: hotwordID,
                    content: .hotword(phrase: "Rill")
                ),
            ]
        )
        let bindings = [
            VocabularyCollectionBinding(
                collectionID: collectionID,
                condition: WorkflowBindingCondition(
                    bundleIdentifier: "com.example.editor",
                    locale: "zh-CN"
                )
            ),
            VocabularyCollectionBinding(
                collectionID: collectionID,
                condition: WorkflowBindingCondition(locale: "en-US")
            ),
        ]

        let chinese = VocabularyCollectionResolver.resolve(
            bindings: bindings,
            collections: [collection],
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.editor",
                locale: "zh-CN"
            )
        )
        let english = VocabularyCollectionResolver.resolve(
            bindings: bindings,
            collections: [collection],
            context: VocabularyRuleContext(locale: "en-US")
        )
        let mismatch = VocabularyCollectionResolver.resolve(
            bindings: bindings,
            collections: [collection],
            context: VocabularyRuleContext(
                bundleIdentifier: "com.example.other",
                locale: "zh-CN"
            )
        )

        XCTAssertEqual(chinese.hotwordRules.map(\.id), [hotwordID])
        XCTAssertEqual(english.hotwordRules.map(\.id), [hotwordID])
        XCTAssertTrue(mismatch.hotwordRules.isEmpty)
    }

    func testLegacyMigrationIsDeterministicAndPreservesRuleState() {
        let scopedID = UUID(uuidString: "22144B4B-93D3-4B0D-A797-3A78D5FF788A")!
        let rule = VocabularyRule(
            id: scopedID,
            kind: .mapping,
            enabled: false,
            pattern: "codex",
            replacement: "Codex",
            matchMode: .wordBoundary,
            caseSensitive: true,
            scope: VocabularyRuleScope(
                bundleIdentifier: "com.openai.codex",
                locale: "zh-CN"
            ),
            priority: 7,
            createdAt: Date(timeIntervalSince1970: 123)
        )

        let first = VocabularyLegacyMigrator.migrate([rule])
        let second = VocabularyLegacyMigrator.migrate([rule])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.collections[0].entries[0].id, scopedID)
        XCTAssertFalse(first.collections[0].entries[0].enabled)
        XCTAssertEqual(
            first.bindings[0].condition,
            WorkflowBindingCondition(
                bundleIdentifier: "com.openai.codex",
                locale: "zh-CN"
            )
        )
    }

    private func makeVoiceWorkflow() -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Plan Test",
            plan: WorkflowPlan(
                setup: WorkflowSetupPhase(
                    speechRoute: WorkflowSpeechRoute(
                        recognizerID: "test.recognizer"
                    )
                ),
                process: WorkflowProcessPhase(
                    steps: [
                        WorkflowProcessStep(kind: .recognizeSpeech),
                        WorkflowProcessStep(kind: .applyVocabulary),
                    ]
                ),
                output: WorkflowOutputPhase(
                    actions: [OutputActionReference(id: "clipboard.copy")],
                    deliveryPolicy: DeliveryPolicy(strategy: .clipboardOnly)
                )
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }
}
