import AppKit
import RillCore
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class BenchmarkArchiveRenderTests: XCTestCase {
  func testRenderExplicitArchiveSelection() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
    }
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for language in AppLanguage.allCases {
      for dark in [false, true] {
        let settings = SettingsPersistenceModel(store: nil, language: language, verifyOpenAIConfiguration: { _ in }, configurationChanged: {})
        settings.isLoading = false
        let model = BenchmarkRecordingArchiveModel(settings: settings, store: nil,
          reader: RenderArchive(), exporter: nil, refresh: { _ in }, clear: {})
        let view = NSHostingView(rootView: BenchmarkRecordingArchiveSheet(model: model, language: language)
          .environment(\.colorScheme, dark ? .dark : .light)
          .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 590),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 {
          try await Task.sleep(for: .milliseconds(20))
          view.layoutSubtreeIfNeeded()
        }
        await model.waitForOperation()
        XCTAssertEqual(model.receipts.count, 3)
        XCTAssertFalse(model.authorizesPlaintextExport)
        XCTAssertNil(model.evidenceKind)
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("benchmark-archive-\(language.rawValue)-\(dark ? "dark" : "light").png"))
        window.close()
        model.cancelSelection()
        await model.waitForOperation()
      }
    }
  }
}

private struct RenderArchive: BenchmarkRecordingArchiveReading {
  let ids = (0..<3).map { _ in UUID() }
  func recordingIDs() async throws -> [UUID] { ids }
  func receipt(runID: UUID) async throws -> BenchmarkRecordingReceipt {
    .init(runID: runID, workflowID: UUID(), createdAt: Date(timeIntervalSince1970: 1_790_292_600),
      durationSeconds: 12.5, format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16),
      plaintextByteCount: 400_000, trigger: .hotkey, outcome: .completed, metadata: [:])
  }
  func recording(runID: UUID) async throws -> BenchmarkRecording { throw BenchmarkRecordingArchiveError.invalidEntry }
}
