import Foundation
import RillCore
import RillSpeechContracts

public actor RecordWorkerEmbedder: RecordEmbeddingProvider {
  private let supervisor: SpeechWorkerSupervisor
  private var idleRelease: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var isClosed = false
  private var retirement: Task<Void, Never>?
  private var isPrepared = false

  public init(supervisor: SpeechWorkerSupervisor) { self.supervisor = supervisor }

  public func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void)
    async throws
  {
    guard !isClosed else { throw RecordEmbeddingError.unavailable }
    cancelIdleRelease()
    await retirement?.value
    try Task.checkCancellation()
    guard !isClosed else { throw RecordEmbeddingError.unavailable }
    defer { scheduleIdleRelease() }
    do {
      try await supervisor.prepareEmbeddingModel(downloadIfNeeded: downloadIfNeeded) {
        progress($0.fractionCompleted)
      }
      isPrepared = true
    } catch SpeechWorkerClientError.remoteFailure(.modelUnavailable) {
      isPrepared = false
      throw RecordEmbeddingError.modelUnavailable
    } catch {
      isPrepared = false
      throw error
    }
  }

  public func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws
    -> RecordTextEmbedding
  {
    guard !isClosed else { throw RecordEmbeddingError.unavailable }
    cancelIdleRelease()
    defer { scheduleIdleRelease() }
    await retirement?.value
    try Task.checkCancellation()
    guard !isClosed else { throw RecordEmbeddingError.unavailable }
    if !isPrepared {
      try await supervisor.prepareEmbeddingModel(downloadIfNeeded: false, progress: { _ in })
      isPrepared = true
    }
    do {
      return try await supervisor.embedRecordText(text, purpose: purpose)
    } catch SpeechWorkerClientError.remoteFailure(.invalidText) {
      throw RecordEmbeddingError.invalidInput
    } catch {
      isPrepared = false
      throw error
    }
  }

  public func shutdown() async {
    isClosed = true
    cancelIdleRelease()
    await retirement?.value
    try? await supervisor.shutdown()
  }

  private func cancelIdleRelease() {
    generation &+= 1
    idleRelease?.cancel()
    idleRelease = nil
  }

  private func scheduleIdleRelease() {
    guard !isClosed else { return }
    let expectedGeneration = generation
    idleRelease = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      await self?.releaseIfIdle(expectedGeneration)
    }
  }

  private func releaseIfIdle(_ expectedGeneration: UInt64) async {
    guard generation == expectedGeneration, !isClosed else { return }
    idleRelease = nil
    isPrepared = false
    let owned = Task<Void, Never> { [supervisor] in try? await supervisor.releaseLoadedModel() }
    retirement = owned
    await owned.value
    retirement = nil
  }
}
