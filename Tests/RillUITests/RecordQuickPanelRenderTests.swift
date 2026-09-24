import AppKit
import SwiftUI
import XCTest

@testable import RillCore
@testable import RillRuntime
@testable import RillUI

@MainActor
final class RecordQuickPanelRenderTests: XCTestCase {
  func testRenderQuickPanelAndCleanupInBothAppearances() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR for native quick-panel evidence.")
    }
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let store = RecordStore()
    for (text, app) in [
      ("swift test --parallel", "Terminal"),
      ("设计评审：快捷剪贴板\n唤起即搜索，找到即粘贴。", "备忘录"),
      ("https://example.com/project/notes", "Safari"),
      ("会议记录 · 关注异常与取消路径", "备忘录"),
    ] {
      _ = try await store.ingest(
        .init(
          payload: .text(text),
          provenance: .init(source: .init(kind: .systemClipboard), sourceApplicationName: app)),
        into: [])
    }
    let panel = RecordQuickPanelModel(store: store)
    panel.start(sourceBundleIdentifier: nil)
    defer { panel.stop() }
    for _ in 0..<100 where panel.results.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    panel.pasteTargetName = "Notes"
    panel.togglePreview()
    for _ in 0..<100 where panel.preview == nil { await waitForMainRunLoopDefaultMode() }
    XCTAssertNotNil(panel.preview)
    for dark in [false, true] {
      for width in [620, 900] {
      let view = NSHostingView(
        rootView: RecordQuickPanelView(
          model: panel, language: .simplifiedChinese, capturePaused: false,
          onPaste: { _ in }, onCopy: { _ in }, onShowRecord: { _ in }, onClose: {}, onConfigureJev: { _ in }
        )
        .environment(\.colorScheme, dark ? .dark : .light))
      try await render(
        view, size: NSSize(width: width, height: 560), dark: dark,
        to: output.appendingPathComponent("quick-panel-\(dark ? "dark" : "light")-\(width).png"))
      }
      await panel.cleanup.request()
      let cleanup = NSHostingView(
        rootView: RecordCleanupSheet(model: panel.cleanup, language: .simplifiedChinese)
          .environment(\.colorScheme, dark ? .dark : .light))
      try await render(
        cleanup, size: NSSize(width: 480, height: 360), dark: dark,
        to: output.appendingPathComponent("cleanup-\(dark ? "dark" : "light").png"))
      panel.cleanup.cancel()
    }
  }

  func testRenderSemanticReadyAndDownloadStates() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR for native semantic-panel evidence.")
    }
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for missing in [false, true] {
      let store = RecordStore()
      for text in ["git reset --soft HEAD~1", "git revert HEAD"] {
        _ = try await store.ingest(.init(payload: .text(text),
          provenance: .init(source: .init(kind: .systemClipboard), sourceApplicationName: "Terminal")), into: [])
      }
      let search = RecordSemanticSearch(store: store, embedder: PanelEmbeddingFixture(missing: missing))
      let panel = RecordQuickPanelModel(store: store, semanticSearch: search)
      panel.start(sourceBundleIdentifier: nil)
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while panel.capacity.count != 2, ContinuousClock.now < deadline { await Task.yield() }
      panel.searchText = "撤销上次提交但保留代码改动"
      while panel.isSearching, ContinuousClock.now < deadline { await Task.yield() }
      panel.searchByMeaning()
      while panel.semanticState == .working, ContinuousClock.now < deadline { await Task.yield() }
      XCTAssertEqual(panel.semanticState, missing ? .needsModel : .ready)
      for dark in [false, true] {
        let view = NSHostingView(rootView: RecordQuickPanelView(
          model: panel, language: dark ? .english : .simplifiedChinese, capturePaused: false,
          onPaste: { _ in }, onCopy: { _ in }, onShowRecord: { _ in }, onClose: {}, onConfigureJev: { _ in })
          .environment(\.colorScheme, dark ? .dark : .light))
        try await render(view, size: NSSize(width: 620, height: 560), dark: dark,
          to: output.appendingPathComponent("semantic-\(missing ? "download" : "ready")-\(dark ? "dark" : "light").png"))
      }
      await panel.shutdown()
      await search.shutdown()
    }
  }

  func testRenderImageAndFilePreviews() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR for image and file preview evidence.")
    }
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let imageData = try RecordPreviewFixture.imageData()
    let imageURL = output.appendingPathComponent("preview-sample.png")
    try imageData.write(to: imageURL)
    let textURL = output.appendingPathComponent("preview-notes.txt")
    try Data("Rill clipboard preview\nLocal file contents.\n".utf8).write(to: textURL)
    let pdfURL = output.appendingPathComponent("preview-document.pdf")
    var page = CGRect(x: 0, y: 0, width: 600, height: 400)
    let pdf = try XCTUnwrap(CGContext(pdfURL as CFURL, mediaBox: &page, nil))
    pdf.beginPDFPage(nil)
    pdf.setFillColor(CGColor(red: 0.16, green: 0.79, blue: 0.72, alpha: 1))
    pdf.fill(CGRect(x: 60, y: 80, width: 480, height: 240))
    pdf.endPDFPage()
    pdf.closePDF()
    let urls = [imageURL, pdfURL, textURL, output.appendingPathComponent("missing-file.txt")]
    let store = RecordStore()
    let image = try await store.ingest(.init(payload: .image(imageData),
      provenance: .init(source: .init(kind: .systemClipboard), sourceApplicationName: "Preview")), into: [])
    let files = try await store.ingest(.init(payload: .files(urls),
      provenance: .init(source: .init(kind: .systemClipboard), sourceApplicationName: "Finder")), into: [])
    let panel = RecordQuickPanelModel(store: store)
    panel.start(sourceBundleIdentifier: nil)
    defer { panel.stop() }
    for _ in 0..<100 where panel.results.count < 2 { await waitForMainRunLoopDefaultMode() }
    panel.togglePreview()
    for record in [image, files] {
      panel.selectedID = record.id
      for _ in 0..<100 where panel.preview?.id != record.id { await waitForMainRunLoopDefaultMode() }
      XCTAssertEqual(panel.preview?.id, record.id)
      for dark in [false, true] {
        for width in [620, 900] {
          let language: AppLanguage = dark ? .english : .simplifiedChinese
          let view = NSHostingView(rootView: RecordQuickPanelView(
            model: panel, language: language, capturePaused: false,
            onPaste: { _ in XCTFail("Preview must not paste.") },
            onCopy: { _ in XCTFail("Preview must not copy.") }, onShowRecord: { _ in }, onClose: {}, onConfigureJev: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light))
          try await render(view, size: NSSize(width: width, height: 560), dark: dark,
            to: output.appendingPathComponent("preview-\(record.record.payload.kind)-\(dark ? "dark" : "light")-\(width).png"),
            settle: true)
        }
      }
    }
  }

  func testRenderJevReviewAndResults() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR for native Jev evidence.")
    }
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for dark in [false, true] {
      for scored in [false, true] {
        let fixture = JevPanelFixture()
        let first = try await fixture.insert("git reset --soft HEAD~1")
        let second = try await fixture.insert("git revert HEAD")
        let model = RecordJevPanelModel(settings: JevAPISettingsModel(service: fixture.service))
        model.prepare(query: "撤销上次提交，但保留代码改动", recordIDs: [first.id, second.id])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.state == .preparing, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.state, .review)
        if scored {
          model.settings.setKey("unit-test-key")
          while !model.isConfigured, ContinuousClock.now < deadline { await Task.yield() }
          model.confirm()
          while model.state == .scoring, ContinuousClock.now < deadline { await Task.yield() }
          XCTAssertEqual(model.state, .ready)
        }
        let view = NSHostingView(rootView: RecordJevSheet(model: model,
          language: dark ? .english : .simplifiedChinese, onSelect: { _ in
            // Rendering only; selection behavior is covered by RecordJevPanelTests.
          }, onConfigure: { _ in }, onRetry: {})
          .environment(\.colorScheme, dark ? .dark : .light))
        try await render(view, size: NSSize(width: 540, height: 620), dark: dark,
          to: output.appendingPathComponent("jev-\(scored ? "result" : "review")-\(dark ? "dark" : "light").png"))
        await model.shutdown()
        await fixture.service.shutdown()
      }
    }
  }

  private func render<Content: View>(
    _ view: NSHostingView<Content>, size: NSSize, dark: Bool, to url: URL, settle: Bool = false
  ) async throws {
    let previous = NSApplication.shared.appearance
    NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    defer { NSApplication.shared.appearance = previous }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    window.layoutIfNeeded()
    if settle { try await Task.sleep(for: .seconds(1)) }
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    window.close()
  }
}
