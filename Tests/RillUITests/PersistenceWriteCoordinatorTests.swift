import Foundation
import Testing
@testable import RillUI

private actor PersistenceWriteProbe {
  enum Failure: Error { case rejected }

  private(set) var values: [String] = []
  private var entered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func write(_ value: String, pause: Bool = false, fail: Bool = false) async throws {
    if pause {
      entered = true
      entryWaiters.forEach { $0.resume() }
      entryWaiters.removeAll()
      await withCheckedContinuation { releaseContinuation = $0 }
    }
    if fail { throw Failure.rejected }
    values.append(value)
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

@MainActor
struct PersistenceWriteCoordinatorTests {
  @Test func replacementWaitsForRetiredWriteAndIgnoresItsFailure() async {
    let writes = PersistenceWriteCoordinator()
    let store = PersistenceWriteProbe()
    var completions: [String] = []
    writes.replace(for: .openAIModel, debounce: .zero) {
      try await store.write("old", pause: true, fail: true)
    } completion: { _ in completions.append("old") }
    await store.waitUntilEntered()

    writes.replace(for: .openAIModel, debounce: .zero) {
      try await store.write("new")
    } completion: { result in
      if case .success = result { completions.append("new") }
    }
    let (finished, signal) = AsyncStream<Void>.makeStream()
    writes.replace(for: .interfaceLanguage, debounce: .zero) {
      try await store.write("independent")
    } completion: { _ in signal.yield(()) }
    for await _ in finished { break }

    #expect(await store.values == ["independent"])
    await store.release()
    await writes.flush()
    #expect(await store.values == ["independent", "new"])
    #expect(completions == ["new"])
  }

  @Test func replacementSkipsSupersededDebounce() async {
    let writes = PersistenceWriteCoordinator()
    let store = PersistenceWriteProbe()
    writes.replace(for: .openAIModel, debounce: .seconds(3_600)) {
      try await store.write("old")
    } completion: { _ in Issue.record("A superseded write published a result.") }
    writes.replace(for: .openAIModel, debounce: .zero) {
      try await store.write("new")
    } completion: { _ in }

    await writes.flush()
    #expect(await store.values == ["new"])
  }

  @Test func flushIncludesWritesAcceptedDuringCompletion() async {
    let writes = PersistenceWriteCoordinator()
    let store = PersistenceWriteProbe()
    writes.replace(for: .openAIModel, debounce: .zero) {
      try await store.write("first")
    } completion: { _ in
      writes.track(Task {
        try? await store.write("follow-up", pause: true)
      })
    }
    var flushed = false
    let flush = Task {
      await writes.flush()
      flushed = true
    }
    await store.waitUntilEntered()
    #expect(!flushed)
    await store.release()
    await flush.value
    #expect(await store.values == ["first", "follow-up"])
    #expect(flushed)
  }
}
