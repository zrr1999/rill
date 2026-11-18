import Foundation

actor CaptureReadinessGate<CaptureFailure: Error & Sendable> {
  typealias Failure = CaptureFailure

  private enum Resolution: Sendable {
    case ready
    case failed(Failure)
    case cancelled
  }

  private var resolution: Resolution?
  private var waiters: [CheckedContinuation<Resolution, Never>] = []

  func wait(
    timeout: Duration,
    timeoutFailure: Failure,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async throws {
    let timeoutTask = Task { [weak self] in
      do {
        try await sleep(timeout)
      } catch {
        return
      }
      await self?.resolve(.failed(timeoutFailure))
    }
    let result = await withTaskCancellationHandler {
      await nextResolution()
    } onCancel: {
      Task { [weak self] in await self?.resolve(.cancelled) }
    }
    timeoutTask.cancel()
    await timeoutTask.value
    try Task.checkCancellation()

    switch result {
    case .ready:
      return
    case .failed(let failure):
      throw failure
    case .cancelled:
      throw CancellationError()
    }
  }

  func signalReady() {
    resolve(.ready)
  }

  func signalFailure(_ failure: Failure) {
    resolve(.failed(failure))
  }

  func cancel() {
    resolve(.cancelled)
  }

  private func nextResolution() async -> Resolution {
    if let resolution { return resolution }
    return await withCheckedContinuation { waiters.append($0) }
  }

  private func resolve(_ result: Resolution) {
    guard resolution == nil else { return }
    resolution = result
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume(returning: result)
    }
  }
}
