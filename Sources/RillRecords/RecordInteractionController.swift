import Foundation
import RillCore

public actor RecordInteractionController {
  private let delivery: any RecordDeliveryPerforming
  private let eventBus: any RillEventPublishing
  private let focusIdentitySampleProvider: @Sendable () async -> FocusPrivacyIdentitySample
  private let accessibilityChecker: @Sendable () -> Bool
  private let permissionFailureMessage: String
  private var stopped = false
  private var isDeliveryInProgress = false
  private var deliveryOperationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    delivery: any RecordDeliveryPerforming, eventBus: any RillEventPublishing,
    focus: @escaping @Sendable () async -> FocusPrivacyIdentitySample,
    accessibility: @escaping @Sendable () -> Bool, permissionFailureMessage: String
  ) {
    self.delivery = delivery
    self.eventBus = eventBus
    self.focusIdentitySampleProvider = focus
    self.accessibilityChecker = accessibility
    self.permissionFailureMessage = permissionFailureMessage
  }

  public func stopAcceptingRequests() { stopped = true }

  public func shutdown() async {
    stopped = true
    await waitForDeliveryOperation()
  }
  public func deliverNextRecord() async {
    guard !stopped, !isDeliveryInProgress else { return }
    guard accessibilityChecker() else {
      await publishSelectedRecordDeliveryFailure(
        message: permissionFailureMessage
      )
      return
    }
    isDeliveryInProgress = true
    defer { finishDeliveryOperation() }
    let focus = await focusIdentitySampleProvider().focus
    guard !stopped, let target = FocusedApplicationTargetIdentity(focus: focus) else {
      await reportSelectedRecordDeliveryUnavailable()
      return
    }
    await delivery.deliverNextRecord(
      for: FocusedApplicationIdentity(
        bundleIdentifier: focus.bundleIdentifier, applicationName: focus.applicationName),
      actionID: RecordActionID.focusedApplicationInsert,
      expectedTarget: target
    )
  }

  public func deliverSelectedRecord(
    _ subject: RecordDeliverySubject,
    to target: FocusedApplicationTargetIdentity
  ) async {
    guard !stopped else { return }
    guard accessibilityChecker() else {
      await eventBus.publish(
        .runFailed(
          runID: nil,
          workflow: WorkflowPresentation(
            fallbackName: "Record Delivery",
            titleKey: .recordDelivery
          ),
          message: permissionFailureMessage
        )
      )
      return
    }
    if isDeliveryInProgress {
      await publishSelectedRecordDeliveryFailure(
        message: HistoryFailureSanitizer.genericMessage
      )
      return
    }
    isDeliveryInProgress = true
    defer {
      finishDeliveryOperation()
    }

    await delivery.deliverRecord(
      matching: subject, to: target, actionID: RecordActionID.focusedApplicationInsert)
  }

  public func reuseRecord(
    _ subject: RecordReuseSubject,
    to target: FocusedApplicationTargetIdentity? = nil,
    copyOnly: Bool = false
  ) async -> RecordReuseOutcome {
    guard !stopped, !isDeliveryInProgress else { return .blocked }
    guard copyOnly || accessibilityChecker() else {
      await reportSelectedRecordDeliveryUnavailable()
      return .permissionRequired
    }
    isDeliveryInProgress = true
    defer { finishDeliveryOperation() }
    return await delivery.reuseRecord(subject, to: target, copyOnly: copyOnly)
  }

  public func reportSelectedRecordDeliveryUnavailable() async {
    await publishSelectedRecordDeliveryFailure(
      message: HistoryFailureSanitizer.genericMessage
    )
  }

  private func publishSelectedRecordDeliveryFailure(message: String) async {
    await eventBus.publish(
      .runFailed(
        runID: nil,
        workflow: WorkflowPresentation(
          fallbackName: "Record Delivery",
          titleKey: .recordDelivery
        ),
        message: message
      )
    )
  }

  private func finishDeliveryOperation() {
    guard isDeliveryInProgress else { return }
    isDeliveryInProgress = false
    let waiters = deliveryOperationWaiters
    deliveryOperationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
  private func waitForDeliveryOperation() async {
    while isDeliveryInProgress {
      await withCheckedContinuation { continuation in
        deliveryOperationWaiters.append(continuation)
      }
    }
  }
}
