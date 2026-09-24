
@testable import RillCore
@testable import RillWorkflows
import XCTest
@testable import RillProviders

final class SelectionCaptureRecognizerTests: XCTestCase {
    func testRecognizerUsesClipboardWhenSelectionIsMissingAndClipboardIsAllowed() async throws {
        let recognizer = SelectionCaptureRecognizer()

        let result = try await recognizer.recognize(
            RecognitionRequest(
                runID: UUID(),
                workflow: makeWorkflow(),
                contextSnapshot: makeContext(
                    selectedText: "",
                    clipboard: SystemClipboardSnapshot(plainText: "clipboard text", changeCount: 1)
                )
            )
        )

        XCTAssertEqual(result.bestText, "clipboard text")
    }

    func testRecognizerRejectsClipboardWhenWorkflowCaptureIsExcluded() async {
        let recognizer = SelectionCaptureRecognizer()

        do {
            _ = try await recognizer.recognize(
                RecognitionRequest(
                    runID: UUID(),
                    workflow: makeWorkflow(),
                    contextSnapshot: makeContext(
                        selectedText: "",
                        clipboard: SystemClipboardSnapshot(
                            plainText: "loop me",
                            changeCount: 2,
                            captureTags: [.excludeFromWorkflowCapture]
                        )
                    )
                )
            )
            XCTFail("Expected workflow-protected clipboard content to be rejected.")
        } catch let error as SelectionCaptureRecognizer.RecognizerError {
            XCTAssertEqual(error, .clipboardExcludedFromWorkflowCapture)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecognizerPrefersSelectionEvenWhenClipboardIsProtected() async throws {
        let recognizer = SelectionCaptureRecognizer()

        let result = try await recognizer.recognize(
            RecognitionRequest(
                runID: UUID(),
                workflow: makeWorkflow(),
                contextSnapshot: makeContext(
                    selectedText: "selected text",
                    clipboard: SystemClipboardSnapshot(
                        plainText: "loop me",
                        changeCount: 3,
                        captureTags: [.excludeFromWorkflowCapture]
                    )
                )
            )
        )

        XCTAssertEqual(result.bestText, "selected text")
    }
}

private func makeWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
        name: "Capture",
        pipeline: PipelineDeclaration(
            recognizerID: "context.selection",
            outputActions: [OutputActionReference(id: "system-clipboard.copy")]
        ),
        ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "blue")
    )
}

private func makeContext(selectedText: String, clipboard: SystemClipboardSnapshot) -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: nil,
            focusedRole: nil,
            selectedText: selectedText,
            secureInput: false
        ),
        clipboard: clipboard
    )
}
