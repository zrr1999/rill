import Foundation

enum GlobalInputStartupSequence {
  static func run(
    startRecordingConsumer: @escaping @Sendable () async -> Void,
    waitForVoiceConfiguration: @escaping @Sendable () async -> Void,
    startClipboardConsumer: @escaping @Sendable (Bool) async -> Void,
    startSharedInputProducer: @escaping @Sendable () async -> Void
  ) async {
    await startRecordingConsumer()
    guard !Task.isCancelled else { return }
    // A subscribed consumer is harmless, but advertising the producer as
    // ready before the atomic settings snapshot lands can interpret the
    // first Fn press using transient cloud/hold defaults. Keep the visible
    // capability in `checking` until the single AppModel-owned load has
    // selected a coherent workflow, engine, and control mode.
    await waitForVoiceConfiguration()
    guard !Task.isCancelled else { return }
    // Clipboard capture still starts fail-closed. Both typed-stream
    // consumers must subscribe before the application owner installs the
    // single shared producer.
    await startClipboardConsumer(false)
    guard !Task.isCancelled else { return }
    await startSharedInputProducer()
  }
}

/// Owns asynchronous application-startup work until termination has either
/// cancelled and drained it or every operation has completed naturally.
actor ApplicationStartupTaskCoordinator {
  typealias Operation = @Sendable () async -> Void

  private let startupTasks: [Task<Void, Never>]
  private var stopTask: Task<Void, Never>?

  init(operations: [Operation]) {
    startupTasks = operations.map { operation in
      Task {
        await operation()
      }
    }
  }

  func stopAndDrain() async {
    let task: Task<Void, Never>
    if let stopTask {
      task = stopTask
    } else {
      for startupTask in startupTasks {
        startupTask.cancel()
      }
      let startupTasks = startupTasks
      task = Task {
        for startupTask in startupTasks {
          await startupTask.value
        }
      }
      stopTask = task
    }
    await task.value
  }

  deinit {
    for startupTask in startupTasks {
      startupTask.cancel()
    }
  }
}
