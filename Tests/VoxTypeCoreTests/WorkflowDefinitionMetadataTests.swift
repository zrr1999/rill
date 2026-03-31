import XCTest
@testable import VoxTypeCore

final class WorkflowDefinitionMetadataTests: XCTestCase {
    func testWorkflowCaptureExclusionDefaultsToEnabled() {
        let workflow = WorkflowDefinition(
            name: "Default Policy",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "clipboard.copy")]
            ),
            ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "blue")
        )

        XCTAssertTrue(workflow.excludesOutputFromWorkflowCapture)
    }

    func testWorkflowCaptureExclusionCanBeDisabledViaMetadata() {
        let workflow = WorkflowDefinition(
            name: "Chainable",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "clipboard.copy")]
            ),
            ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "blue"),
            metadata: [WorkflowMetadataKey.excludeOutputFromWorkflowCapture: "false"]
        )

        XCTAssertFalse(workflow.excludesOutputFromWorkflowCapture)
    }
}
