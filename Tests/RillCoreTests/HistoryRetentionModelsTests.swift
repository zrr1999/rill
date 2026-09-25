import Foundation
import XCTest
@testable import RillCore

final class HistoryRetentionModelsTests: XCTestCase {
    func testRetentionPeriodsUseFixedDurationsFromInjectedNow() {
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let expectations: [(HistoryRetentionPeriod, TimeInterval)] = [
            (.oneDay, 86_400),
            (.oneWeek, 604_800),
            (.thirtyDays, 2_592_000),
            (.oneYear, 31_536_000),
        ]

        XCTAssertEqual(HistoryRetentionPeriod.defaultPeriod, .thirtyDays)
        for (period, duration) in expectations {
            XCTAssertEqual(period.duration, duration)
            XCTAssertEqual(
                period.cutoffDate(relativeTo: now),
                Date(timeIntervalSince1970: now.timeIntervalSince1970 - duration)
            )
        }
        XCTAssertNil(HistoryRetentionPeriod.forever.duration)
        XCTAssertNil(HistoryRetentionPeriod.forever.cutoffDate(relativeTo: now))
    }

    func testMaintenanceStateRoundTripsIndependentPointInTimeOperations() throws {
        let transition = try RunHistoryClearTransition(
            intentID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            advancing: .initial
        )
        let state = LocalHistoryMaintenanceState(
            clipboardOperation: .prune(olderThan: Date(timeIntervalSince1970: 111)),
            runOperation: .clearAll,
            runClearTransition: transition,
            phase: .residuePending
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LocalHistoryMaintenanceState.self, from: encoded)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.schemaVersion, LocalHistoryMaintenanceState.currentSchemaVersion)
        XCTAssertTrue(decoded.hasPendingOperations)
    }

    func testLegacyMaintenanceStateWithoutClearBoundaryStillDecodes() throws {
        let legacy = Data(
            #"{"schemaVersion":3,"runOperation":{"kind":"clear-all"},"phase":"logical-pending"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(LocalHistoryMaintenanceState.self, from: legacy)

        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.runOperation, .clearAll)
        XCTAssertNil(decoded.clearThrough)
    }

    func testClearAllOperationRejectsUnexpectedCutoff() {
        let malformed = Data(#"{"kind":"clear-all","olderThan":0}"#.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(LocalHistoryMaintenanceOperation.self, from: malformed)
        )
    }

    func testRunHistoryGenerationRejectsNegativeValuesAndOverflow() throws {
        XCTAssertThrowsError(try RunHistoryWriteGeneration(-1))
        let maximum = try RunHistoryWriteGeneration(Int64.max)
        XCTAssertThrowsError(try maximum.advanced())
    }

    func testRunHistoryClearTransitionDecodeRejectsNoncontiguousGeneration() {
        let malformed = Data(
            #"{"intentID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","previousGeneration":0,"nextGeneration":2}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(RunHistoryClearTransition.self, from: malformed)
        )
    }

}
