import Foundation
import RillCore
import RillRuntime

/// Owns the product-level focused-application delivery boundary. System
/// clipboard fencing remains in `SystemClipboardCaptureController`; selection,
/// exact membership leases, and durable receipts stay here.
actor FocusedApplicationDeliveryController {
  private let recordDeliveryCoordinator: RecordDeliveryCoordinator
  private let sessionCoordinator: SessionCoordinator

  init(
    recordDeliveryCoordinator: RecordDeliveryCoordinator,
    sessionCoordinator: SessionCoordinator
  ) {
    self.recordDeliveryCoordinator = recordDeliveryCoordinator
    self.sessionCoordinator = sessionCoordinator
  }

  func deliverNext(to target: FocusedApplicationIdentity) async {
    await sessionCoordinator.deliverNextRecord(
      for: target,
      actionID: RecordActionID.focusedApplicationInsert
    )
  }

  func deliver(
    _ subject: RecordDeliverySubject,
    to target: FocusedApplicationTargetIdentity
  ) async {
    await sessionCoordinator.deliverRecord(
      matching: subject,
      to: target,
      actionID: RecordActionID.focusedApplicationInsert
    )
  }

  func beginRichDelivery(
    matching subject: RecordDeliverySubject
  ) async throws -> RecordDeliveryLease {
    try await recordDeliveryCoordinator.beginDelivery(
      matching: subject,
      sink: .focusedApplication
    )
  }

  func completeRichDelivery(_ leaseID: UUID) async throws {
    _ = try await recordDeliveryCoordinator.completeDelivery(leaseID)
  }

  func failRichDelivery(_ leaseID: UUID) async {
    try? await recordDeliveryCoordinator.failDelivery(leaseID)
  }
}
