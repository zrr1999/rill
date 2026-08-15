import AppKit
import XCTest
@testable import RillCore
@testable import RillPlatform
@testable import RillProviders

final class FocusedApplicationInsertActionTests: XCTestCase {
    func testCommittedPasteRestoreFailureCrossesProviderBoundaryAsCommittedOutput() async throws {
        let pasteboard = await MainActor.run {
            SystemClipboardPort(
                pasteboard: NSPasteboard(
                    name: .init("dev.rill.provider-tests.\(UUID().uuidString)")
                )
            )
        }
        _ = await pasteboard.writePlainText("original clipboard")
        let pasteProbe = FocusedApplicationPasteProbe()
        let focusIdentity = TextInjectionEngine.FocusIdentity(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42
        )
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            focusController: TextInjectionEngine.FocusController(
                currentIdentity: { focusIdentity },
                activate: { _ in true }
            ),
            pasteCommandSender: {
                await pasteProbe.recordPaste()
                return true
            },
            temporaryClipboardRestorer: { _, expectedChangeCount in
                .writeFailed(retryChangeCount: expectedChangeCount + 1)
            }
        )
        let action = FocusedApplicationInsertAction(engine: engine)
        let focus = FocusSnapshot(
            applicationName: "Editor",
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            focusedRole: "AXTextArea",
            selectedText: "",
            secureInput: false
        )
        let context = ActionContext(
            runID: UUID(),
            workflow: WorkflowDefinition(
                name: "Insert",
                pipeline: PipelineDeclaration(
                    recognizerID: "test.recognizer",
                    outputActions: [
                        OutputActionReference(id: BuiltinRecordActionID.focusedApplicationInsert),
                    ]
                ),
                ui: WorkflowUIConfig(symbolName: "text.insert", accentColorName: "blue")
            ),
            contextSnapshot: ContextSnapshot(
                focus: focus,
                clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0)
            ),
            recognitionResult: RecognitionResult(rawText: "payload", bestText: "payload"),
            finalText: "payload",
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2)
        )

        do {
            _ = try await action.execute(
                record: RecordDraft(
                    payload: .text("payload"),
                    provenance: RecordProvenance(
                        source: RecordSourceIdentity(kind: .workflow)
                    )
                ),
                context: context
            )
            XCTFail("A committed paste with failed clipboard recovery must report its fixed failure.")
        } catch let failure as CommittedOutputFailure {
            XCTAssertEqual(failure, .clipboardRestorationFailedAfterInjection)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let pasteCount = await pasteProbe.count()
        XCTAssertEqual(pasteCount, 1)
    }
}

private actor FocusedApplicationPasteProbe {
    private var pasteCount = 0

    func recordPaste() {
        pasteCount += 1
    }

    func count() -> Int {
        pasteCount
    }
}
