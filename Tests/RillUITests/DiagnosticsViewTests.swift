import Foundation
import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class DiagnosticsViewTests: XCTestCase {
    func testRepositoryFailureNeverResolvesToOrdinaryEmptyState() {
        guard case .failed(let entries) = DiagnosticsView.timelineContent(
            loadState: .failed,
            events: []
        ) else {
            return XCTFail("A failed repository load must resolve to the durable error state.")
        }
        XCTAssertTrue(entries.isEmpty)
        guard case .empty = DiagnosticsView.timelineContent(loadState: .loaded, events: []) else {
            return XCTFail("Only a successfully loaded empty repository may show the empty state.")
        }
    }


    func testTimelineShowsNewestTwentyEventsInNewestFirstOrder() {
        let baseTimestamp = Date(timeIntervalSince1970: 1_000)
        let events = (0..<25).reversed().map { offset in
            DiagnosticEvent(
                timestamp: baseTimestamp.addingTimeInterval(TimeInterval(offset)),
                subsystem: .ui,
                level: .info,
                event: "diagnostic.\(offset)",
                message: "Event \(offset)"
            )
        }

        let visibleEvents = DiagnosticsView.timelineEvents(from: events)

        XCTAssertEqual(visibleEvents.count, 20)
        XCTAssertEqual(visibleEvents.map(\.event), (5..<25).reversed().map { "diagnostic.\($0)" })
    }

    func testActivityFilterHidesDebugWhileIssuesAndAllRemainAvailable() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let debug = DiagnosticEvent(
            timestamp: timestamp,
            subsystem: .session,
            level: .debug,
            event: "debug.detail",
            message: "Diagnostic event recorded."
        )
        let info = DiagnosticEvent(
            timestamp: timestamp.addingTimeInterval(1),
            subsystem: .session,
            level: .info,
            event: "recording.started",
            message: "Diagnostic event recorded."
        )
        let warning = DiagnosticEvent(
            timestamp: timestamp.addingTimeInterval(2),
            subsystem: .providers,
            level: .warning,
            event: "provider.warning",
            message: "Provider warning"
        )

        XCTAssertEqual(
            DiagnosticsView.timelineEvents(from: [warning, info, debug]).map(\.event),
            ["provider.warning", "recording.started"]
        )
        XCTAssertEqual(
            DiagnosticsView.timelineEvents(
                from: [warning, info, debug],
                filter: .issues
            ).map(\.event),
            ["provider.warning"]
        )
        XCTAssertEqual(
            DiagnosticsView.timelineEvents(
                from: [warning, info, debug],
                filter: .all
            ).map(\.event),
            ["provider.warning", "recording.started", "debug.detail"]
        )
    }

    func testDiagnosticPresentationLocalizesKnownActivityAndKeepsTechnicalDetail() {
        let event = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            subsystem: .session,
            level: .info,
            event: "session.stage",
            message: "Diagnostic event recorded.",
            metadata: ["stage": "recognizing", "model": "local-model"]
        )

        XCTAssertEqual(
            DiagnosticEventPresentation.title(for: event, language: .english),
            "Recognizing speech on device"
        )
        XCTAssertEqual(
            DiagnosticEventPresentation.title(for: event, language: .simplifiedChinese),
            "正在本机识别语音"
        )
        XCTAssertEqual(
            DiagnosticEventPresentation.detail(for: event),
            "session.stage · model=local-model · stage=recognizing"
        )
    }


    func testRunFailurePresentationLocalizesGenericFailureWithoutLeakingRawInput() {
        let raw = "provider-internal-canary"

        XCTAssertEqual(
            RunFailurePresentation.historyText(for: raw, language: .english),
            "Processing did not complete. Expand execution details to see why."
        )
        XCTAssertEqual(
            RunFailurePresentation.historyText(for: raw, language: .simplifiedChinese),
            "本次处理未完成。展开执行详情查看原因。"
        )
    }

    func testTimelineIdentitySurvivesRefreshAndUnrelatedHeadInsertion() throws {
        let baseTimestamp = Date(timeIntervalSince1970: 1_000)
        let existingEvents = (0..<3).reversed().map { offset in
            DiagnosticEvent(
                timestamp: baseTimestamp.addingTimeInterval(TimeInterval(offset)),
                subsystem: .ui,
                level: .warning,
                event: "diagnostic.\(offset)",
                message: "Event \(offset)",
                metadata: ["attempt": "\(offset)"]
            )
        }
        let initialEntries = DiagnosticsView.timelineEntries(from: existingEvents)
        let refreshedEntries = DiagnosticsView.timelineEntries(from: existingEvents)
        XCTAssertEqual(initialEntries.map(\.id), refreshedEntries.map(\.id))

        let insertedEvent = DiagnosticEvent(
            timestamp: baseTimestamp.addingTimeInterval(3),
            subsystem: .providers,
            level: .error,
            event: "diagnostic.inserted",
            message: "Inserted event"
        )
        let entriesAfterInsertion = DiagnosticsView.timelineEntries(
            from: [insertedEvent] + existingEvents
        )

        for initialEntry in initialEntries {
            let retainedEntry = try XCTUnwrap(
                entriesAfterInsertion.first { $0.event == initialEntry.event }
            )
            XCTAssertEqual(retainedEntry.id, initialEntry.id)
        }
    }

    func testTimelineIdentityDisambiguatesValueIdenticalEvents() {
        let event = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            subsystem: .ui,
            level: .warning,
            event: "diagnostic.duplicate",
            message: "Duplicate event"
        )

        let entries = DiagnosticsView.timelineEntries(from: [event, event])

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    }

    func testCopyAccessibilityLabelsAreUniqueBilingualAndContentFree() throws {
        let runID = UUID(uuidString: "4A239C31-3FD0-4EB7-BF17-A4387E343F34")!
        let messageCanary = "MESSAGE-CANARY-4821"
        let metadataCanary = "METADATA-CANARY-7195"
        let events = [
            DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: 1_001),
                runID: runID,
                subsystem: .ui,
                level: .warning,
                event: "diagnostic.first",
                message: messageCanary,
                metadata: ["secret": metadataCanary]
            ),
            DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: 1_000),
                runID: runID,
                subsystem: .ui,
                level: .error,
                event: "diagnostic.second",
                message: messageCanary,
                metadata: ["secret": metadataCanary]
            ),
        ]
        let entries = DiagnosticsView.timelineEntries(from: events)

        let englishLabels = entries.map { $0.copyAccessibilityLabel(language: .english) }
        let chineseLabels = entries.map {
            $0.copyAccessibilityLabel(language: .simplifiedChinese)
        }

        XCTAssertEqual(englishLabels, ["Copy diagnostic entry 1", "Copy diagnostic entry 2"])
        XCTAssertEqual(chineseLabels, ["复制第 1 条诊断记录", "复制第 2 条诊断记录"])
        XCTAssertEqual(Set(englishLabels).count, entries.count)
        XCTAssertEqual(Set(chineseLabels).count, entries.count)

        for label in englishLabels + chineseLabels {
            XCTAssertFalse(label.contains(messageCanary))
            XCTAssertFalse(label.contains(metadataCanary))
            XCTAssertFalse(label.localizedCaseInsensitiveContains(runID.uuidString))
        }
    }
}
