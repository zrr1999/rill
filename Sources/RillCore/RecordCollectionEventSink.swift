import Foundation

public enum RecordCollectionEventSubmissionResult: Sendable, Equatable {
  case accepted
  case duplicate
  case stopped
}

public protocol RecordCollectionEventSink: Sendable {
  @discardableResult
  func submit(
    _ descriptor: RecordCollectionEventDescriptor
  ) async -> RecordCollectionEventSubmissionResult
}
