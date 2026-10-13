import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

public extension AppModel {
  func failedAudioRecoveryReceipt(
    for runID: UUID?
  ) -> FailedAudioRecoveryReceipt? {
    guard let runID else { return nil }
    return self.voice.failedAudioRecoveryReceipts.first { $0.originalRunID == runID }
  }

  func failedAudioRecoveryUnavailableMessage(
    _ reason: FailedAudioRecoveryError
  ) -> String {
    let detail = localizedRecoveryErrorDetail(reason)
    return String(
      format: L10n.runText(.failedRecordingNotRetainedFormat, language: self.settings.language),
      detail
    )
  }

  func setFailedAudioRecoveryEnabled(_ isEnabled: Bool) {
    guard !hasBegunApplicationShutdown,
      !self.settings.isLoading,
      isEnabled != self.voice.failedAudioRecoveryEnabled,
      !self.voice.isUpdatingFailedAudioRecovery
    else {
      return
    }
    guard let settingsStore else {
      self.voice.failedAudioRecoveryError = L10n.runText(
        .recoveryStorageUnavailable,
        language: self.settings.language
      )
      return
    }

    self.voice.isUpdatingFailedAudioRecovery = true
    self.voice.failedAudioRecoveryError = nil
    let refreshAction = refreshFailedAudioRecoveryAction
    let task = Task { [weak self, settingsStore] in
      do {
        try await settingsStore.setString(
          isEnabled ? "true" : "false",
          forKey: .failedAudioRecoveryEnabled
        )
        await MainActor.run {
          self?.voice.failedAudioRecoveryEnabled = isEnabled
        }
        do {
          try await refreshAction(isEnabled)
        } catch let refreshError {
          if isEnabled {
            // Do not leave the queue opted in when its protected
            // storage cannot be reconciled.
            do {
              try await settingsStore.setString(
                "false",
                forKey: .failedAudioRecoveryEnabled
              )
              await MainActor.run {
                self?.voice.failedAudioRecoveryEnabled = false
              }
            } catch {
              // The durable opt-in remains true, so the UI must
              // not claim it was rolled back. The runtime actor
              // still stays fail-closed for this session.
              await MainActor.run {
                guard let self else { return }
                self.voice.isUpdatingFailedAudioRecovery = false
                self.voice.failedAudioRecoveryEnabled = true
                self.voice.failedAudioRecoveryError = L10n.runText(
                  .recoveryEnabledStorageUnavailable,
                  language: self.settings.language
                )
              }
              return
            }
          }
          throw refreshError
        }
        await MainActor.run {
          self?.voice.failedAudioRecoveryError = nil
          self?.voice.isUpdatingFailedAudioRecovery = false
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.voice.isUpdatingFailedAudioRecovery = false
          self.voice.failedAudioRecoveryError = String(
            format: L10n.runText(.recoveryUpdateFailedFormat, language: self.settings.language),
            self.localizedRecoveryErrorDetail(error)
          )
        }
      }
    }
    persistenceWrites.track(task)
  }

  func loadFailedAudioRecoveryReceipts() {
    guard !hasBegunApplicationShutdown else { return }
    self.voice.failedAudioRecoveryLoadGeneration &+= 1
    let generation = self.voice.failedAudioRecoveryLoadGeneration
    self.voice.failedAudioRecoveryLoadTask?.cancel()
    guard self.voice.failedAudioRecoveryEnabled else {
      self.voice.failedAudioRecoveryReceipts = []
      self.voice.failedAudioRecoveryLoadTask = nil
      return
    }
    let loadAction = loadFailedAudioRecoveryReceiptsAction
    let task = Task { @MainActor [weak self, loadAction] in
      guard let self else { return }
      defer {
        if self.voice.failedAudioRecoveryLoadGeneration == generation {
          self.voice.failedAudioRecoveryLoadTask = nil
        }
      }
      do {
        let receipts = try await loadAction()
        try Task.checkCancellation()
        guard !self.hasBegunApplicationShutdown,
          self.voice.failedAudioRecoveryLoadGeneration == generation
        else { return }
        self.voice.failedAudioRecoveryReceipts = receipts
        self.voice.failedAudioRecoveryError = nil
      } catch is CancellationError {
        return
      } catch {
        guard !self.hasBegunApplicationShutdown,
          self.voice.failedAudioRecoveryLoadGeneration == generation
        else { return }
        self.voice.failedAudioRecoveryReceipts = []
        self.voice.failedAudioRecoveryError = String(
          format: L10n.runText(.recoveryLoadFailedFormat, language: self.settings.language),
          self.localizedRecoveryErrorDetail(error)
        )
      }
    }
    self.voice.failedAudioRecoveryLoadTask = task
  }

  func waitForFailedAudioRecoveryLoad() async {
    while let task = self.voice.failedAudioRecoveryLoadTask {
      await task.value
    }
  }

  func waitForFailedAudioRecoveryRetries() async {
    while !self.voice.failedAudioRecoveryRetryTasks.isEmpty {
      let tasks = Array(self.voice.failedAudioRecoveryRetryTasks.values)
      for task in tasks {
        await task.value
      }
    }
  }

  func retryFailedAudioRecovery(_ receipt: FailedAudioRecoveryReceipt) {
    guard !hasBegunApplicationShutdown,
      !self.voice.retryingFailedAudioRecoveryIDs.contains(receipt.id)
    else {
      return
    }
    guard receipt.status.canRetry else {
      self.voice.failedAudioRecoveryError = L10n.runText(
        .recoveryRetryDuplicateWarning,
        language: self.settings.language
      )
      return
    }
    guard let workflow = self.workflowLibrary.workflows.first(where: { $0.id == receipt.workflowID }) else {
      self.voice.failedAudioRecoveryError = L10n.runText(
        .recoveryWorkflowUnavailable,
        language: self.settings.language
      )
      return
    }

    self.voice.failedAudioRecoveryError = nil
    self.voice.retryingFailedAudioRecoveryIDs.insert(receipt.id)
    let retryAction = retryFailedAudioRecoveryAction
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.voice.retryingFailedAudioRecoveryIDs.remove(receipt.id)
        self.voice.failedAudioRecoveryRetryTasks.removeValue(forKey: receipt.id)
      }
      do {
        try Task.checkCancellation()
        let outcome = try await retryAction(receipt.id, workflow)
        try Task.checkCancellation()
        self.voice.failedAudioRecoveryReceipts.removeAll { $0.id == receipt.id }
        switch outcome {
        case .completed:
          self.voice.failedAudioRecoveryError = nil
        case .completedCleanupPending:
          self.voice.failedAudioRecoveryError = L10n.runText(
            .recoveryCleanupPending,
            language: self.settings.language
          )
        }
      } catch is CancellationError {
        // Cancellation is the expected application-shutdown path. The
        // runtime controller restores the retryable receipt and removes
        // any decrypted temporary audio before returning.
      } catch {
        self.voice.failedAudioRecoveryError = String(
          format: L10n.runText(.recoveryRetryFailedFormat, language: self.settings.language),
          self.localizedRecoveryErrorDetail(error)
        )
      }
    }
    self.voice.failedAudioRecoveryRetryTasks[receipt.id] = task
  }

  /// Prevents new operations, cancels the active index load and every retry,
  /// and waits until the runtime has restored durable state and cleaned any
  /// decrypted audio.
  /// Call this before draining events or flushing persistence during quit.
  func stopFailedAudioRecoveryRetriesForApplicationShutdown() async {
    beginApplicationShutdown()
    self.voice.failedAudioRecoveryLoadGeneration &+= 1
    let loadTask = self.voice.failedAudioRecoveryLoadTask
    self.voice.failedAudioRecoveryLoadTask = nil
    loadTask?.cancel()
    await loadTask?.value
    let tasks = Array(self.voice.failedAudioRecoveryRetryTasks.values)
    tasks.forEach { $0.cancel() }
    for task in tasks {
      await task.value
    }
    self.voice.failedAudioRecoveryRetryTasks.removeAll()
    self.voice.retryingFailedAudioRecoveryIDs.removeAll()
  }

  func deleteFailedAudioRecovery(_ receipt: FailedAudioRecoveryReceipt) {
    guard !hasBegunApplicationShutdown,
      !self.voice.retryingFailedAudioRecoveryIDs.contains(receipt.id)
    else {
      return
    }
    self.voice.isUpdatingFailedAudioRecovery = true
    self.voice.failedAudioRecoveryError = nil
    let deleteAction = deleteFailedAudioRecoveryAction
    Task { [weak self] in
      do {
        try await deleteAction(receipt.id)
        await MainActor.run {
          self?.voice.isUpdatingFailedAudioRecovery = false
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.voice.isUpdatingFailedAudioRecovery = false
          self.voice.failedAudioRecoveryError = String(
            format: L10n.runText(.recoveryDeleteFailedFormat, language: self.settings.language),
            self.localizedRecoveryErrorDetail(error)
          )
        }
      }
    }
  }

  func clearFailedAudioRecoveries() {
    guard !hasBegunApplicationShutdown,
      !self.voice.isUpdatingFailedAudioRecovery,
      self.voice.retryingFailedAudioRecoveryIDs.isEmpty
    else {
      return
    }
    self.voice.isUpdatingFailedAudioRecovery = true
    self.voice.failedAudioRecoveryError = nil
    let clearAction = clearFailedAudioRecoveryAction
    Task { [weak self] in
      do {
        try await clearAction()
        await MainActor.run {
          self?.voice.isUpdatingFailedAudioRecovery = false
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.voice.isUpdatingFailedAudioRecovery = false
          self.voice.failedAudioRecoveryError = String(
            format: L10n.runText(.recoveryClearFailedFormat, language: self.settings.language),
            self.localizedRecoveryErrorDetail(error)
          )
        }
      }
    }
  }
}

extension AppModel {
  func localizedRecoveryErrorDetail(_ error: Error) -> String {
    if let controllerError = error as? FailedAudioRecoveryController.ControllerError {
      let message = controllerError.errorDescription ?? "Failed recording recovery is unavailable."
      let resource: LocalizedStringResource =
        switch controllerError {
        case .retryAlreadyRunning: L10n.resource("recovery.controller.retryAlreadyRunning", defaultValue: "\(message)")
        case .recoveryDisabled: L10n.resource("recovery.controller.recoveryDisabled", defaultValue: "\(message)")
        case .retryFailed: L10n.resource("recovery.controller.retryFailed", defaultValue: "\(message)")
        case .retryFailedCleanupPending: L10n.resource("recovery.controller.retryFailedCleanupPending", defaultValue: "\(message)")
        case .plaintextCleanupPending: L10n.resource("recovery.controller.plaintextCleanupPending", defaultValue: "\(message)")
        }
      return resource.string(for: self.settings.language)
    }
    guard let recoveryError = error as? FailedAudioRecoveryError else {
      return L10n.runText(.recoveryTemporarilyUnavailable, language: self.settings.language)
    }
    let message = recoveryError.errorDescription ?? "Failed recording recovery is unavailable."
    let resource: LocalizedStringResource =
      switch recoveryError {
      case .entryTooLarge: L10n.resource("recovery.error.entryTooLarge", defaultValue: "\(message)")
      case .expired: L10n.resource("recovery.error.expired", defaultValue: "\(message)")
      case .invalidEntry: L10n.resource("recovery.error.invalidEntry", defaultValue: "\(message)")
      case .notFound: L10n.resource("recovery.error.notFound", defaultValue: "\(message)")
      case .protectionUnavailable: L10n.resource("recovery.error.protectionUnavailable", defaultValue: "\(message)")
      case .retryOutcomeUnknown: L10n.resource("recovery.error.retryOutcomeUnknown", defaultValue: "\(message)")
      case .storageUnavailable: L10n.resource("recovery.error.storageUnavailable", defaultValue: "\(message)")
      case .unsupportedPayload: L10n.resource("recovery.error.unsupportedPayload", defaultValue: "\(message)")
      }
    return resource.string(for: self.settings.language)
  }
}
