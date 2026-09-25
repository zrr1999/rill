import AppKit
import RillCore
import SwiftUI
import XCTest
@testable import RillUI

@MainActor
final class HistoryRunCardRenderTests: XCTestCase {
    func testDeepLinkFocusStaysWithinTheRunHeader() async throws {
        let fixture = try await makeFixture(language: .english)
        let window = makeWindow(model: fixture.model, expandedEntryID: fixture.successID)
        defer { window.close() }
        await settle(window)

        fixture.model.showHistoryEntry(fixture.successID)
        await settle(window)
        let focusedView = try XCTUnwrap(window.firstResponder as? NSView,
            "Expected a focused header view, found \(String(describing: window.firstResponder)).")
        XCTAssertGreaterThan(focusedView.bounds.height, 0)
        XCTAssertLessThan(focusedView.bounds.height, 70,
                          "Deep links must focus the header rather than the entire expanded detail.")
        if let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory), withIntermediateDirectories: true
            )
            try snapshot(try XCTUnwrap(window.contentView), to: URL(fileURLWithPath: directory)
                .appendingPathComponent("run-card-keyboard-focus.png"))
        }
        await fixture.model.stopSettingsReadTasksForApplicationShutdown()
        await fixture.model.flushPendingPersistenceWrites()
    }

    func testRenderRunCardsWithInlineDiagnostics() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in AppLanguage.allCases {
            for dark in [false, true] {
                let fixture = try await makeFixture(language: language)
                let size = NSSize(width: dark ? 520 : 960, height: 680)
                let states: [(String, UUID?)] = [
                    ("collapsed", nil), ("success", fixture.successID),
                    ("failure", fixture.failureID), ("legacy", fixture.legacyID)
                ]
                for (state, expandedEntryID) in states {
                    let window = makeWindow(
                        model: fixture.model, expandedEntryID: expandedEntryID,
                        size: size, dark: dark
                    )
                    await settle(window)
                    let name = "run-card-\(language.rawValue)-\(dark ? "dark" : "light")-\(state)"
                    try snapshot(try XCTUnwrap(window.contentView),
                                 to: output.appendingPathComponent(name + ".png"))
                    window.close()
                }
                let diagnostics = NSHostingView(rootView: DiagnosticsView(model: fixture.model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let diagnosticsWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled], backing: .buffered, defer: false)
                diagnosticsWindow.isReleasedWhenClosed = false
                diagnosticsWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                diagnosticsWindow.contentView = diagnostics
                diagnostics.frame = NSRect(origin: .zero, size: size)
                diagnosticsWindow.makeKeyAndOrderFront(nil)
                await settle(diagnosticsWindow)
                try snapshot(diagnostics, to: output.appendingPathComponent(
                    "diagnostics-\(language.rawValue)-\(dark ? "dark" : "light").png"
                ))
                diagnosticsWindow.close()
                await fixture.model.stopSettingsReadTasksForApplicationShutdown()
                await fixture.model.flushPendingPersistenceWrites()
            }
        }
    }

    private struct Fixture {
        let model: AppModel
        let successID: UUID
        let failureID: UUID
        let legacyID: UUID
    }

    private func makeFixture(language: AppLanguage) async throws -> Fixture {
        let model = makeHarness().model
        await model.waitForInitialVoiceConfiguration()
        await model.waitForHistoryProjectionLoads()
        model.setInterfaceLanguage(language)
        let successID = UUID(), failureID = UUID(), legacyID = UUID()
        let timestamp = Date()
        let workflow = WorkflowPresentation(fallbackName: language == .english ? "Smart Cleanup" : "智能整理")
        model.history.historyRecords = [
            WorkflowResultRecord(
                runID: successID, workflow: workflow,
                finalText: language == .english ? "What can we improve?" : "有哪些改进点？",
                timestamp: timestamp, outcome: .completed
            ),
            WorkflowResultRecord(
                runID: failureID, workflow: workflow,
                failureMessage: HistoryFailureSanitizer.genericMessage,
                timestamp: timestamp.addingTimeInterval(-60), outcome: .failed
            ),
            WorkflowResultRecord(
                id: legacyID,
                workflow: WorkflowPresentation(fallbackName: language == .english ? "Older recording" : "旧录音"),
                failureMessage: HistoryFailureSanitizer.genericMessage,
                timestamp: timestamp.addingTimeInterval(-3_600), outcome: .failed, trigger: .hotkey
            )
        ]
        model.history.workflowRunReceiptsByRunID = [
            successID: try WorkflowRunReceipt(
                runID: successID, workflowID: nil, trigger: .hotkey, timestamp: timestamp,
                duration: .s1To4, termination: .completed,
                stepDetails: [
                    .init(stepIndex: 0, kind: .recognizeSpeech, result: .completed, duration: .under250ms, durationMilliseconds: 170),
                    .init(stepIndex: 1, kind: .llmRewrite, result: .completed, duration: .ms250To999, durationMilliseconds: 573)
                ],
                actionDetails: [
                    .init(actionIndex: 0, result: .injected, duration: .under250ms, durationMilliseconds: 42),
                    .init(actionIndex: 1, result: .storedRecord, duration: .under250ms, durationMilliseconds: 8)
                ],
                recordingDurationMilliseconds: 1_785
            ),
            failureID: try WorkflowRunReceipt(
                runID: failureID, workflowID: nil, trigger: .hotkey,
                timestamp: timestamp.addingTimeInterval(-60),
                duration: .s1To4, termination: .failed(stage: .transforming, code: .processing),
                stepDetails: [
                    .init(stepIndex: 0, kind: .recognizeSpeech, result: .completed, duration: .ms250To999, durationMilliseconds: 520),
                    .init(stepIndex: 1, kind: .llmRewrite, result: .failed, duration: .s1To4, durationMilliseconds: 2_500)
                ],
                recordingDurationMilliseconds: 12_500
            )
        ]
        let debugEvent = DiagnosticEvent(
            runID: successID, subsystem: .session, level: .debug,
            event: "audio-processing.temporary-file-removed", message: "Diagnostic event recorded.",
            metadata: ["lane": "interactive"]
        )
        model.history.diagnosticEvents = [
            debugEvent,
            DiagnosticEvent(
                runID: failureID, subsystem: .session, level: .error,
                event: "session.failure", message: "Diagnostic event recorded.",
                metadata: ["stage": "transforming", "failureCode": "processing"]
            )
        ]
        return Fixture(model: model, successID: successID, failureID: failureID,
                       legacyID: legacyID)
    }

    private func makeWindow(
        model: AppModel, expandedEntryID: UUID?,
        size: NSSize = NSSize(width: 960, height: 680), dark: Bool = false
    ) -> NSWindow {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: ScrollViewReader { proxy in
            ScrollView {
                HistoryTimelineView(model: model, proxy: proxy, expandedEntryID: expandedEntryID)
                    .padding(24)
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
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func snapshot(_ view: NSView, to url: URL) throws {
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
