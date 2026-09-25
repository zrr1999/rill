import AppKit
import RillCore
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class HistoryRunCardRenderTests: XCTestCase {
    func testRenderRunCardsWithInlineDiagnostics() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in AppLanguage.allCases {
            for dark in [false, true] {
                let model = makeHarness().model
                await model.waitForInitialVoiceConfiguration()
                await model.waitForHistoryProjectionLoads()
                model.setInterfaceLanguage(language)
                let runID = UUID()
                let receipt = try WorkflowRunReceipt(
                    runID: runID, workflowID: nil, trigger: .hotkey, timestamp: Date(),
                    duration: .s1To4, termination: .partiallyCompleted(code: .processing),
                    stepDetails: [
                        .init(stepIndex: 0, kind: .recognizeSpeech, result: .completed, duration: .s1To4, durationMilliseconds: 1_234),
                        .init(stepIndex: 1, kind: .llmRewrite, result: .completed, duration: .s1To4, durationMilliseconds: 2_500)
                    ],
                    actionDetails: [.init(actionIndex: 0, result: .injected, duration: .under250ms, durationMilliseconds: 42)],
                    recordingDurationMilliseconds: 12_500
                )
                let legacyID = UUID()
                model.history.historyRecords = [WorkflowResultRecord(
                    runID: runID,
                    workflow: WorkflowPresentation(fallbackName: language == .english ? "Smart Cleanup" : "智能整理"),
                    finalText: nil, failureMessage: HistoryFailureSanitizer.genericMessage,
                    outcome: .failed
                ), WorkflowResultRecord(
                    id: legacyID, workflow: WorkflowPresentation(fallbackName: language == .english ? "Older recording" : "旧录音"),
                    failureMessage: HistoryFailureSanitizer.genericMessage,
                    timestamp: Date().addingTimeInterval(-3_600), outcome: .failed, trigger: .hotkey
                )]
                model.history.workflowRunReceiptsByRunID = [runID: receipt]
                model.history.diagnosticEvents = [DiagnosticEvent(
                    runID: runID, subsystem: .session, level: .error,
                    event: "session.failure", message: "Diagnostic event recorded.",
                    metadata: ["stage": "delivering", "failureCode": "processing"]
                )]
                let size = NSSize(width: dark ? 520 : 960, height: 800)
                for expanded in [false, true] {
                    let view = NSHostingView(rootView: ScrollViewReader { proxy in
                        ScrollView {
                            HistoryTimelineView(
                                model: model, proxy: proxy,
                                expandedEntryIDs: expanded ? [runID, legacyID] : []
                            ).padding(24)
                        }
                    }
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.isReleasedWhenClosed = false
                    window.contentView = view
                    view.frame = NSRect(origin: .zero, size: size)
                    window.layoutIfNeeded()
                    for _ in 0..<20 { await Task.yield() }
                    view.layoutSubtreeIfNeeded()
                    let name = "run-card-\(language.rawValue)-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "collapsed")"
                    try snapshot(view, to: output.appendingPathComponent(name + ".png"))
                    window.close()
                }
                await model.stopSettingsReadTasksForApplicationShutdown()
                await model.flushPendingPersistenceWrites()
            }
        }
    }

    private func snapshot(_ view: NSView, to url: URL) throws {
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
