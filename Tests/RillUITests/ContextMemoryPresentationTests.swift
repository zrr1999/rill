import AppKit
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
struct MemoryPresentationFixture {
  let app: AppModel
  let model: ContextMemoryModel
  let repository: ContextUIRepository
  let workflow: WorkflowDefinition
  let memories: [LongTermMemory]
  let receipt: CorrectionReferenceReceipt

  static func make() async throws -> Self {
    var workflow = makeBuiltinPushToTalkWorkflow()
    XCTAssertFalse(workflow.supportsContextualCorrection)
    workflow.name = "Scope fixture workflow"
    workflow.titleKey = nil
    let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let first = LongTermMemory(
      scope: .init(workflowID: workflow.id, applicationBundleID: "fixture.editor", language: "zh-Hans"),
      summary: "FIRST_CURRENT_SUMMARY · 当前项目使用 Rill", terms: ["PRIVATE_MEMORY_TERM"], evidenceKind: .userStatement,
      sources: [.init(sourceID: sourceID, revision: 7)], expiresAt: .distantPast)
    let second = LongTermMemory(
      scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
      summary: "SECOND_CURRENT_SUMMARY · 检查术语后再提交", evidenceKind: .userCorrection,
      sources: [.init(sourceID: UUID(), revision: 2)], sourceHistoryDeleted: true)
    let repository = ContextUIRepository(memories: [first, second])
    let model = ContextMemoryModel(
      repository: repository, settingsStore: UITestSettingsStore(storage: [:]),
      activate: { _ in false }, revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
    model.load()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertFalse(model.isLoading)
    let app = makeHarness(workflows: [workflow]).model
    await app.waitForInitialVoiceConfiguration()
    await app.waitForHistoryProjectionLoads()
    app.contextMemory = model
    return Self(
      app: app, model: model, repository: repository, workflow: workflow, memories: [first, second],
      receipt: .init(
        imageSummary: .sent, memorySummary: .sent,
        screenSummary: .init(terms: ["PRIVATE_SCREEN_TERM"], observations: ["PRIVATE_SCREEN_OBSERVATION"]),
        memoryIDs: [second.id, UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, first.id]))
  }

  func shutdown() async {
    await app.stopSettingsReadTasksForApplicationShutdown()
    await app.flushPendingPersistenceWrites()
    await model.shutdown()
  }
}

@MainActor
private struct MemoryReferenceHost: View {
  @Bindable var app: AppModel
  let receipt: CorrectionReferenceReceipt

  var body: some View {
    CorrectionReferenceView(
      receipt: receipt, memories: app.contextMemory?.memories ?? [], workflows: app.workflowLibrary.workflows,
      previewMode: app.settings.privacyPolicySettings.historyPreviewMode, language: app.settings.language,
      manageMemories: { app.showSettings(.contextMemory) }, isExpanded: true
    )
    .padding(20)
  }
}

@MainActor
final class ContextMemoryPresentationTests: NativeAccessibilityTestCase {
  func testPrivacyTighteningRemovesReferenceBodiesFromTheRealAccessibilityTree() async throws {
    for language in AppLanguage.allCases {
      let fixture = try await MemoryPresentationFixture.make()
      fixture.app.setInterfaceLanguage(language)
      fixture.app.setPrivacyHistoryPreviewMode(.full)
      let window = makeWindow(MemoryReferenceHost(app: fixture.app, receipt: fixture.receipt))
      await settle(window)
      let reads = await fixture.repository.memoryReadCount
      let full = accessibilityText(window)
      for canary in ["PRIVATE_SCREEN_TERM", "PRIVATE_SCREEN_OBSERVATION", "FIRST_CURRENT_SUMMARY", "PRIVATE_MEMORY_TERM"] {
        XCTAssertTrue(full.contains(canary), "Full AX tree must contain the positive canary: \(canary)")
      }
      XCTAssertNotNil(button(L10n.surface(.manageMemories, language: language), in: window))
      for mode in [PrivacyHistoryPreviewMode.restricted, .disabled] {
        fixture.app.setPrivacyHistoryPreviewMode(mode)
        await settle(window)
        let hidden = accessibilityText(window)
        XCTAssertTrue(hidden.contains(L10n.surface(.correctionReferences, language: language)), "The host AX tree must remain populated")
        for canary in ["PRIVATE_SCREEN", "CURRENT_SUMMARY", "PRIVATE_MEMORY_TERM", "fixture.editor", "00000000-0000-0000-0000-000000000099"] {
          XCTAssertFalse(hidden.contains(canary), "Sensitive AX node survived privacy tightening: \(canary)")
        }
        XCTAssertNil(button(L10n.surface(.manageMemories, language: language), in: window))
      }
      let finalReads = await fixture.repository.memoryReadCount
      XCTAssertEqual(finalReads, reads, "History references observe the existing model without refreshing it")
      window.close()
      await fixture.shutdown()
    }
  }

  func testReferencesKeepReceiptOrderMissingEntriesAndObserveCurrentEdits() async throws {
    let fixture = try await MemoryPresentationFixture.make()
    fixture.app.setPrivacyHistoryPreviewMode(.full)
    let window = makeWindow(MemoryReferenceHost(app: fixture.app, receipt: fixture.receipt))
    await settle(window)
    let text = accessibilityText(window)
    let second = try XCTUnwrap(text.range(of: "SECOND_CURRENT_SUMMARY"))
    let missing = try XCTUnwrap(text.range(of: "00000000-0000-0000-0000-000000000099"))
    let first = try XCTUnwrap(text.range(of: "FIRST_CURRENT_SUMMARY"))
    XCTAssertLessThan(second.lowerBound, missing.lowerBound)
    XCTAssertLessThan(missing.lowerBound, first.lowerBound)
    XCTAssertTrue(text.contains(fixture.workflow.name))
    var edited = fixture.memories
    edited[0].summary = "EDITED_CURRENT_SUMMARY"
    await fixture.repository.replaceMemories(edited)
    await fixture.model.refresh()
    await settle(window)
    let updated = accessibilityText(window)
    XCTAssertTrue(updated.contains("EDITED_CURRENT_SUMMARY"))
    XCTAssertFalse(updated.contains("FIRST_CURRENT_SUMMARY"))
    XCTAssertTrue(updated.contains(L10n.surface(.memoryCurrentContentNotice, language: fixture.app.settings.language)))
    window.close()
    await fixture.shutdown()
  }

  func testManagementShowsPreciseScopeExpiryAndSourceEvidenceWithoutMutatingIt() async throws {
    let fixture = try await MemoryPresentationFixture.make()
    await fixture.repository.replaceMemories([fixture.memories[0]])
    await fixture.model.refresh()
    let window = makeWindow(
      MemoryManagementView(model: fixture.model, workflows: [fixture.workflow], language: .english, openSource: { _ in }),
      size: NSSize(width: 760, height: 900))
    await settle(window)
    let expired = accessibilityText(window)
    for value in [fixture.workflow.name, "fixture.editor", "zh-Hans", "PRIVATE_MEMORY_TERM", fixture.memories[0].sources[0].sourceID.uuidString] {
      XCTAssertTrue(expired.contains(value), "Missing detail in the real AX tree: \(value)")
    }
    XCTAssertTrue(expired.contains(L10n.surface(.memoryExpiredNotSelected, language: .english)))
    XCTAssertTrue(expired.contains("Evidence revision\n7"))
    XCTAssertFalse(expired.contains(L10n.surface(.memoryAllSourceBodiesDeleted, language: .english)))
    var memory = fixture.memories[1]
    for expiresAt in [nil, Date.distantFuture] {
      memory.expiresAt = expiresAt
      await fixture.repository.replaceMemories([memory])
      await fixture.model.refresh()
      await settle(window)
      let current = accessibilityText(window)
      for value in [memory.scope.workflowID.uuidString, "Not recorded", "Not specified", "All source history bodies have been deleted."] {
        XCTAssertTrue(current.contains(value))
      }
      XCTAssertFalse(current.contains(L10n.surface(.memoryExpiredNotSelected, language: .english)))
      XCTAssertEqual(current.contains("No expiry"), expiresAt == nil)
    }
    let writes = await fixture.repository.writeCount
    XCTAssertEqual(writes, 0, "Displaying an expired memory must not archive or otherwise mutate it")
    window.close()
    await fixture.shutdown()
  }

  func testOpenManagementUpdatesAtExpiryWithoutRefreshingOrWritingMemories() async throws {
    let fixture = try await MemoryPresentationFixture.make()
    var memory = fixture.memories[0]
    memory.expiresAt = .distantFuture
    await fixture.repository.replaceMemories([memory])
    await fixture.model.refresh()
    let window = makeWindow(
      MemoryManagementView(model: fixture.model, workflows: [fixture.workflow], language: .english, openSource: { _ in }))
    await settle(window)
    let expiredLabel = L10n.surface(.memoryExpiredNotSelected, language: .english)
    XCTAssertFalse(accessibilityText(window).contains(expiredLabel))

    memory.expiresAt = Date().addingTimeInterval(2)
    await fixture.repository.replaceMemories([memory])
    await fixture.model.refresh()
    await settle(window)
    XCTAssertFalse(accessibilityText(window).contains(expiredLabel))
    let reads = await fixture.repository.memoryReadCount
    await wait(window) { accessibilityText(window).contains(expiredLabel) }
    let finalReads = await fixture.repository.memoryReadCount
    let writes = await fixture.repository.writeCount
    XCTAssertEqual(finalReads, reads, "Expiry updates the presentation without reloading persistence")
    XCTAssertEqual(writes, 0, "Expiry presentation must not archive the memory")
    window.close()
    await fixture.shutdown()
  }

  func testSourceNavigationWaitsForManagementSheetDismissalAndOrdinaryCloseDoesNotNavigate() async throws {
    let fixture = try await MemoryPresentationFixture.make()
    await fixture.repository.replaceMemories([fixture.memories[0]])
    await fixture.model.refresh()
    var window: NSWindow!
    var sheetAttachedAtNavigation: Bool?
    window = makeWindow(
      ContextMemorySettingsView(
        memory: fixture.model, workflows: [fixture.workflow], language: .english,
        openSource: { sourceID in
          sheetAttachedAtNavigation = window.attachedSheet != nil
          fixture.app.showHistoryEntry(sourceID)
        }, isExpanded: .constant(true)))
    await settle(window)
    let manage = try XCTUnwrap(element("settings.context.manage-memories", in: window))
    XCTAssertTrue(press(manage))
    await wait(window) { window.attachedSheet != nil }
    let cancelledSheet = try XCTUnwrap(window.attachedSheet)
    let done = try XCTUnwrap(button(L10n.surface(.done, language: .english), in: cancelledSheet))
    XCTAssertTrue(press(done))
    await wait(window) { window.attachedSheet == nil }
    XCTAssertNil(fixture.app.history.historyNavigationRequest)
    XCTAssertNil(sheetAttachedAtNavigation)

    let reopenedManage = try XCTUnwrap(element("settings.context.manage-memories", in: window))
    XCTAssertTrue(press(reopenedManage))
    await wait(window) { window.attachedSheet != nil }
    let sourceID = fixture.memories[0].sources[0].sourceID
    let sheet = try XCTUnwrap(window.attachedSheet)
    XCTAssertNil(fixture.app.history.historyNavigationRequest)
    let source = try XCTUnwrap(element("memory.source.\(sourceID.uuidString)", in: sheet))
    XCTAssertTrue(press(source))
    await wait(window) { fixture.app.history.historyNavigationRequest != nil }
    XCTAssertEqual(sheetAttachedAtNavigation, false)
    XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(fixture.app.history.historyNavigationRequest?.entryID, sourceID)
    XCTAssertEqual(fixture.app.selectedSidebarSection, .stream)
    window.close()
    await fixture.shutdown()
  }

  private func makeWindow<Content: View>(_ content: Content, size: NSSize = NSSize(width: 800, height: 900)) -> NSWindow {
    _ = NSApplication.shared
    if !NSApp.isRunning {
      NSApp.setActivationPolicy(.accessory)
      NSApp.finishLaunching()
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Memory presentation \(UUID().uuidString)"
    window.contentView = NSHostingView(rootView: content)
    window.makeKeyAndOrderFront(nil)
    return window
  }

}
