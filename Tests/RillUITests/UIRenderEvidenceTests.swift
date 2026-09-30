import AppKit
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge
@testable import RillUI

/// Opt-in rendered evidence with ephemeral services, never the user's settings or clipboard.
@MainActor
final class UIRenderEvidenceTests: XCTestCase {
    func testRenderUnifiedRecordPanel() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = RecordStore()
        _ = try await seedRecords(store)
        let drafts: [(String, RecordBufferID)] = [
            ("会议记录\n\n明天下午三点讨论设计稿。\n\n先确认悬浮窗的交互，再整理页面里的内容和操作顺序。", RecordBuffer.speechID),
            ("待整理片段\n\n把零散的想法放在这里，准备好后再发送。", RecordBuffer.speechID),
            ("项目链接\n\nhttps://example.com/design-notes", RecordBuffer.clipboardID),
        ]
        for (text, bufferID) in drafts {
            let record = try await store.ingest(.init(payload: .text(text),
                provenance: .init(source: .init(kind: .user))), into: [])
            _ = try await store.enqueueRecord(record.id, in: bufferID)
        }
        let workspace = RecordWorkspaceModel(store: store)
        let model = makeHarness(recordWorkspace: workspace).model
        let session = workspace.makeQuickPanelModel()
        session.start(sourceBundleIdentifier: nil)
        await session.waitForSearch()
        session.togglePreview()
        session.pasteTargetName = "Notes"
        workspace.buffers.editor.open()
        await workspace.buffers.editor.refresh()
        if let first = workspace.buffers.editor.items.first { workspace.buffers.editor.select(first.id) }
        await workspace.buffers.editor.waitForPendingWrites()
        workspace.buffers.editor.targetName = "Notes"
        let presentation = RecordPanelPresentation()
        for language in AppLanguage.allCases {
            model.setInterfaceLanguage(language)
            for dark in [false, true] {
                let variant = "\(language.rawValue)-\(dark ? "dark" : "light")"
                for mode in RecordPanelPresentation.Mode.allCases {
                    presentation.mode = mode
                    let view = UnifiedRecordPanelView(presentation: presentation, model: model,
                        onModeChange: { presentation.mode = $0 }) {
                        RecordQuickPanelView(model: session, language: language, capturePaused: false,
                            onPaste: { _ in }, onCopy: { _ in }, onShowRecord: { _ in }, onClose: {}, onConfigureJev: { _ in })
                    }
                    for size in [NSSize(width: 620, height: 320), NSSize(width: 668, height: 468), NSSize(width: 820, height: 560)] {
                        try await render(view, size: size, dark: dark, floating: true,
                            to: output.appendingPathComponent("unified-\(mode.rawValue)-\(variant)-\(Int(size.width)).png"))
                    }
                    let scene = ZStack {
                        LinearGradient(colors: dark
                            ? [Color(red: 0.16, green: 0.22, blue: 0.3), Color(red: 0.29, green: 0.24, blue: 0.33)]
                            : [Color(red: 0.77, green: 0.85, blue: 0.91), Color(red: 0.89, green: 0.83, blue: 0.83)],
                            startPoint: .topTrailing, endPoint: .bottomLeading)
                        VStack(spacing: 14) {
                            RecordPanelCapsuleView(model: model, onExpand: {}, onClose: {})
                            view.frame(width: 668, height: 468)
                                .shadow(color: .black.opacity(0.15), radius: 18, y: 10)
                        }
                    }
                    try await render(scene, size: NSSize(width: 760, height: 610), dark: dark, floating: true,
                        to: output.appendingPathComponent("floating-scene-\(mode.rawValue)-\(variant).png"))
                }
                try await render(RecordPanelCapsuleView(model: model, onExpand: {}, onClose: {}),
                    size: NSSize(width: 260, height: 48), dark: dark, floating: true,
                    to: output.appendingPathComponent("pending-capsule-\(variant).png"))
                try await render(VoiceSetupView(model: model), size: NSSize(width: 500, height: 360), dark: dark,
                    to: output.appendingPathComponent("setup-\(variant).png"))
                model.voiceSetupPresentation = .presented
                try await render(MainShellView(model: model), size: NSSize(width: 960, height: 720), dark: dark,
                    to: output.appendingPathComponent("setup-window-\(variant).png"))
                model.voiceSetupPresentation = .dismissed
            }
        }
        await session.shutdown()
        await workspace.shutdown()
    }

    func testRenderEditableDrafts() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = RecordStore()
        let speech = try await store.reserveBufferInput(in: RecordBuffer.speechID)
        _ = try await store.ingest(.init(payload: .text("明天去北京开会，记得带上新的设计稿。"),
            provenance: .init(source: .init(kind: .voiceInput))), into: [], fulfilling: speech,
            recognitionText: "明天去背景开会，记得带上新的设计稿。")
        let copied = try await store.ingest(.init(payload: .text("https://example.com/project/notes"),
            provenance: .init(source: .init(kind: .systemClipboard))), into: [])
        _ = try await store.enqueueRecord(copied.id, in: RecordBuffer.clipboardID)
        let workspace = RecordWorkspaceModel(store: store)
        let model = makeHarness(recordWorkspace: workspace).model
        let editor = workspace.buffers.editor
        editor.open()
        await editor.refresh()
        editor.select(speech)
        await editor.waitForPendingWrites()
        editor.targetName = "TextEdit"
        for language in AppLanguage.allCases {
            model.applyLanguage(language)
            for dark in [false, true] {
                for width in [580.0, 820.0] {
                    editor.showsChanges = width > 580
                    try await render(RecordBufferDraftView(model: model),
                        size: NSSize(width: width, height: 520), dark: dark,
                        to: output.appendingPathComponent("drafts-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
        let session = try XCTUnwrap(editor.session)
        _ = try await store.ingestBufferDictation(.init(payload: .text("会议改到周五上午十点。"),
            provenance: .init(source: .init(kind: .voiceInput), workflowRunID: UUID())),
            recognitionText: "会议改到周五上午十点", for: .init(entryID: speech,
                draftID: session.saved.id, revision: session.saved.revision,
                selection: .init(location: 0), editingSessionID: UUID()))
        await editor.refresh()
        editor.showsChanges = false
        model.applyLanguage(.simplifiedChinese)
        try await render(RecordBufferDraftView(model: model),
            size: NSSize(width: 580, height: 520), dark: false,
            to: output.appendingPathComponent("drafts-suggestion-compact.png"))
        await editor.shutdown()
    }

    func testRenderLiveSubtitleControls() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in AppLanguage.allCases {
            for dark in [false, true] {
                let snapshots = [8.0, 360_000, 52, 58].map { elapsed in
                    LiveSubtitleSnapshot(
                        runID: UUID(), phase: .recording,
                        hypothesisText: language == .english ? "Recording preview" : "正在录音的字幕预览",
                        levelMeter: [0.2, 0.4, 0.8, 0.3, 0.6, 0.5], networkUsage: .online,
                        recordingStartedAt: Date().addingTimeInterval(-elapsed),
                        maximumRecordingDurationSeconds: elapsed < 60 ? 60 : nil,
                        recordingDurationIsUnlimited: elapsed >= 60,
                        canRemoveRecordingDurationLimit: true
                    )
                }
                let content = VStack(spacing: 16) {
                    ForEach(snapshots, id: \.runID) { snapshot in
                        HStack(spacing: 16) {
                            LiveSubtitleOverlay(snapshot: snapshot, language: language,
                                expandedLayout: false, includesShadow: false)
                            LiveSubtitleOverlay(snapshot: snapshot, language: language,
                                expandedLayout: true, includesShadow: false)
                        }
                    }
                }.padding(16)
                let size = NSSize(
                    width: LiveSubtitleOverlayMetrics.compactSurfaceWidth
                        + LiveSubtitleOverlayMetrics.expandedSurfaceWidth + 48,
                    height: LiveSubtitleOverlayMetrics.expandedSurfaceHeight * 4 + 80
                )
                try await render(content, size: size, dark: dark,
                    to: output.appendingPathComponent("subtitle-controls-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                for expanded in [false, true] {
                    let overlay = LiveSubtitleOverlay(snapshot: snapshots[0], language: language,
                        expandedLayout: expanded, includesShadow: false)
                    try await render(overlay, size: NSSize(
                        width: expanded ? LiveSubtitleOverlayMetrics.expandedSurfaceWidth : LiveSubtitleOverlayMetrics.compactSurfaceWidth,
                        height: expanded ? LiveSubtitleOverlayMetrics.expandedSurfaceHeight : LiveSubtitleOverlayMetrics.compactSurfaceHeight),
                        dark: dark, floating: true,
                        to: output.appendingPathComponent("subtitle-\(expanded ? "expanded" : "compact")-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

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
        model.voiceSetupPresentation = .dismissed
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
                    workspace.setPayloadKindFilter(.image)
                    workspace.setShowsPinnedOnly(true)
                    try await render(RecordWorkspaceView(workspace: workspace, language: language),
                        size: NSSize(width: 720, height: 560), dark: dark,
                        to: output.appendingPathComponent("records-no-results-\(variant).png"))
                    workspace.setPayloadKindFilter(nil)
                    workspace.setShowsPinnedOnly(false)
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

    func testNestedSplitsStayInsideDetailColumnAfterWindowResize() async throws {
        let store = RecordStore()
        let records = try await seedRecords(store)
        let workspace = RecordWorkspaceModel(store: store)
        await workspace.refresh()
        await workspace.revealRecord(try XCTUnwrap(records.last?.1))
        let model = makeHarness(recordWorkspace: workspace).model
        model.voiceSetupPresentation = .dismissed
        let host = NSHostingView(rootView: MainShellView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func splits(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? [])
                + view.subviews.flatMap { splits(in: $0) }
        }
        host.autoresizingMask = [.width, .height]
        // Window chrome and sidebar widths differ between macOS versions. Exercise
        // both presentations with room on either side of the 700pt content threshold.
        let sizes: [(width: CGFloat, splitCount: Int)] = [
            (1280, 2), (1100, 2), (800, 1), (1280, 2),
        ]
        for section in [SidebarSection.records, .workflows] {
            model.selectSidebarSection(section)
            for size in sizes {
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: size.width, height: 720)), display: true)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                var splitViews: [NSSplitView]
                repeat {
                    await waitForMainRunLoopDefaultMode()
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    splitViews = splits(in: host)
                } while splitViews.count != size.splitCount && ContinuousClock.now < deadline

                let context = "section=\(section), window=\(window.frame), splits=\(splitViews.map(\.frame))"
                XCTAssertEqual(splitViews.count, size.splitCount, context)
                guard size.splitCount == 2, splitViews.count == 2 else { continue }
                let outer = splitViews[0]
                let inner = splitViews[1]
                let outerBounds = outer.convert(outer.bounds, to: host)
                let innerBounds = inner.convert(inner.bounds, to: host)
                XCTAssertGreaterThanOrEqual(innerBounds.minX, outerBounds.minX + MainShellLayoutMetrics.sidebarColumnMinWidth, context)
                XCTAssertLessThanOrEqual(innerBounds.maxX, outerBounds.maxX, context)
                XCTAssertGreaterThanOrEqual(innerBounds.minY, outerBounds.minY + host.safeAreaInsets.top, context)
                inner.setPosition(340, ofDividerAt: 0)
                inner.layoutSubtreeIfNeeded()
                XCTAssertTrue(inner.subviews.allSatisfy { $0.frame.maxX <= inner.bounds.maxX }, context)
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

    private func render<Content: View>(
        _ content: Content, size: NSSize, dark: Bool, focusWindow: Bool = false,
        floating: Bool = false, to url: URL
    ) async throws {
        if let match = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_MATCH"],
           !url.lastPathComponent.contains(match) { return }
        let originalAppearance = NSApplication.shared.appearance
        let highContrast = ProcessInfo.processInfo.environment["RILL_UI_HIGH_CONTRAST"] == "1"
        let appearance = NSAppearance(named: highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        NSApplication.shared.appearance = appearance
        defer { NSApplication.shared.appearance = originalAppearance }
        // Match SwiftUI scenes: the native titlebar overlaps full-size content.
        let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light)
            .background(floating ? Color.clear : (dark ? Color(white: 0.12) : Color(white: 0.98))))
        view.sizingOptions = []
        let window: NSWindow = floating
            ? NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        if floating { window.isOpaque = false; window.backgroundColor = .clear }
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.autoresizingMask = [.width, .height]
        if focusWindow { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<12 { await waitForMainRunLoopDefaultMode() }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["RILL_UI_LAYOUT_DIAGNOSTICS"] == "1" {
            func describe(_ node: NSView, depth: Int = 0) -> [String] {
                let name = String(describing: type(of: node))
                let row = "\(String(repeating: " ", count: depth))\(name) frame=\(node.frame) bounds=\(node.bounds) hidden=\(node.isHidden) alpha=\(node.alphaValue) safe=\(node.safeAreaInsets)"
                return [row] + node.subviews.flatMap { describe($0, depth: depth + 1) }
            }
            let rows = ["window=\(window.frame) content=\(window.contentLayoutRect) mask=\(window.styleMask.rawValue)"] + describe(view)
            try rows.joined(separator: "\n").write(to: url.deletingPathExtension().appendingPathExtension("layout.txt"), atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.environment["RILL_UI_COMPOSITOR_CAPTURE"] == "1" {
            guard CGPreflightScreenCaptureAccess() else {
                throw XCTSkip("Compositor evidence requires existing Screen Recording permission; no prompt was requested.")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownWindow = try XCTUnwrap(content.windows.first {
                $0.windowID == CGWindowID(window.windowNumber)
                    && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            })
            let configuration = SCStreamConfiguration()
            let scale = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_SCALE"].flatMap(Double.init)
                ?? window.backingScaleFactor
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.includeChildWindows = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: url)
            return
        }
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: representation) }
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)

    }
}
