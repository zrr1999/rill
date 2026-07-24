import AppKit
import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
  typealias CleanupOperation = @Sendable () async -> Void
  typealias Reply = @MainActor @Sendable (Bool) -> Void
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private enum State {
    case ready
    case terminating
    case slow
    case finished
  }

  private let timeout: Duration
  private let sleep: Sleep
  private var cleanupOperation: CleanupOperation?
  private var state: State = .ready
  private var cleanupTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var reply: Reply?

  init(
    timeout: Duration = .seconds(15),
    cleanupOperation: CleanupOperation? = nil,
    sleep: @escaping Sleep = { duration in
      try await ContinuousClock().sleep(for: duration)
    }
  ) {
    self.timeout = timeout
    self.cleanupOperation = cleanupOperation
    self.sleep = sleep
  }

  var hasExceededCleanupDeadline: Bool {
    if case .slow = state { return true }
    return false
  }

  func installCleanupOperation(_ operation: @escaping CleanupOperation) {
    guard case .ready = state else { return }
    cleanupOperation = operation
  }

  func beginTermination(reply: @escaping Reply) -> NSApplication.TerminateReply {
    switch state {
    case .terminating, .slow:
      return .terminateLater
    case .finished:
      return .terminateNow
    case .ready:
      break
    }

    guard let cleanupOperation else {
      state = .finished
      return .terminateNow
    }

    state = .terminating
    self.reply = reply

    cleanupTask = Task { [weak self] in
      await cleanupOperation()
      self?.finishCleanup()
    }
    timeoutTask = Task { [weak self, sleep, timeout] in
      do {
        try await sleep(timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.markTerminationSlow()
    }
    return .terminateLater
  }

  private func finishCleanup() {
    switch state {
    case .terminating, .slow:
      state = .finished
      timeoutTask?.cancel()
      timeoutTask = nil
      cleanupTask = nil

      let pendingReply = reply
      reply = nil
      pendingReply?(true)
    case .ready, .finished:
      break
    }
  }

  private func markTerminationSlow() {
    guard case .terminating = state else { return }
    state = .slow
    timeoutTask = nil

    // Shutdown has crossed irreversible producer and input seals, while
    // clipboard recovery and persistence may still be in progress. Never
    // reply false and expose a sealed process as running, but do not reply
    // true until the required cleanup has actually completed either.
  }

  deinit {
    cleanupTask?.cancel()
    timeoutTask?.cancel()
  }
}

enum ApplicationShutdownOperation {
  static func make(
    sealMarkdownPostCommitCleanups: @escaping @Sendable () async -> Void = {},
    sealClipboardMutations: @escaping @Sendable () async -> Void = {},
    stopStartupTasks: @escaping @Sendable () async -> Void = {},
    stopSettingsReads: @escaping @Sendable () async -> Void = {},
    drainClipboardMutations: @escaping @Sendable () async -> Void = {},
    cancelRecording: @escaping @Sendable () async -> Void,
    cancelWorkflowRun: @escaping @Sendable () async -> Void,
    cancelFailedAudioRecoveryRetries: @escaping @Sendable () async -> Void,
    stopLocalHistoryMaintenance: @escaping @Sendable () async -> Void,
    shutdownAudioQueue: @escaping @Sendable () async -> Void,
    cancelDeepgramTest: @escaping @Sendable () async -> Void,
    drainTextInjectionClipboardRecovery: @escaping @Sendable () async -> Void = {},
    stopStackPaste: @escaping @Sendable () async -> Void,
    stopGlobalInputOwner: @escaping @Sendable () async -> Void = {},
    stopClipboardGroupScheduler: @escaping @Sendable () async -> Void,
    drainMarkdownPostCommitCleanups: @escaping @Sendable () async -> Void = {},
    stopLocalSpeechPreparation: @escaping @Sendable () async -> Void,
    stopEventListener: @escaping @Sendable () async -> Void,
    flushPersistence: @escaping @Sendable () async -> Void
  ) -> @Sendable () async -> Void {
    {
      // Establish the terminal UI mutation boundary before waiting for
      // startup work, which could otherwise leave a window for new writes.
      await sealMarkdownPostCommitCleanups()
      await sealClipboardMutations()
      // Startup work and model-owned settings reads may activate producers,
      // migrate credentials, or write diagnostics. Drain both before the
      // producer phase so nothing publishes behind later barriers.
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await stopStartupTasks()
        }
        group.addTask {
          await stopSettingsReads()
        }
      }
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await drainClipboardMutations()
        }
        group.addTask {
          await cancelRecording()
        }
        group.addTask {
          await cancelWorkflowRun()
        }
        group.addTask {
          await cancelFailedAudioRecoveryRetries()
        }
        group.addTask {
          await stopLocalHistoryMaintenance()
        }
        group.addTask {
          await shutdownAudioQueue()
        }
        group.addTask {
          await cancelDeepgramTest()
        }
      }
      // A text injection can temporarily sit on top of a StackPaste
      // preview. Restore that inner transaction first, then let StackPaste
      // restore the original system clipboard. Running these drains in
      // parallel can make the outer archive look like an external loser.
      await drainTextInjectionClipboardRecovery()
      await stopStackPaste()
      // Every typed-stream consumer is now stopped. The application-level
      // owner is the only component allowed to uninstall the shared tap.
      await stopGlobalInputOwner()
      await stopClipboardGroupScheduler()
      // Output producers are stopped and the coordinator was sealed
      // before teardown began. Finish descriptor-bound cleanup while
      // diagnostics and persistence are still available.
      await drainMarkdownPostCommitCleanups()
      await stopEventListener()
      await flushPersistence()
      // Model disposal is intentionally last. A slow third-party unload
      // must not delay event draining or durable persistence.
      await stopLocalSpeechPreparation()
    }
  }
}

@MainActor
final class VoiceInputApplicationDelegate: NSObject, NSApplicationDelegate {
  private let terminationCoordinator = ApplicationTerminationCoordinator()

  func installCleanupOperation(
    _ operation: @escaping ApplicationTerminationCoordinator.CleanupOperation
  ) {
    terminationCoordinator.installCleanupOperation(operation)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    terminationCoordinator.beginTermination { shouldTerminate in
      sender.reply(toApplicationShouldTerminate: shouldTerminate)
    }
  }
}
