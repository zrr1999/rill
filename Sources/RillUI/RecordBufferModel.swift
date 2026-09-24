import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor @Observable
public final class RecordBufferModel {
  public private(set) var snapshot: RecordBufferSnapshot?
  public var message: String?
  public var isSending = false
  public var outputAction: (BufferEntryID?) -> Void = { _ in }
  public var confirmAction: () -> Void = {}
  public var retryAction: () -> Void = {}
  public var cancelAction: () -> Void = {}
  public var showMessageAction: () -> Void = {}
  public var shutdownAction: () async -> Void = {}
  private let store: RecordStore
  private var observation: Task<Void, Never>?
  private var mutation: Task<Void, Never>?
  private var isClosed = false

  public init(store: RecordStore) { self.store = store }
  isolated deinit { observation?.cancel() }

  public func start() {
    guard observation == nil, !isClosed else { return }
    observation = Task { [weak self, store] in
      do {
        for await value in try await store.bufferStream() {
          guard !Task.isCancelled else { break }
          self?.snapshot = value
        }
      } catch { self?.message = error.localizedDescription }
    }
  }

  public func setEnabled(_ enabled: Bool, buffer: RecordBuffer) {
    mutate {
      var updated = buffer
      updated.isEnabled = enabled
      try await self.store.updateBuffer(updated)
    }
  }

  public func enqueue(_ recordID: RecordID, bufferID: RecordBufferID) {
    mutate { _ = try await self.store.enqueueRecord(recordID, in: bufferID) }
  }

  public func createSet(name: String) {
    mutate { try await self.store.updateBuffer(.init(name: name, policy: .set)) }
  }

  public func entries(in bufferID: RecordBufferID) async -> [BufferEntry] {
    (try? await store.entries(in: bufferID)) ?? []
  }

  public func shutdown() async {
    isClosed = true
    observation?.cancel()
    await shutdownAction()
    await mutation?.value
  }

  private func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isClosed else { return }
    let previous = mutation
    mutation = Task {
      await previous?.value
      do { try await operation() } catch { message = error.localizedDescription }
    }
  }
}
