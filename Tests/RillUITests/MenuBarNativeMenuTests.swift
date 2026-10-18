import RillPlatform
import AppKit
import SwiftUI
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class MenuBarNativeMenuTests: XCTestCase {
  func testNativeMenuKeepsActionIconsAndOneSettingsEntryInBothLanguages() async throws {
    _ = NSApplication.shared
    for language in AppLanguage.allCases {
      let model = makeHarness(
        settingsStore: UITestSettingsStore(storage: [.interfaceLanguage: language.rawValue])
      ).model
      await model.waitForInitialVoiceConfiguration()
      let menu = NSHostingMenu(
        rootView: MenuBarStatusView(model: model).labelStyle(.titleOnly)
      )
      menu.update()

      let firstAction = try XCTUnwrap(
        menu.items.firstIndex {
          $0.title == L10n.string(.menuOpenDrafts, language: language)
        })
      let actions = menu.items[firstAction...].filter { !$0.isSeparatorItem }
      XCTAssertEqual(actions.count, 11)
      for item in actions {
        XCTAssertNotNil(item.image, "Missing native menu icon: \(item.title)")
        XCTAssertNil(item.view, "Use native menu items: \(item.title)")
      }
      let settings = actions.filter { $0.title == L10n.text(.settingsTitle, language: language) }
      XCTAssertEqual(settings.count, 1)
      XCTAssertEqual(settings.first?.keyEquivalent, ",")
      XCTAssertEqual(
        actions.prefix(3).map(\.title),
        [
          L10n.string(.menuOpenDrafts, language: language),
          L10n.workspace(.allRecords, language: language),
          L10n.text(.sidebarStream, language: language),
        ])
      await model.recordWorkspace.shutdown()
    }
  }

  func testVoiceMenuUsesWorkflowOutputChoices() async throws {
    _ = NSApplication.shared
    let workflows = try BuiltinWorkflowCatalog().manifest().workflows
    let model = makeHarness(
      workflows: workflows, settingsStore: UITestSettingsStore(storage: [.interfaceLanguage: AppLanguage.english.rawValue, .longRecordingModeEnabled: "false"])
    )
    .model
    await model.waitForInitialVoiceConfiguration()
    let menu = NSHostingMenu(rootView: MenuBarStatusView(model: model))
    menu.update()
    let voice = try XCTUnwrap(menu.items.first { $0.title == L10n.string(.menuVoiceInput, language: .english) }?.submenu)
    voice.update()
    let pendingTitle = L10n.resource("models.output.pending").string(for: .english)
    XCTAssertEqual(voice.items.first { $0.title == pendingTitle }?.state, .on)
    voice.performActionForItem(at: try XCTUnwrap(voice.items.firstIndex { $0.title == L10n.string(.menuLongRecordingToggle, language: .english) }))
    XCTAssertTrue(model.settings.longRecordingModeEnabled)
    voice.update()
    voice.performActionForItem(at: try XCTUnwrap(voice.items.firstIndex { $0.title == pendingTitle }))
    await model.flushPendingPersistenceWrites()
    let workflow = try XCTUnwrap(model.activeVoiceInputWorkflow)
    let action = try XCTUnwrap(workflow.plan.output.actions.last)
    XCTAssertFalse(model.isWorkflowOutputEnabled(action, index: 2, workflow: workflow))
    await model.recordWorkspace.shutdown()
  }

  func testClipboardSubmenuKeepsUnavailableActionsDisabled() async throws {
    _ = NSApplication.shared
    let model = makeHarness(
      settingsStore: UITestSettingsStore(
        storage: [.interfaceLanguage: AppLanguage.english.rawValue],
        unavailableKeys: [.systemClipboardCaptureEnabled]
      )
    ).model
    await model.waitForInitialVoiceConfiguration()
    let menu = NSHostingMenu(rootView: MenuBarStatusView(model: model))
    menu.update()
    let clipboard = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Clipboard ·") }?.submenu)
    clipboard.update()
    let toggle = try XCTUnwrap(clipboard.items.first { $0.title.contains("Clipboard Capture") })
    let ignore = try XCTUnwrap(clipboard.items.first { $0.title == "Ignore Next External Copy" })
    XCTAssertFalse(toggle.isEnabled)
    XCTAssertFalse(ignore.isEnabled)
    let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Last Transcription" })
    XCTAssertFalse(copy.isEnabled)
    await model.recordWorkspace.shutdown()
  }
}
