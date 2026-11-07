import AppKit
import RillTestSupport
import RillInputMethodContracts
import RillInputMethodIPC
import Testing
import SwiftUI
import XCTest

@testable import RillUI

@MainActor
struct InputMethodAppearanceModelTests {
  @Test func draftOnlyPublishesOnApplyAndSurvivesReopeningSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = InputMethodAppearanceStore(file: directory.appendingPathComponent("appearance.json"))
    let model = InputMethodAppearanceModel(store: store)
    model.loadIfNeeded()
    model.draft.numberFormat = "{n}."
    model.draft.fontSize = 28
    model.loadIfNeeded()
    #expect(model.draft.numberFormat == "{n}.")
    #expect(model.canApply)
    #expect(try store.load() == .defaults)
    model.apply()
    #expect(model.saved == model.draft)
    #expect(!model.canApply)
    let reopened = InputMethodAppearanceModel(store: store)
    reopened.loadIfNeeded()
    #expect(reopened.draft == model.saved)
    model.draft.numberFormat = "{"
    #expect(model.validationError == .numberFormat)
    #expect(!model.canApply)
    model.apply()
    #expect(try store.load() == reopened.saved)
    model.reset()
    #expect(try store.load() == .defaults)
  }

  @Test func writeFailureKeepsTheDraftWithoutClaimingItWasSaved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appendingPathComponent("file-instead-of-directory")
    try Data().write(to: blocker)
    let store = InputMethodAppearanceStore(file: blocker.appendingPathComponent("appearance.json"))
    let model = InputMethodAppearanceModel(store: store)
    model.draft.showsNumbers = false
    model.apply()
    #expect(model.storageError == .save)
    #expect(model.saved == .defaults)
    #expect(!model.draft.showsNumbers)
    #expect(model.canApply)
  }

  @Test func appearanceControlsHaveEnglishAndChineseCopy() {
    for language in AppLanguage.allCases {
      for key in InputMethodAppearanceText.allCases {
        let text = L10n.inputMethodAppearance(key, language: language)
        #expect(!text.isEmpty)
        #expect(!text.hasPrefix("inputMethodAppearance."))
      }
      #expect(!L10n.inputMethodAppearanceFontSize(20, language: language).contains("%@"))
      #expect(!L10n.inputMethodAppearanceValidationError(.numberFormat, language: language).hasPrefix("inputMethodAppearance."))
    }
  }
}

@MainActor
final class InputMethodAppearanceInteractionTests: NativeAccessibilityTestCase {
  func testDesktopAppearanceControlsApplyDraftAndRestoreFontTarget() async throws {
    guard try await requireInteractiveDesktop() else { return }
    if !NSApp.isRunning { NSApp.finishLaunching() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = InputMethodAppearanceStore(file: directory.appendingPathComponent("appearance.json"))
    let model = InputMethodAppearanceModel(store: store)
    let window = NSPanel(
      contentRect: NSRect(x: 200, y: 200, width: 560, height: 650),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    window.title = "Candidate appearance test"
    window.isReleasedWhenClosed = false
    let view = NSHostingView(
      rootView: Form {
        InputMethodAppearanceSettingsView(model: model, language: .english, isExpanded: true)
      }.formStyle(.grouped))
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    await wait(window) { window.isKeyWindow }
    XCTAssertTrue(press(try XCTUnwrap(element("input-method-show-numbers", in: window))))
    await settle(window)
    XCTAssertFalse(model.draft.showsNumbers)
    XCTAssertEqual(try store.load(), .defaults)

    let manager = NSFontManager.shared
    let previousTarget = manager.target as AnyObject?
    let previousAction = manager.action
    XCTAssertTrue(press(try XCTUnwrap(element("input-method-choose-font", in: window))))
    await settle(window)
    let panel = try XCTUnwrap(manager.fontPanel(false))
    XCTAssertTrue(panel.isVisible)
    let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 28))
    panel.setPanelFont(font, isMultiple: false)
    manager.modifyFontViaPanel(panel)
    await settle(window)
    XCTAssertEqual(model.draft.fontName, font.fontName)
    XCTAssertEqual(model.draft.fontSize, 28)
    let bold = NSMenuItem()
    bold.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
    manager.addFontTrait(bold)
    XCTAssertEqual(model.draft.fontName, "Helvetica-Bold")
    XCTAssertTrue(press(try XCTUnwrap(element("input-method-apply-appearance", in: window))))
    await settle(window)
    XCTAssertEqual(try store.load(), model.draft)
    window.contentView = nil
    await settle(window)
    XCTAssertFalse(panel.isVisible)
    XCTAssertTrue((manager.target as AnyObject?) === previousTarget)
    XCTAssertEqual(manager.action, previousAction)
  }
}
