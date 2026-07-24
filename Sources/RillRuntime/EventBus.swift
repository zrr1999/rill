import Foundation
import RillCore

/// An ordered delivery stream for consumers that must establish a shutdown
/// barrier after event producers have stopped.
public enum EventBusDelivery: Sendable, Equatable {
  case event(RillEvent)
  case barrier(UUID)
}

/// A content-free coordinate for consumers that only need to reload derived
/// clipboard state. The stream carrying this value retains at most the newest
/// invalidation, so it never queues `ClipboardStoreSnapshot` payloads.
public struct ClipboardStoreInvalidation: Sendable, Equatable {
  public let revision: UInt64

  public init(revision: UInt64) {
    self.revision = revision
  }
}

private enum EventBusStateProjectionKey: Sendable, Equatable {
  case clipboard
  case liveSubtitle(UUID)
  case audioProcessingQueue
  case failedAudioRecovery
  case deliveryStack
}

private enum EventBusCoalescingDisposition: Sendable {
  case replaceableState(EventBusStateProjectionKey)
  case transparentToClipboard
  case boundary
}

private final class EventBusBufferedChannel<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let coalescingDisposition:
    @Sendable (_ incoming: Element) -> EventBusCoalescingDisposition
  private var bufferedElements: [Element] = []
  private var bufferedHeadIndex = 0
  private var replaceableStateIndex: Int?
  private var replaceableStateKey: EventBusStateProjectionKey?
  private var transparentClipboardDiagnosticIndex: Int?
  private var waiter: CheckedContinuation<Element?, Never>?
  private var isFinished = false

  init(
    coalescingDisposition:
      @escaping @Sendable (_ incoming: Element) -> EventBusCoalescingDisposition
  ) {
    self.coalescingDisposition = coalescingDisposition
  }

  func send(_ element: Element) {
    let waitingConsumer = lock.withLock { () -> CheckedContinuation<Element?, Never>? in
      guard !isFinished else { return nil }
      if let waiter {
        self.waiter = nil
        return waiter
      }

      switch coalescingDisposition(element) {
      case .replaceableState(let key):
        if let replaceableStateIndex, replaceableStateKey == key {
          bufferedElements[replaceableStateIndex] = element
        } else {
          bufferedElements.append(element)
          replaceableStateIndex = bufferedElements.index(before: bufferedElements.endIndex)
          replaceableStateKey = key
          transparentClipboardDiagnosticIndex = nil
        }
      case .transparentToClipboard:
        if replaceableStateKey == .clipboard {
          if let transparentClipboardDiagnosticIndex {
            bufferedElements[transparentClipboardDiagnosticIndex] = element
          } else {
            bufferedElements.append(element)
            transparentClipboardDiagnosticIndex = bufferedElements.index(
              before: bufferedElements.endIndex
            )
          }
        } else {
          bufferedElements.append(element)
          replaceableStateIndex = nil
          replaceableStateKey = nil
          transparentClipboardDiagnosticIndex = nil
        }
      case .boundary:
        bufferedElements.append(element)
        replaceableStateIndex = nil
        replaceableStateKey = nil
        transparentClipboardDiagnosticIndex = nil
      }
      return nil
    }
    waitingConsumer?.resume(returning: element)
  }

  func next() async -> Element? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        var immediateResult: Element??
        lock.withLock {
          if bufferedHeadIndex < bufferedElements.endIndex {
            immediateResult = .some(bufferedElements[bufferedHeadIndex])
            if replaceableStateIndex == bufferedHeadIndex {
              replaceableStateIndex = nil
              replaceableStateKey = nil
            }
            if transparentClipboardDiagnosticIndex == bufferedHeadIndex {
              transparentClipboardDiagnosticIndex = nil
            }
            bufferedHeadIndex += 1
            compactConsumedPrefixIfNeeded()
          } else if isFinished || Task.isCancelled {
            immediateResult = .some(nil)
          } else {
            precondition(waiter == nil, "An event stream supports one consumer.")
            waiter = continuation
          }
        }
        if let immediateResult {
          continuation.resume(returning: immediateResult)
        }
      }
    } onCancel: {
      self.finish()
    }
  }

  func finish() {
    let waitingConsumer = lock.withLock { () -> CheckedContinuation<Element?, Never>? in
      guard !isFinished else { return nil }
      isFinished = true
      bufferedElements.removeAll(keepingCapacity: false)
      bufferedHeadIndex = 0
      replaceableStateIndex = nil
      replaceableStateKey = nil
      transparentClipboardDiagnosticIndex = nil
      let waiter = waiter
      self.waiter = nil
      return waiter
    }
    waitingConsumer?.resume(returning: nil)
  }

  /// Keeps dequeue amortized O(1) without retaining an indefinitely growing
  /// consumed prefix. Compaction occurs only after a substantial prefix has
  /// accumulated and that prefix occupies at least half of the allocation.
  private func compactConsumedPrefixIfNeeded() {
    guard bufferedHeadIndex > 0 else { return }
    if bufferedHeadIndex == bufferedElements.endIndex {
      bufferedElements.removeAll(keepingCapacity: true)
      bufferedHeadIndex = 0
      replaceableStateIndex = nil
      replaceableStateKey = nil
      transparentClipboardDiagnosticIndex = nil
      return
    }

    let minimumCompactionCount = 256
    guard
      bufferedHeadIndex >= minimumCompactionCount,
      bufferedHeadIndex >= bufferedElements.count - bufferedHeadIndex
    else { return }

    let consumedCount = bufferedHeadIndex
    bufferedElements.removeFirst(consumedCount)
    bufferedHeadIndex = 0
    if let replaceableStateIndex {
      self.replaceableStateIndex = replaceableStateIndex - consumedCount
    }
    if let transparentClipboardDiagnosticIndex {
      self.transparentClipboardDiagnosticIndex =
        transparentClipboardDiagnosticIndex - consumedCount
    }
  }
}

extension RillEvent {
  fileprivate var eventBusCoalescingDisposition: EventBusCoalescingDisposition {
    if case .liveSubtitleUpdated(let snapshot) = self, !snapshot.isVisible {
      // A terminal hidden snapshot closes one visible-presentation segment.
      // Treat it as a boundary so a stalled consumer observes the newest
      // visible snapshot before the run disappears instead of seeing only the
      // coalesced terminal state.
      return .boundary
    }
    if let key = stateProjectionKey {
      return .replaceableState(key)
    }
    return allowsClipboardSnapshotCoalescingAcrossEvent
      ? .transparentToClipboard
      : .boundary
  }

  fileprivate var stateProjectionKey: EventBusStateProjectionKey? {
    switch self {
    case .clipboardUpdated:
      return .clipboard
    case .liveSubtitleUpdated(let snapshot):
      return .liveSubtitle(snapshot.runID)
    case .audioProcessingQueueUpdated:
      return .audioProcessingQueue
    case .failedAudioRecoveryUpdated:
      return .failedAudioRecovery
    case .stackUpdated:
      return .deliveryStack
    default:
      return nil
    }
  }

  /// The per-publication debug record is replaceable observability traffic,
  /// not an event ordering boundary for clipboard state projection. Other
  /// events remain barriers.
  fileprivate var allowsClipboardSnapshotCoalescingAcrossEvent: Bool {
    guard case .diagnostic(let event) = self else { return false }
    return event.subsystem == .clipboard && event.event == "clipboard.snapshot"
  }
}

extension EventBusDelivery {
  fileprivate var eventBusCoalescingDisposition: EventBusCoalescingDisposition {
    guard case .event(let event) = self else { return .boundary }
    return event.eventBusCoalescingDisposition
  }
}

public actor EventBus {
  private var eventDeliveryChannels: [UUID: EventBusBufferedChannel<RillEvent>] = [:]
  /// Reserved synchronously during EventBus initialization so the single UI
  /// lifecycle consumer cannot miss events before its Task begins iterating.
  /// This stream is intentionally single-consumer.
  public nonisolated let lifecycleDeliveryStream: AsyncStream<EventBusDelivery>
  /// Reserved during initialization for the single StackPaste consumer.
  /// `.bufferingNewest(1)` makes invalidation bursts constant-space and the
  /// element deliberately contains no clipboard content.
  public nonisolated let clipboardInvalidationStream: AsyncStream<ClipboardStoreInvalidation>
  private let lifecycleDeliveryChannel: EventBusBufferedChannel<EventBusDelivery>
  private let clipboardInvalidationContinuation:
    AsyncStream<ClipboardStoreInvalidation>.Continuation
  private var clipboardInvalidationRevision: UInt64 = 0

  public init() {
    let channel = EventBusBufferedChannel<EventBusDelivery> { incoming in
      incoming.eventBusCoalescingDisposition
    }
    let invalidations = AsyncStream.makeStream(
      of: ClipboardStoreInvalidation.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    lifecycleDeliveryChannel = channel
    clipboardInvalidationStream = invalidations.stream
    clipboardInvalidationContinuation = invalidations.continuation
    lifecycleDeliveryStream = AsyncStream(
      unfolding: { await channel.next() },
      onCancel: { channel.finish() }
    )
  }

  /// Creates a broadcast event stream. High-frequency state projections are
  /// not an audit log: while a subscriber is behind, a consecutive projection
  /// for the same state scope replaces its older pending value. Other events
  /// retain FIFO order and form semantic boundaries. Clipboard snapshot debug
  /// diagnostics are the sole transparent boundary exception, and only the
  /// newest such diagnostic is retained in each pending clipboard segment.
  public func stream() -> AsyncStream<RillEvent> {
    let id = UUID()
    let channel = EventBusBufferedChannel<RillEvent> { incoming in
      incoming.eventBusCoalescingDisposition
    }
    eventDeliveryChannels[id] = channel
    return AsyncStream(
      unfolding: { await channel.next() },
      onCancel: { Task { await self.removeEventDeliveryChannel(id) } }
    )
  }

  public func publish(_ event: RillEvent) async {
    if event.stateProjectionKey == .clipboard {
      clipboardInvalidationRevision &+= 1
      clipboardInvalidationContinuation.yield(
        ClipboardStoreInvalidation(revision: clipboardInvalidationRevision)
      )
    }
    for channel in eventDeliveryChannels.values {
      channel.send(event)
    }
    lifecycleDeliveryChannel.send(.event(event))
  }

  /// Inserts an ordered marker only into delivery streams. Ordinary event
  /// subscribers never observe lifecycle coordination traffic.
  public func publishBarrier(_ id: UUID) async {
    lifecycleDeliveryChannel.send(.barrier(id))
  }

  private func removeEventDeliveryChannel(_ id: UUID) {
    guard let channel = eventDeliveryChannels.removeValue(forKey: id) else { return }
    channel.finish()
  }
}
