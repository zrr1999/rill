import RillTestSupport
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class BufferOutputSettingsTests: XCTestCase {
  func testRestoredAndEditedOutputShortcutReachRuntimeWithoutRewritingTheReadValue() async throws {
    let restored = KeyboardShortcut(keyCode: 9, modifiers: [.command, .option])
    let edited = KeyboardShortcut(keyCode: 9, modifiers: [.control, .option])
    let store = UITestSettingsStore(storage: [.bufferOutputHotkey: restored.storageString])
    var runtimeBindings: [HotkeyBindingDescriptor] = []
    let model = makeHarness(
      settingsStore: store,
      recordInteractionServices: makeRecordInteractionServicesForTesting(
        updateBufferHotkey: { runtimeBindings.append($0) })
    ).model
    await model.waitForInitialVoiceConfiguration()
    await model.flushPendingPersistenceWrites()

    XCTAssertEqual(model.settings.bufferOutputHotkeyBinding, .keyboardShortcut(restored))
    XCTAssertEqual(runtimeBindings.last, .keyboardShortcut(restored))
    let restoredActivity = await store.activitySnapshot()
    XCTAssertEqual(restoredActivity.setCounts[.bufferOutputHotkey, default: 0], 0)

    model.setBufferOutputHotkeyShortcut(edited)
    await model.flushPendingPersistenceWrites()

    XCTAssertEqual(model.settings.bufferOutputHotkeyBinding, .keyboardShortcut(edited))
    XCTAssertEqual(runtimeBindings.last, .keyboardShortcut(edited))
    let saved = try await store.string(forKey: .bufferOutputHotkey)
    XCTAssertEqual(saved, edited.storageString)
  }

  func testCollidingShortcutsLeaveRuntimeAndStoredBindingsUnchanged() async throws {
    let panelShortcut = KeyboardShortcut(keyCode: 9, modifiers: [.command, .option])
    let store = UITestSettingsStore(storage: [.recordPanelHotkey: panelShortcut.storageString])
    var runtimeBindings: [HotkeyBindingDescriptor] = []
    let model = makeHarness(
      settingsStore: store,
      recordInteractionServices: makeRecordInteractionServicesForTesting(
        updateHotkey: { runtimeBindings.append($0) },
        updateBufferHotkey: { runtimeBindings.append($0) })
    ).model
    await model.waitForInitialVoiceConfiguration()
    let bindingsBefore = runtimeBindings

    model.setBufferOutputHotkeyShortcut(panelShortcut)
    model.setRecordPanelHotkeyShortcut(.outputNext)
    await model.flushPendingPersistenceWrites()

    XCTAssertEqual(model.settings.recordPanelHotkeyBinding, .keyboardShortcut(panelShortcut))
    XCTAssertEqual(model.settings.bufferOutputHotkeyBinding, .keyboardShortcut(.outputNext))
    XCTAssertEqual(runtimeBindings, bindingsBefore)
    let savedOutput = try await store.string(forKey: .bufferOutputHotkey)
    let savedPanel = try await store.string(forKey: .recordPanelHotkey)
    XCTAssertNil(savedOutput)
    XCTAssertEqual(savedPanel, panelShortcut.storageString)
  }
}
