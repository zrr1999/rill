import AppKit
import SwiftUI
import XCTest
import RillTestSupport
@testable import RillCore
@testable import RillUI

@MainActor
private struct VocabularyPresentationHost: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack {
      ForEach(model.vocabulary.vocabularyCollections) { collection in
        VocabularyCollectionCard(model: model, collection: collection)
      }
    }.padding(20).environment(\.colorScheme, .light)
  }
}

@MainActor
final class VocabularyCollectionPresentationTests: NativeAccessibilityTestCase {
  func testDesktopCollectionDeletionRequiresConfirmationAndRemovesItsBindings() async throws {
    guard try await requireInteractiveDesktop() else { return }
    for language in AppLanguage.allCases {
      let store = UITestSettingsStore()
      let harness = makeHarness(settingsStore: store)
      let model = harness.model
      await model.waitForInitialVoiceConfiguration()
      model.setInterfaceLanguage(language)
      let entry = VocabularyEntry(content: .hotword(phrase: "Rill"))
      let collection = VocabularyCollection(name: "Deletion fixture", entries: [entry])
      model.vocabulary.restore(
        collections: [.personal(), collection],
        bindings: [.init(collectionID: VocabularyCollection.personalID), .init(collectionID: collection.id)])
      model.setVocabularyBindings([.init(collectionID: collection.id)], for: harness.workflow.id)
      let window = makeWindow(model)
      await settle(window)
      let deleteID = "vocabulary.collection.\(collection.id.uuidString).delete"
      XCTAssertNil(element("vocabulary.collection.\(VocabularyCollection.personalID.uuidString).delete", in: window))
      XCTAssertNotNil(element(deleteID, in: window))
      try await capture(window, named: "vocabulary-manager-\(language.rawValue)-light")

      let toggleLabel = "\(L10n.workflowText(.workflowCollectionEntriesToggle, language: language)): \(collection.name)"
      XCTAssertTrue(press(try XCTUnwrap(button(toggleLabel, in: window))))
      await settle(window)
      XCTAssertNil(element("vocabulary.entry.\(entry.id.uuidString).edit", in: window))
      XCTAssertTrue(press(try XCTUnwrap(element(deleteID, in: window))))
      await wait(window) { window.attachedSheet != nil }
      let confirmation = try XCTUnwrap(window.attachedSheet)
      XCTAssertTrue(model.vocabulary.vocabularyCollections.contains { $0.id == collection.id })
      try await capture(confirmation, named: "vocabulary-delete-confirmation-\(language.rawValue)-light")
      _ = press(try XCTUnwrap(button(L10n.recordText(.cancel, language: language), in: confirmation)))
      await wait(window) { window.attachedSheet == nil }
      XCTAssertTrue(model.vocabulary.vocabularyCollections.contains { $0.id == collection.id })

      XCTAssertTrue(press(try XCTUnwrap(button(toggleLabel, in: window))))
      await settle(window)
      XCTAssertTrue(press(try XCTUnwrap(element("vocabulary.entry.\(entry.id.uuidString).edit", in: window))))
      await wait(window) { window.attachedSheet != nil }
      let editor = try XCTUnwrap(window.attachedSheet)
      try await capture(editor, named: "vocabulary-editor-\(language.rawValue)-light")
      _ = press(try XCTUnwrap(button(L10n.string(.vocabularyCorrectionCancel, language: language), in: editor)))
      await wait(window) { window.attachedSheet == nil }

      XCTAssertTrue(press(try XCTUnwrap(element(deleteID, in: window))))
      await wait(window) { window.attachedSheet != nil }
      let repeatedConfirmation = try XCTUnwrap(window.attachedSheet)
      _ = press(try XCTUnwrap(button(L10n.text(.clipboardDeleteItem, language: language), in: repeatedConfirmation)))
      await wait(window) { !model.vocabulary.vocabularyCollections.contains { $0.id == collection.id } }
      XCTAssertNil(element(deleteID, in: window))
      XCTAssertFalse(model.vocabulary.vocabularyCollectionBindings.contains { $0.collectionID == collection.id })
      XCTAssertFalse(model.workflowLibrary.customWorkflows.contains { $0.plan.setup.vocabularyBindings.contains { $0.collectionID == collection.id } })
      XCTAssertTrue(model.vocabulary.vocabularyCollections.contains { $0.id == VocabularyCollection.personalID })
      await model.flushPendingPersistenceWrites()
      let reloaded = makeHarness(settingsStore: store).model
      await reloaded.waitForInitialVoiceConfiguration()
      XCTAssertFalse(reloaded.vocabulary.vocabularyCollections.contains { $0.id == collection.id })
      XCTAssertFalse(reloaded.vocabulary.vocabularyCollectionBindings.contains { $0.collectionID == collection.id })
      window.close()
      await reloaded.stopSettingsReadTasksForApplicationShutdown()
      await model.stopSettingsReadTasksForApplicationShutdown()
      await reloaded.flushPendingPersistenceWrites()
    }
  }

  private func capture(_ window: NSWindow, named name: String) async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"],
      ProcessInfo.processInfo.environment["RILL_UI_COMPOSITOR_CAPTURE"] == "1"
    else { return }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try await captureNativeWindow(window, to: output.appendingPathComponent(name + ".png"))
  }

  private func makeWindow(_ model: AppModel) -> NSWindow {
    _ = NSApplication.shared
    if !NSApp.isRunning {
      NSApp.finishLaunching()
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Vocabulary presentation \(UUID().uuidString)"
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(rootView: VocabularyPresentationHost(model: model))
    window.makeKeyAndOrderFront(nil)
    return window
  }
}
