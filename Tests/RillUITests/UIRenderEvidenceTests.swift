import AppKit
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillRuntime
@testable import RillUI

/// Opt-in rendered evidence with ephemeral services, never the user's settings or clipboard.
@MainActor
final class UIRenderEvidenceTests: XCTestCase {
    func testRenderManagementSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = RecordStore()
        let sampleIDs = try await seedRecords(store)
        let workspace = RecordWorkspaceModel(store: store)
        await workspace.refresh()
        let workflow = makeBuiltinPushToTalkWorkflow()
        let files = UITestWorkflowFileStore(records: [.init(workflow: workflow, isEnabled: true,
            fileURL: URL(fileURLWithPath: "/tmp/rill-render-fixture/speech.toml"))])
        let history = InMemoryHistoryRepository()
        try await history.save(WorkflowResultRecord(workflow: WorkflowPresentation(fallbackName: "Speech to Text"),
            finalText: "Review the design and copy the final notes. 检查设计并复用最终笔记。", outcome: .completed, trigger: .hotkey))
        let model = makeHarness(workflows: [workflow], workflowFileStore: files, historyRepository: history,
            recordWorkspace: workspace).model
        await model.reloadWorkflowFiles()
        for language in AppLanguage.allCases {
            model.setInterfaceLanguage(language)
            for dark in [false, true] {
                let variant = "\(language.rawValue)-\(dark ? "dark" : "light")"
                for width in [960, 1280] {
                    for section in [SidebarSection.records, .stream, .workflows] {
                        model.selectSidebarSection(section)
                        try await render(MainShellView(model: model), size: NSSize(width: width, height: 720), dark: dark,
                            to: output.appendingPathComponent("\(section.rawValue)-\(variant)-\(width).png"))
                    }
                }
                for pane in SettingsPane.allCases {
                    model.selectedSettingsPane = pane
                    try await render(SettingsWindowView(model: model), size: NSSize(width: 760, height: 640), dark: dark,
                        to: output.appendingPathComponent("settings-\(pane.rawValue)-\(variant).png"))
                }
                for (name, id) in sampleIDs {
                    await workspace.revealRecord(id)
                    try await render(RecordWorkspaceView(workspace: workspace, language: language, copySelection: { _ in .copied }),
                        size: NSSize(width: 980, height: 660), dark: dark,
                        to: output.appendingPathComponent("payload-\(name)-\(variant).png"))
                }
                try await render(RecordWorkspaceView(workspace: workspace, language: language, copySelection: { _ in .storageUnavailable }),
                    size: NSSize(width: 620, height: 660), dark: dark,
                    to: output.appendingPathComponent("records-compact-\(variant).png"))
                workspace.payloadKindFilter = .image
                workspace.showsPinnedOnly = true
                try await render(RecordWorkspaceView(workspace: workspace, language: language),
                    size: NSSize(width: 720, height: 560), dark: dark,
                    to: output.appendingPathComponent("records-no-results-\(variant).png"))
                workspace.payloadKindFilter = nil
                workspace.showsPinnedOnly = false
                try await render(GlobalSearchResultsView(query: .constant("unavailable"), results: [], selectedResultID: nil,
                    historySearchState: .failed, recordSearchState: .failed, historyFailureActionTitle: "Retry", language: language,
                    focusRequest: 0, onMoveSelection: { _ in }, onSubmit: {}, onCancel: {},
                    onHistorySearchFailureAction: {}, onHighlight: { _ in }, onSelect: { _ in }),
                    size: NSSize(width: 620, height: 420), dark: dark,
                    to: output.appendingPathComponent("search-failure-\(variant).png"))
            }
        }
        await workspace.shutdown()
    }

    func testRenderAPIProviderSettings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = JevPanelFixture()
        let workspace = RecordWorkspaceModel(store: fixture.store, cloudRanking: fixture.service)
        let model = makeHarness(recordWorkspace: workspace).model
        for language in AppLanguage.allCases {
            model.setInterfaceLanguage(language)
            for dark in [false, true] {
                model.showSettings(.providers)
                try await render(SettingsView(model: model, pane: .voice), size: NSSize(width: 760, height: 1100),
                    dark: dark, to: output.appendingPathComponent("api-providers-\(language.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        await workspace.shutdown()
    }

    func testRenderTextCorrection() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let model = makeHarness().model
        for language in AppLanguage.allCases {
            model.setInterfaceLanguage(language)
            for dark in [false, true] {
                let sheet = VocabularyCorrectionSheet(model: model,
                    source: RecognitionCorrectionSource(preMappingText: "请保留原始文本，不要重复发送。", context: VocabularyRuleContext()),
                    workflowRunID: UUID())
                try await render(sheet, size: NSSize(width: 620, height: 600), dark: dark,
                    to: URL(fileURLWithPath: directory).appendingPathComponent("correction-\(language.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func seedRecords(_ store: RecordStore) async throws -> [(String, RecordID)] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 280,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 280)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 400, height: 200), xRadius: 24, yRadius: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let samples: [(String, RecordPayload, String, String)] = [
            ("image", .image(image), "Preview", "com.apple.Preview"),
            ("files", .files([URL(fileURLWithPath: "/tmp/rill-fixture/Design Notes.pdf"), URL(fileURLWithPath: "/tmp/rill-fixture/屏幕截图.png")]), "Finder", "com.apple.finder"),
            ("long-text", .text(String(repeating: "Design notes · 设计笔记\n搜索 → 定位 → 预览 → 复制。Keep the content clear and the controls familiar.\n\n", count: 40)), "Notes", "com.apple.Notes"),
            ("text", .text("Review the design\n先找到内容，再决定如何使用。\n\n记录正文优先，来源和时间作为辅助信息。"), "Notes", "com.apple.Notes"),
        ]
        var ids: [(String, RecordID)] = []
        for (name, payload, app, bundle) in samples {
            let record = try await store.ingest(.init(payload: payload,
                provenance: .init(source: .init(kind: .user), sourceApplicationName: app, sourceBundleIdentifier: bundle)), into: [])
            ids.append((name, record.id))
        }
        return ids
    }

    private func render<Content: View>(_ content: Content, size: NSSize, dark: Bool, to url: URL) async throws {
        let originalAppearance = NSApplication.shared.appearance
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApplication.shared.appearance = appearance
        defer { NSApplication.shared.appearance = originalAppearance }
        let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).background(dark ? Color(white: 0.12) : Color(white: 0.98)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        for _ in 0..<12 { await waitForMainRunLoopDefaultMode() }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: representation) }
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
