import Foundation

public struct RecordBufferID: RecordIdentifier {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Collections organize history; buffers alone own pending output.
public struct RecordBuffer: Codable, Sendable, Equatable, Identifiable {
  public static let maximumCount = RecordStorageLimits.productDefault.maximumCollectionCount * 2 + 2

  public enum Policy: String, Codable, Sendable { case stack, queue, set }
  public let id: RecordBufferID
  public var name: String
  public var policy: Policy
  public var isEnabled: Bool
  public let legacyCollectionID: RecordCollectionID?

  public init(
    id: RecordBufferID = .init(), name: String, policy: Policy, isEnabled: Bool = true,
    legacyCollectionID: RecordCollectionID? = nil
  ) {
    self.id = id
    self.name = name
    self.policy = policy
    self.isEnabled = isEnabled
    self.legacyCollectionID = legacyCollectionID
  }
  public static let clipboardID = RecordBufferID(
    UUID(uuidString: "4C5A3D00-90E6-4BA0-95D7-17E8B6DB0001")!)
  public static let speechID = RecordBufferID(
    UUID(uuidString: "4C5A3D00-90E6-4BA0-95D7-17E8B6DB0002")!)
  public static let defaults: [RecordBuffer] = [
    .init(id: clipboardID, name: "Clipboard", policy: .stack),
    .init(id: speechID, name: "Speech", policy: .queue),
  ]
}

public struct BufferEntryID: Codable, Sendable, Hashable, CustomStringConvertible {
  public let bufferID: RecordBufferID
  public let sequence: UInt64
  public init(bufferID: RecordBufferID, sequence: UInt64) {
    self.bufferID = bufferID
    self.sequence = sequence
  }
  public var description: String { "\(bufferID)/\(sequence)" }
}

public struct BufferEntry: Codable, Sendable, Equatable, Identifiable {
  public enum State: String, Codable, Sendable {
    case preparing, ready, delivering, awaitingConfirmation, delivered
  }
  public let id: BufferEntryID
  public var recordID: RecordID?
  public var state: State
  public init(id: BufferEntryID, recordID: RecordID? = nil, state: State = .preparing) {
    self.id = id
    self.recordID = recordID
    self.state = state
  }
}

public struct RecordBufferSummary: Sendable, Equatable, Identifiable {
  public let buffer: RecordBuffer
  public let count: Int
  public var id: RecordBufferID { buffer.id }
  public init(buffer: RecordBuffer, count: Int) {
    self.buffer = buffer
    self.count = count
  }
}

public struct RecordBufferSnapshot: Sendable, Equatable {
  public let buffers: [RecordBufferSummary]
  public let next: BufferEntry?
  public let nextHeader: RecordHeader?
  public let active: BufferEntry?
  public var remainingCount: Int {
    buffers.filter { $0.buffer.isEnabled && $0.buffer.policy != .set }.reduce(0) { $0 + $1.count }
  }
  public init(
    buffers: [RecordBufferSummary], next: BufferEntry?, nextHeader: RecordHeader?,
    active: BufferEntry?
  ) {
    self.buffers = buffers
    self.next = next
    self.nextHeader = nextHeader
    self.active = active
  }
}

public struct BufferOutput: Sendable {
  public let entry: BufferEntry
  public let record: Record
  public init(entry: BufferEntry, record: Record) {
    self.entry = entry
    self.record = record
  }
}

public enum BufferOutputError: Error, Sendable, Equatable {
  case empty, processing, busy, unavailable, sequenceExhausted
}

/// This port deliberately has no system clipboard dependency.
public enum BufferTextResult: Sendable, Equatable { case verified, unconfirmed, rejected }

/// The position is allocated immediately; its journal write is ordered in the background.
public struct BufferInputReservation: Sendable {
  public let id: BufferEntryID
  public let committed: Task<Void, Error>
  public init(id: BufferEntryID, committed: Task<Void, Error>) {
    self.id = id
    self.committed = committed
  }
}
