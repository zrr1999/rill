import Foundation
import RillCore

/// Diagnostic doubles that must never participate in history maintenance.
public protocol NonMaintainingDiagnosticRepository: DiagnosticRepository, DiagnosticHistoryMaintaining {
  func reportUnexpectedHistoryMaintenance() async
}

public extension NonMaintainingDiagnosticRepository {
  func deleteEvents(olderThan cutoff: Date) async throws -> Int {
    await reportUnexpectedHistoryMaintenance()
    throw RunHistoryGenerationError.unsupported
  }
  func deleteAllEvents() async throws -> Int {
    await reportUnexpectedHistoryMaintenance()
    throw RunHistoryGenerationError.unsupported
  }
  func deleteEvents(obsoletedBy transition: RunHistoryClearTransition, preservingLegacyRowsAfter legacyUpperBound: Date?) async throws -> Int {
    await reportUnexpectedHistoryMaintenance()
    throw RunHistoryGenerationError.unsupported
  }
}
