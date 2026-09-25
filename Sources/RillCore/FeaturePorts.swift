import Foundation

public protocol RillEventPublishing: Sendable {
  func publish(_ event: RillEvent) async
}

public protocol DiagnosticRecording: Sendable {
  func record(_ event: DiagnosticEvent) async
}

public protocol RecordDeliveryPerforming: Sendable {
  func deliverNextRecord(
    for target: FocusedApplicationIdentity, actionID: String?,
    expectedTarget: FocusedApplicationTargetIdentity?) async
  func deliverRecord(
    matching subject: RecordDeliverySubject, to target: FocusedApplicationTargetIdentity,
    actionID: String?) async
  func reuseRecord(
    _ subject: RecordReuseSubject, to target: FocusedApplicationTargetIdentity?, copyOnly: Bool
  ) async -> RecordReuseOutcome
}

public protocol SystemClipboardRecordCapturing: Sendable {
  func captureSystemClipboard(
    snapshot: SystemClipboardSnapshot, sourceApplication: FocusedApplicationIdentity,
    allowsWorkflowCapture: Bool
  ) async throws -> RecordProjection
}
