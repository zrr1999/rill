import Foundation
import XCTest

@testable import RillCore
@testable import RillRuntime

private actor BenchmarkArchiveStoreProbe: BenchmarkRecordingArchiveStore {
  private(set) var preservedRunIDs: [UUID] = []
  private(set) var deletedRunIDs: [UUID] = []
  private(set) var deleteAllCount = 0

  func preserve(
    audio: CapturedAudio,
    runID: UUID,
    workflowID: UUID,
    trigger: WorkflowRunTriggerKind?,
    outcome: BenchmarkRecordingOutcome,
    metadata: [String: String],
    now: Date
  ) async throws -> BenchmarkRecordingReceipt {
    preservedRunIDs.append(runID)
    return BenchmarkRecordingReceipt(
      runID: runID,
      workflowID: workflowID,
      createdAt: now,
      durationSeconds: audio.durationSeconds,
      format: audio.format,
      plaintextByteCount: audio.inlineData?.count ?? 0,
      trigger: trigger,
      outcome: outcome,
      metadata: metadata
    )
  }

  func delete(runID: UUID) async throws {
    deletedRunIDs.append(runID)
  }

  func deleteAll() async throws {
    deleteAllCount += 1
  }
}

final class BenchmarkRecordingArchiveControllerTests: XCTestCase {
  func testRetentionRequiresExplicitEnableAndStopsWithoutDeletingExistingEntries() async throws {
    let store = BenchmarkArchiveStoreProbe()
    let controller = BenchmarkRecordingArchiveController(store: store)
    let audio = try makeAudio()
    let disabledRunID = UUID()

    let disabledReceipt = try await controller.preserveIfEnabled(
      audio: audio,
      runID: disabledRunID,
      workflowID: UUID(),
      trigger: .hotkey,
      outcome: .completed,
      metadata: [:]
    )
    XCTAssertNil(disabledReceipt)
    let initiallyPreservedRunIDs = await store.preservedRunIDs
    XCTAssertTrue(initiallyPreservedRunIDs.isEmpty)

    await controller.refresh(isEnabled: true)
    let enabledRunID = UUID()
    let enabledReceipt = try await controller.preserveIfEnabled(
      audio: audio,
      runID: enabledRunID,
      workflowID: UUID(),
      trigger: .hotkey,
      outcome: .completed,
      metadata: [:]
    )
    XCTAssertEqual(enabledReceipt?.runID, enabledRunID)

    await controller.refresh(isEnabled: false)
    let laterReceipt = try await controller.preserveIfEnabled(
      audio: audio,
      runID: UUID(),
      workflowID: UUID(),
      trigger: .hotkey,
      outcome: .completed,
      metadata: [:]
    )
    XCTAssertNil(laterReceipt)
    let preservedRunIDs = await store.preservedRunIDs
    let deletedRunIDs = await store.deletedRunIDs
    XCTAssertEqual(preservedRunIDs, [enabledRunID])
    XCTAssertTrue(deletedRunIDs.isEmpty)
  }

  func testExplicitClearDeletesAllArchivedRecordings() async throws {
    let store = BenchmarkArchiveStoreProbe()
    let controller = BenchmarkRecordingArchiveController(store: store)

    try await controller.deleteAll()

    let deleteAllCount = await store.deleteAllCount
    XCTAssertEqual(deleteAllCount, 1)
  }

  private func makeAudio() throws -> CapturedAudio {
    try CapturedAudio(
      durationSeconds: 1,
      format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
      inlineData: Data([1, 2, 3]),
      fileOwnership: .callerManaged
    )
  }
}
