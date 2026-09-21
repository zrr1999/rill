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
    for dark in [false, true] {
      let view = NSHostingView(
        rootView: RecordQuickPanelView(
          model: panel, language: .simplifiedChinese, capturePaused: false,
          onPaste: { _ in }, onCopy: { _ in }, onShowRecord: { _ in }, onClose: {}
        )
        .environment(\.colorScheme, dark ? .dark : .light))
      try render(
        view, size: NSSize(width: 620, height: 560), dark: dark,
        to: output.appendingPathComponent("quick-panel-\(dark ? "dark" : "light").png"))
      await panel.cleanup.request()
      let cleanup = NSHostingView(
        rootView: RecordCleanupSheet(model: panel.cleanup, language: .simplifiedChinese)
          .environment(\.colorScheme, dark ? .dark : .light))
      try render(
        cleanup, size: NSSize(width: 480, height: 360), dark: dark,
        to: output.appendingPathComponent("cleanup-\(dark ? "dark" : "light").png"))
      panel.cleanup.cancel()
    }
  }

  private func render<Content: View>(
    _ view: NSHostingView<Content>, size: NSSize, dark: Bool, to url: URL
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    window.close()
  }
}
