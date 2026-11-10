import AppKit
import RillCore
@testable import RillPlatform
import XCTest

final class ClipboardOutputFallbackTests: XCTestCase {
  @MainActor
  func testFocusedApplicationOutputTypesTextWithoutReplacingUnpreservableClipboard() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let type = NSPasteboard.PasteboardType("com.example.over-budget")
    let original = Data([0x01, 0x02])
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setData(original, forType: type))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([item]))
    let changeCount = pasteboard.changeCount
    var limits = SystemClipboardPort.TemporaryPreservationLimits.productDefault
    limits.maximumRepresentationByteCount = 1
    let focus = FocusSnapshot(
      applicationName: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 42,
      focusedRole: "AXTextArea", selectedText: "", secureInput: false)
    let output = OutputProbe()
    let engine = TextInjectionEngine(
      pasteboard: SystemClipboardPort(pasteboard: pasteboard, temporaryPreservationLimits: limits),
      accessibilityChecker: { true },
      diagnosticReporter: { await output.record(DiagnosticEventSanitizer.sanitize($0)) },
      focusController: .init(
        currentIdentity: { .init(bundleIdentifier: focus.bundleIdentifier, processIdentifier: focus.processIdentifier) },
        activate: { _ in
          XCTFail("The target already has focus.")
          return false
        }),
      pasteCommandSender: {
        XCTFail("The original clipboard could not be archived.")
        return false
      },
      keyboardChunkSender: { await output.type($0) })
    let action = FocusedApplicationInsertAction(engine: engine)
    let text = String(repeating: "字", count: 19) + "👋 next line\n中文"
    let context = ActionContext(
      runID: UUID(),
      workflow: .init(
        name: "Focused application output",
        plan: .init(setup: .init(), process: .init(), output: .init(actions: [.init(id: action.id)])),
        ui: .init(symbolName: "text.cursor", accentColorName: "green")),
      contextSnapshot: .init(focus: focus, clipboard: .init(plainText: "", changeCount: changeCount)),
      recognitionResult: .init(rawText: text, bestText: text),
      finalText: text, startedAt: Date(), finishedAt: Date())
    let provenance = RecordProvenance(source: .init(kind: .workflow))

    let result = try await action.execute(record: .init(payload: .text(text), provenance: provenance), context: context)
    XCTAssertEqual(result, .injected)
    for payload in [RecordPayload.image(Data([0x89])), .files([URL(fileURLWithPath: "/tmp/fixture.txt")])] {
      do {
        _ = try await action.execute(record: .init(payload: payload, provenance: provenance), context: context)
        XCTFail("Expected rich output to fail without a clipboard archive.")
      } catch let error as TextInjectionEngine.InjectionError {
        XCTAssertEqual(error, .clipboardContentsCannotBePreserved)
      }
    }
    let typedText = await output.text
    XCTAssertEqual(typedText, text)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: type), original)
    let fallbacks = await output.fallbacks
    XCTAssertEqual(fallbacks.map(\.runID), [context.runID])
    XCTAssertEqual(fallbacks.map(\.metadata), [["reason": "clipboard-cannot-be-preserved"]])
  }

  private actor OutputProbe {
    private(set) var text = ""
    private(set) var fallbacks: [DiagnosticEvent] = []

    func type(_ units: [UInt16]) -> Bool {
      text += String(decoding: units, as: UTF16.self)
      return true
    }

    func record(_ event: DiagnosticEvent) {
      if event.name == .clipboardInjectKeyboardFallback { fallbacks.append(event) }
    }
  }
}
